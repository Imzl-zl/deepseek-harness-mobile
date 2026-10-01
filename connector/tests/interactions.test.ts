/**
 * `dsh/interactions.ts` 的审批管线（此前**没有测试** —— 它是唯一未覆盖的适配器）。
 *
 * 它可测的原因值得记下来：判定本身早已抽成纯函数（`src/protocol/takeover.ts` 的
 * `decideTakeover`），适配器只做三件事 —— 把 DSH 请求翻成我们的 prompt、把决定翻回去、
 * 失败时 fail-closed。于是测试**不需要 DSH 的替身**，只需要一个会捕获 handler 的假 `ctx`。
 *
 * 三条被钉住的语义：
 * 1. **不接管就 `next()`**（三种情形各一条）；
 * 2. 接管的 prompt **逐字段**来自 DSH 请求，且 **signal 是原对象**
 *    （代码注释写着"绝不替换" —— 取消语义整个挂在它上面）；
 * 3. 端口抛错时收束成 `'unavailable'`：DSH 会把 answerer 的异常**静默**归一成它，
 *    所以我们自己接住并留声（结果一样，但失败不再无声无息）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { registerInteractions } from '../src/dsh/interactions.js'

interface Captured {
  approval?: (request: never, next: () => Promise<unknown>) => Promise<unknown>
}

function setup(patch: {
  mode?: string
  devices?: readonly Record<string, unknown>[]
  /** `null` = 这个会话没登记给手机（`sidOf` 返回 `undefined`）。 */
  sid?: string | null
  askApproval?: () => Promise<'allow-once' | 'reject'>
} = {}) {
  const handlers: Captured = {}
  const calls: { prompt: Record<string, unknown>; signal: unknown }[] = []
  const warnings: string[] = []
  let nextCalled = 0

  const ctx = {
    on: (event: string, handler: unknown) => {
      if (event === 'approval/request') handlers.approval = handler as Captured['approval']
      return () => {}
    },
  }

  registerInteractions(ctx as never, {
    port: {
      askApproval: (prompt: unknown, signal?: AbortSignal) => {
        calls.push({ prompt: prompt as unknown as Record<string, unknown>, signal })
        return (patch.askApproval ?? (() => Promise.resolve('allow-once' as const)))()
      },
      askQuestion: () => Promise.reject(new Error('本用例不涉及提问')),
    },
    takeover: {
      mode: () => patch.mode ?? 'always',
      devices: () => (patch.devices ?? [{ id: 'dev-1', online: true, pairedAt: 1 }]) as never,
      sidOf: () => (patch.sid === null ? undefined : (patch.sid ?? 'sid_1')),
    },
    log: { warn: (message: string) => warnings.push(message) },
  } as never)

  const run = async (input: Record<string, unknown>) => {
    const next = () => {
      nextCalled += 1
      return Promise.resolve('from-desktop')
    }
    const handler = handlers.approval
    assert.ok(handler !== undefined, 'registerInteractions 应当注册 approval/request')
    return handler(input as never, next)
  }

  return { run, calls, warnings, nextCount: () => nextCalled }
}

const request = (patch: Record<string, unknown> = {}) => ({
  agent: { id: 'dsh-session-1' },
  callId: 'call-1',
  toolName: 'bash',
  signal: new AbortController().signal,
  ...patch,
})

test('不接管的三种情形都交还桌面（会话未登记 / 没有 callId / 档位是 never）', async () => {
  const unknown = setup({ sid: null })
  assert.equal(await unknown.run(request()), 'from-desktop', '会话未登记给手机 → next()')

  const noCall = setup()
  assert.equal(await noCall.run({ ...request(), callId: undefined }), 'from-desktop', '没有 callId 就没有稳定身份 → next()')

  const never = setup({ mode: 'never' })
  assert.equal(await never.run(request()), 'from-desktop', '档位 never → next()')

  for (const [name, fixture] of [['未登记', unknown], ['无 callId', noCall], ['never', never]] as const) {
    assert.deepEqual(fixture.calls, [], `${name}：不接管时绝不打扰手机`)
  }
})

test('接管：prompt 逐字段来自 DSH 请求，且 **signal 就是原对象**', async () => {
  const { run, calls } = setup()
  const original = request({ reason: '要删文件', displayReason: { en: 'delete a file' } })

  assert.equal(await run(original), 'allowed-once')
  assert.equal(calls.length, 1)
  const call = calls[0]
  assert.ok(call !== undefined)
  assert.equal(call.prompt['sid'], 'sid_1')
  assert.equal(call.prompt['dshSessionId'], 'dsh-session-1')
  assert.equal(call.prompt['callId'], 'call-1')
  assert.equal(call.prompt['toolName'], 'bash')
  assert.equal(call.prompt['reason'], '要删文件')
  assert.deepEqual(call.prompt['displayReason'], { en: 'delete a file' })
  assert.equal(call.signal, original.signal, 'signal 必须是原对象：取消语义整个挂在它上面')
})

test('拒绝与异常：reject → rejected；端口抛错 → **unavailable** 且留声', async () => {
  const rejected = setup({ askApproval: () => Promise.resolve('reject') })
  assert.equal(await rejected.run(request()), 'rejected')

  const failed = setup({ askApproval: () => Promise.reject(new Error('手机那边断了')) })
  assert.equal(
    await failed.run(request()),
    'unavailable',
    'DSH 会把 answerer 的异常静默归一成 unavailable —— 我们自己接住：结果一样，但留声',
  )
  assert.equal(failed.warnings.length, 1, '失败不能无声无息')
  assert.match(failed.warnings[0] ?? '', /fail-closed/)
})
