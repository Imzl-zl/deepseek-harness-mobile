/**
 * 插件的安装 / 卸载 / 取消 / 看进度（`plugin.install*` / `plugin.remove`）。
 *
 * 这一层的形状是"**发起即返回 + 轮询**"，用例就照这个形状钉：
 *
 * 1. `plugin.install` 在宿主还没跑完时就回 `{requestId}`（真实安装远超 60 s 请求超时）；
 * 2. 进度来自宿主的 `install-state` / `install-log` 事件，按 requestId 收进尾窗并**明说截断**；
 * 3. `cancelInstall` 的三档状态原样；失败时 status 带宿主的原话；
 * 4. `install` / `remove` 带幂等键（键就是任务句柄），`cancelInstall` / `installStatus` 不带。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import { createPluginInstallFace } from '../src/dsh/plugin-install.js'
import { readCaps } from '../src/dsh/caps.js'
import { createDispatcher, IDEMPOTENT_METHODS, METHODS, isMethod } from '../src/protocol/methods.js'

/**
 * 假 DSH 上下文：`get` 答服务，`on` 收集宿主事件的监听器（安装面的进度就从这里来）。
 */
function fakeCtx(services: Record<string, unknown>) {
  const listeners = new Map<string, ((payload: unknown) => void)[]>()
  return {
    ctx: {
      get: (key: string) => services[key],
      on: (event: string, listener: (payload: unknown) => void) => {
        const list = listeners.get(event) ?? []
        list.push(listener)
        listeners.set(event, list)
        return () => undefined
      },
    } as never,
    emit(event: string, payload: unknown) {
      for (const listener of listeners.get(event) ?? []) listener(payload)
    },
  }
}

const NO_SESSIONS = { list: async () => [] } as never
const ALIASES = { ensure: async () => 'sid_1', sessionOf: () => 'dsh-session-1' } as never

function depsWith(ctx: unknown): HandlerDeps {
  return {
    sessions: NO_SESSIONS,
    aliases: ALIASES,
    caps: () => readCaps(ctx as never),
    aliasVersion: () => 0,
    devices: () => [],
  } as unknown as HandlerDeps
}

/** 一次"还在跑"的宿主安装：promise 由测试决定何时兑现。 */
function pendingInstall() {
  let settle: (value: unknown) => void = () => undefined
  let fail: (error: unknown) => void = () => undefined
  const promise = new Promise<unknown>((resolve, reject) => {
    settle = resolve
    fail = reject
  })
  return { promise, settle, fail }
}

const DONE_RESULT = {
  changed: true,
  application: 'applied',
  stage: 'install',
  target: 'dsh-plugin-demo',
  bundle: 'dsh-plugin-demo',
  version: '1.2.3',
  packageResult: { exitCode: 0, output: 'added 3 packages', truncated: false, logPath: '/tmp/x.log' },
}

function harness(options: { install?: Promise<unknown>; cancel?: unknown } = {}) {
  const host = fakeCtx({
    pluginManager: {
      installBundle: async () => options.install ?? DONE_RESULT,
      removeBundle: async () => ({ ...DONE_RESULT, stage: 'remove' }),
      cancelInstall: async () => options.cancel ?? { status: 'cancelled' },
    },
  })
  const face = createPluginInstallFace(host.ctx)
  const handlers = createHandlers({ ...depsWith(host.ctx), pluginInstall: face })
  const dispatcher = createDispatcher(handlers)
  return { host, face, handlers, dispatcher }
}

test('方法表：install / remove 带幂等键，installStatus / cancelInstall 不带', () => {
  for (const method of ['plugin.install', 'plugin.installStatus', 'plugin.cancelInstall', 'plugin.remove'] as const) {
    assert.equal(isMethod(method), true, `${method} 必须在封闭集里`)
    assert.ok(METHODS.includes(method))
  }
  assert.equal(IDEMPOTENT_METHODS.has('plugin.install'), true, '重发不能起第二遍 pnpm')
  assert.equal(IDEMPOTENT_METHODS.has('plugin.remove'), true)
  assert.equal(IDEMPOTENT_METHODS.has('plugin.installStatus'), false, '读方法')
  assert.equal(IDEMPOTENT_METHODS.has('plugin.cancelInstall'), false, '重复取消落到同一个终态')
})

test('plugin.install：宿主还没跑完就先回 requestId；随后 status 变 done 并带回结论', async () => {
  const pending = pendingInstall()
  const h = harness({ install: pending.promise })

  const started = await h.dispatcher.dispatch({
    method: 'plugin.install',
    params: { spec: 'dsh-plugin-demo' },
    requestId: 'job-1',
  })
  assert.equal(started.ok, true)
  assert.deepEqual(started.ok === true ? started.result : null, { requestId: 'job-1' })

  const running = await h.dispatcher.dispatch({
    method: 'plugin.installStatus',
    params: { requestId: 'job-1' },
  })
  assert.equal(running.ok, true)
  const runningResult = (running.ok === true ? running.result : null) as Record<string, unknown>
  assert.equal(runningResult['status'], 'running')

  pending.settle(DONE_RESULT)
  await new Promise((resolve) => setImmediate(resolve))

  const done = await h.dispatcher.dispatch({
    method: 'plugin.installStatus',
    params: { requestId: 'job-1' },
  })
  const result = (done.ok === true ? done.result : null) as Record<string, unknown>
  assert.equal(result['status'], 'done')
  assert.equal(result['kind'], 'install')
  const detail = result['result'] as Record<string, unknown>
  assert.equal(detail['application'], 'applied')
  assert.equal(detail['bundle'], 'dsh-plugin-demo')
  assert.equal(detail['version'], '1.2.3')
  assert.equal(detail['exitCode'], 0)
  // 宿主的 `logPath`（电脑上的绝对路径）**不过线**。
  assert.equal(JSON.stringify(result).includes('/tmp/x.log'), false)
})

test('进度来自宿主事件：按 requestId 收尾窗，超长时明说截断', async () => {
  const pending = pendingInstall()
  const h = harness({ install: pending.promise })
  await h.dispatcher.dispatch({
    method: 'plugin.install',
    params: { spec: 'dsh-plugin-demo' },
    requestId: 'job-2',
  })

  h.host.emit('plugin-manager/install-state', { requestId: 'job-2', phase: 'applying' })
  h.host.emit('plugin-manager/install-log', { requestId: 'job-2', stream: 'stdout', text: 'resolving deps\n' })
  h.host.emit('plugin-manager/install-log', { requestId: 'job-2', stream: 'stdout', text: 'x'.repeat(9000) })
  // 别的任务 / 没有 requestId 的日志不该混进来。
  h.host.emit('plugin-manager/install-log', { stream: 'stdout', text: 'noise\n' })

  const status = (await h.dispatcher.dispatch({
    method: 'plugin.installStatus',
    params: { requestId: 'job-2' },
  })) as { ok: true; result: Record<string, unknown> }
  assert.equal(status.result['phase'], 'applying')
  assert.equal(status.result['logTruncated'], true, '截断要说')
  const lines = status.result['log'] as string[]
  assert.equal(lines.some((line) => line.includes('resolving deps')), false, '尾窗只留最后一段')
  assert.equal(lines.join('').includes('noise'), false, '别人的日志不进来')
  pending.settle(DONE_RESULT)
  await new Promise((resolve) => setImmediate(resolve))
})

test('plugin.cancelInstall：宿主三档原样回（cancelled / too-late / not-running）', async () => {
  for (const status of ['cancelled', 'too-late', 'not-running'] as const) {
    const h = harness({ cancel: { status } })
    const reply = await h.dispatcher.dispatch({
      method: 'plugin.cancelInstall',
      params: { requestId: 'job-x' },
    })
    assert.deepEqual(reply.ok === true ? reply.result : null, { status })
  }
})

test('宿主抛错：status 变 done 并带上原话（不伪装成未知失败）', async () => {
  const pending = pendingInstall()
  const h = harness({ install: pending.promise })
  await h.dispatcher.dispatch({
    method: 'plugin.install',
    params: { spec: 'bad spec' },
    requestId: 'job-3',
  })
  pending.fail(new Error('invalid-spec'))
  await new Promise((resolve) => setImmediate(resolve))

  const status = (await h.dispatcher.dispatch({
    method: 'plugin.installStatus',
    params: { requestId: 'job-3' },
  })) as { ok: true; result: Record<string, unknown> }
  assert.equal(status.result['status'], 'done')
  assert.equal(status.result['error'], 'invalid-spec')
})

test('plugin.remove：走 removeBundle，结论里 stage 是 remove', async () => {
  const h = harness()
  await h.dispatcher.dispatch({
    method: 'plugin.remove',
    params: { name: 'dsh-plugin-demo' },
    requestId: 'job-4',
  })
  await new Promise((resolve) => setImmediate(resolve))
  const status = (await h.dispatcher.dispatch({
    method: 'plugin.installStatus',
    params: { requestId: 'job-4' },
  })) as { ok: true; result: Record<string, unknown> }
  assert.equal(status.result['status'], 'done')
  assert.equal(status.result['kind'], 'remove')
  assert.equal((status.result['result'] as Record<string, unknown>)['stage'], 'remove')
})

test('不认识的任务 id ⇒ status unknown（不是"还在跑"）', async () => {
  const h = harness()
  const status = (await h.dispatcher.dispatch({
    method: 'plugin.installStatus',
    params: { requestId: 'never-started' },
  })) as { ok: true; result: Record<string, unknown> }
  assert.equal(status.result['status'], 'unknown')
})

test('漏幂等键 ⇒ 安装不发出去（分发前就拦）', async () => {
  const pending = pendingInstall()
  const h = harness({ install: pending.promise })
  const reply = await h.dispatcher.dispatch({
    method: 'plugin.install',
    params: { spec: 'dsh-plugin-demo' },
  })
  assert.equal(reply.ok, false)
  assert.equal(reply.ok === false ? reply.code : undefined, 'protocol/bad-frame')
  pending.settle(DONE_RESULT)
})
