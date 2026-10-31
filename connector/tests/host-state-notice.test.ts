/**
 * 宿主状态变更提示（契约 §5.9）：**发什么、发给谁、发给谁不发**。
 *
 * ## 这一组守什么
 *
 * P1 的症状（"桌面改了模型 / 权限 / 设置，手机还显示旧值"）是一类，所以判据也必须是
 * 结构性的：
 *
 * 1. **触发点 → keys 的映射只有一处**（`protocol/host-state.ts` 的五个函数），
 *    这里逐条断言它们与契约 §5.9 的触发点表一致；
 * 2. **写操作成功才发**、**发起者那台设备不发**（回执已带回值）；
 * 3. **线上形状**：`{t:'host', sid?, box:{keys}}`，未鉴权不发、空清单不发；
 * 4. **老客户端不会被饿死**：它把 `host` 当未知帧忽略、因而不回 `credit`，
 *    而 credit 是累计确认 ⇒ 后一帧的确认覆盖这个空洞。
 * 5. **任务表的触发点**：只有增删 / 终态改清单，`progress` / `output` 不在此列。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createConnectionScope, type ConnectionScopeDeps } from '../src/connection-scope.js'
import { createHandlers } from '../src/handlers.js'
import { METRIC, createMetrics, silentLogger } from '../src/observability.js'
import { createSessionBuffer } from '../src/session-buffer.js'
import { createSendWindow, consumesCredit } from '../src/protocol/flow.js'
import {
  HOST_STATE_KEYS,
  hostStateForSessionEvent,
  jobListChangedNotice,
  modelSelectedNotice,
  permissionSwitchedNotice,
  settingsUpdatedFor,
  settingsUpdatedNotice,
  titleChangedNotice,
  type HostStateNotice,
} from '../src/protocol/host-state.js'
import { onJobsLifecycle } from '../src/dsh/jobs.js'
import { READABLE_NAMESPACES } from '../src/dsh/settings-face.js'
import { needsBox, wireRoutingOf, type WireFrame } from '../src/protocol/frame.js'
import type { ConnectionPort, OutboundFrame } from '../src/transport/connection.js'

function fakePort() {
  const sent: OutboundFrame[] = []
  const port: ConnectionPort = {
    state: 'serving',
    send: (frame) => { sent.push(frame); return true },
    whenWritable: async () => {},
  }
  return { sent, port }
}

function makeDeps(overrides: Partial<ConnectionScopeDeps> = {}): ConnectionScopeDeps {
  const sessions = {
    list: async () => [], prompt: async () => ({ accepted: true as const }), cancel: () => ({ accepted: true as const }),
    updateQueue: async () => ({ accepted: true as const }),
    selectModel: async () => ({ selected: { provider: 'test', model: 'test' } }),
    create: async () => ({ sessionId: 'dsh-new' }),
    fork: async () => ({ childSessionId: 'dsh-child' }),
    rename: async () => ({ title: 't', seq: 1 }),
    page: async () => ({ records: [], hasMore: false }),
    follow: (): never => { throw new Error('本用例不应建立订阅') },
  }
  return {
    logger: silentLogger,
    metrics: createMetrics(),
    sessions,
    handlers: {
      caps: () => ({ sessions: true, storage: true, approval: false, questions: false, jobs: false, subagents: false, references: false, plugins: false, files: false, changes: false, settings: false, credentials: true, direct: false }),
      aliasVersion: () => 0,
      sessions,
      aliases: { ensure: async () => 's1', sessionOf: () => undefined },
      devices: () => [],
    },
    buffer: createSessionBuffer({ pairedDevices: () => [] }),
    jobControl: null,
    idempotency: null,
    ...overrides,
  }
}

/** 只关心"发了哪条通知"的方法面装配。 */
function makeHandlerDeps(notified: HostStateNotice[], deviceOf?: string) {
  return {
    caps: () => ({ sessions: true, storage: true, approval: false, questions: false, jobs: false, subagents: false, references: false, plugins: false, files: false, changes: false, settings: false, credentials: true, direct: false }),
    aliasVersion: () => 0,
    sessions: {
      list: async () => [],
      prompt: async () => ({ accepted: true as const }),
      selectModel: async () => ({ selected: { provider: 'p', model: 'm' } }),
      create: async () => ({ sessionId: 'dsh-new' }),
      updateQueue: async () => ({ accepted: true as const }),
      cancel: () => ({ accepted: true as const }),
    },
    aliases: { ensure: async (id: string) => `sid-${id}`, sessionOf: (sid: string) => (sid === 'sid-A' ? 'dsh-A' : undefined) },
    devices: () => [],
    notifyHostState: (notice: HostStateNotice) => { notified.push(notice) },
    ...(deviceOf === undefined ? {} : { connection: { deviceId: () => deviceOf, presence: {
      online: () => {}, offline: () => {}, app: () => {}, subscriptions: () => {}, interacted: () => {},
    } } }),
  }
}

const hostFramesOf = (frames: readonly OutboundFrame[]) => frames.filter((frame) => frame.t === 'host')

test('触发点 → keys 的映射与契约 §5.9 的触发点表一致', () => {
  // 一张表只在一处代码化（`protocol/host-state.ts`），这里逐条对照契约。
  assert.deepEqual(modelSelectedNotice('s1'), {
    keys: ['session.list', 'session.projections'], sid: 's1',
  })
  assert.deepEqual(permissionSwitchedNotice('s1'), { keys: ['session.projections'], sid: 's1' })
  assert.deepEqual(settingsUpdatedNotice(), { keys: ['settings.describe'] })
  assert.deepEqual(titleChangedNotice('s1'), {
    keys: ['session.list', 'session.projections'], sid: 's1',
  })
  assert.deepEqual(titleChangedNotice(undefined), { keys: ['session.list'] })
  assert.deepEqual(jobListChangedNotice('s1'), { keys: ['job.list'], sid: 's1' })
})

test('清单是封闭集（手写拼错会在这里红）', () => {
  assert.deepEqual([...HOST_STATE_KEYS].sort(), ['job.list', 'session.list', 'session.projections', 'settings.describe'])
  // 每一条被这五个构造函数发出来的 key 都必须在封闭清单里。
  const emitted = new Set<string>()
  for (const notice of [
    modelSelectedNotice('s'), permissionSwitchedNotice('s'), settingsUpdatedNotice(),
    titleChangedNotice('s'), titleChangedNotice(undefined), jobListChangedNotice('s'),
  ]) for (const key of notice.keys) emitted.add(key)
  for (const key of emitted) {
    assert.ok((HOST_STATE_KEYS as readonly string[]).includes(key), `${key} 不在 HOST_STATE_KEYS 里`)
  }
})

test('ConnectionScope：线上形状 `{t:\'host\', sid?, box:{keys}}`，未鉴权不发', () => {
  const a = fakePort()
  const scope = createConnectionScope(a.port, makeDeps())
  assert.equal(scope.sendHostStateChanged(['session.list']), false, '未鉴权的连接不该知道宿主状态')
  assert.deepEqual(a.sent, [])

  scope.deviceEstablished('dev-a')
  assert.equal(scope.sendHostStateChanged(['session.list']), true)
  assert.deepEqual(a.sent, [
    { v: 1, t: 'host', box: JSON.stringify({ keys: ['session.list'] }) },
  ])

  assert.equal(scope.sendHostStateChanged(['session.projections'], 's1'), true)
  assert.deepEqual(a.sent[1], {
    v: 1, t: 'host', sid: 's1', box: JSON.stringify({ keys: ['session.projections'] }),
  })
})

test('ConnectionScope：空清单不发；已发出才计入指标', () => {
  const a = fakePort()
  const metrics = createMetrics()
  const scope = createConnectionScope(a.port, makeDeps({ metrics }))
  scope.deviceEstablished('dev-a')

  assert.equal(scope.sendHostStateChanged([]), false, '空清单没有消费者')
  assert.deepEqual(hostFramesOf(a.sent), [])
  assert.equal(metrics.snapshot()[METRIC.hostStateNotices], undefined, '没发出去就不该计数')

  assert.equal(scope.sendHostStateChanged(['session.list']), true)
  assert.equal(hostFramesOf(a.sent).length, 1)
  assert.equal(metrics.snapshot()[METRIC.hostStateNotices], 1, '发出去一条就记一条')
})

test('老客户端漏 credit 不会被饿死窗口（`host` 占额度但累计确认覆盖空洞）', () => {
  // 老 app 的帧类型清单里没有 `host` ⇒ 解码层忽略、**不回 credit**。
  // 若窗口按"逐帧确认"算，这类帧攒到 W 就会把 `ev` 也压住；
  // 而 `credit.ack` 是**累计确认**（§4.3），后一帧的确认覆盖前面漏掉的。
  assert.equal(consumesCredit('host'), true, '它不占额度的话就没人验证这条链路了')

  const window = createSendWindow(4)
  window.onSent(0, 'host')          // 老客户端：忽略，不回 credit
  window.onSent(1, 'ev')
  window.onSent(2, 'ev')
  window.onSent(3, 'ev')
  assert.equal(window.unacked, 4, '一帧都没确认时四帧都挂着')

  window.onCredit(3)                // 只为最后一帧回 credit（累计确认 [0,3]）
  assert.equal(window.unacked, 0, '累计确认把漏掉的 `host` 也覆盖了')
})

test('切模型 / 切权限档**不在 handler 里发**（真值来自宿主事件，Web 改的也要覆盖）', async () => {
  // 这条钉的是**来源**：从 handler 发只覆盖"手机自己改"，而 P1 的验收是
  // "Web 改了、手机要跟上" —— Web 直接调宿主的 `selectModel` / `/permission`，
  // 根本不经过连接器。所以这两个动作后面由 `session/event` 广播，handler 只做写。
  const notified: HostStateNotice[] = []
  const deps = makeHandlerDeps(notified, 'dev-a') as Record<string, unknown>
  deps.permissions = {
    catalog: async () => undefined,
    switchTo: async () => ({ matched: true, execution: undefined }),
  }
  const handlers = createHandlers(deps as never)

  await handlers['session.select-model']!({ sid: 'sid-A', provider: 'p', model: 'm' }, { requestId: 'r1' })
  await handlers['permission.switch']!({ sid: 'sid-A', preset: 'workspace-write' }, { requestId: 'r2' })
  assert.deepEqual(notified, [], '这两条写不自己发通知')
})

test('宿主会话事件 → 通知：模型 / 权限档 / 标题命中，`request/header` 刻意不命中', () => {
  // `model/selection` 与 `permission/preset` 是宿主落的**持久事件**
  //（`core/agent/src/model-selection.ts:118-121`、`permission-presets/src/index.ts:416`），
  // 与"谁改的"无关 —— 这是 Web → 手机这条验收能成立的唯一来源。
  assert.deepEqual(hostStateForSessionEvent('model/selection', 'sid-A'), {
    keys: ['session.list', 'session.projections'], sid: 'sid-A',
  })
  assert.deepEqual(hostStateForSessionEvent('permission/preset', 'sid-A'), {
    keys: ['session.projections'], sid: 'sid-A',
  })
  assert.deepEqual(hostStateForSessionEvent('sandbox/mode', 'sid-A'), {
    keys: ['session.projections'], sid: 'sid-A',
  })
  assert.deepEqual(hostStateForSessionEvent('session/title', 'sid-A'), {
    keys: ['session.list', 'session.projections'], sid: 'sid-A',
  })

  // **`request/header` 不通知**：它也改 `modelSelection` 投影，但改的是 `lastUsed`
  //（"这一轮用了什么"），不是"选了哪个"。每一轮都通知等于把快照拉成轮询。
  assert.equal(hostStateForSessionEvent('request/header', 'sid-A'), undefined)
  // 与快照无关的普通事件当然不通知。
  assert.equal(hostStateForSessionEvent('assistant/message', 'sid-A'), undefined)

  // 别名未知：标题仍要刷列表（它是行字段）；其余两种只有投影一个落点，发不出去。
  assert.deepEqual(hostStateForSessionEvent('session/title', undefined), { keys: ['session.list'] })
  assert.equal(hostStateForSessionEvent('model/selection', undefined), undefined)
  assert.equal(hostStateForSessionEvent('permission/preset', undefined), undefined)
})

test('设置文档变更：只对手机读得到的命名空间发（其余不许白拉一次）', () => {
  // 宿主每个 ns 的变化都会发 `settings/document-updated`（含手机没有入口的），
  // 过滤判据就是手机可读的那张表（`READABLE_NAMESPACES`）。
  assert.deepEqual(settingsUpdatedFor('permission', READABLE_NAMESPACES), {
    keys: ['settings.describe'],
  })
  assert.deepEqual(settingsUpdatedFor('ui-conversation', READABLE_NAMESPACES), {
    keys: ['settings.describe'],
  })
  assert.equal(
    settingsUpdatedFor('some-desktop-only-ns', READABLE_NAMESPACES),
    undefined,
    '手机上根本没有这个入口 —— 重拉一次只会换回同一份数据',
  )
})

test('settings.update 本身不发通知（真值同样来自宿主事件）', async () => {
  const notified: HostStateNotice[] = []
  const deps = makeHandlerDeps(notified) as Record<string, unknown>
  deps.settings = {
    describe: () => [],
    update: async () => ({ ns: 'permission', revision: 1, values: {}, secrets: [] }),
  }
  const handlers = createHandlers(deps as never)
  await handlers['settings.update']!({ ns: 'permission', path: ['defaultPreset'], value: 'x' }, { requestId: 'r1' })
  assert.deepEqual(notified, [])
})

test('onJobsLifecycle：增删 / 终态才通知；progress / output / 无主不通知', () => {
  const listeners: ((event: unknown) => void)[] = []
  const jobs = {
    events: {
      subscribe: (_filter: unknown, listener: (event: unknown) => void) => {
        listeners.push(listener)
        return () => {}
      },
    },
  }
  const seen: string[] = []
  const dispose = onJobsLifecycle(jobs as never, (dshSessionId) => { seen.push(dshSessionId) })
  const emit = (event: unknown) => { for (const listener of listeners) listener(event) }
  const job = (owner: string | undefined) => ({ id: 'j1', owner, status: 'running' })

  emit({ type: 'registered', job: job('dsh-A') })
  emit({ type: 'settled', job: job('dsh-A'), cause: 'producer', awaited: false })
  emit({ type: 'removed', job: job('dsh-A') })
  assert.deepEqual(seen, ['dsh-A', 'dsh-A', 'dsh-A'])

  seen.length = 0
  emit({ type: 'progress', job: job('dsh-A') })
  emit({ type: 'stopping', job: job('dsh-A') })
  emit({ type: 'output', id: 'j1', owner: 'dsh-A', total: 10 })
  emit({ type: 'registered', job: job(undefined) })
  assert.deepEqual(seen, [], '进度 / 状态字走 `job` 帧；无主任务不属于任何会话的清单')

  dispose()
})

test('`host` 必须封箱，且会话级时 `sid` 进中继的路由视图', () => {
  // 不认证的通知能让任何人让手机反复重取 —— 所以它与 `status` 同档（要封箱），
  // 而 `sid` 在场时必须进路由视图，否则中继不知道该往哪条设备通道送。
  assert.equal(needsBox('host'), true, '`host` 不是明文例外（只有握手三帧与 presence 是）')

  const hostScoped: WireFrame = { v: 1, t: 'host', fc: 3, box: '{}' }
  const sessionScoped: WireFrame = { v: 1, t: 'host', sid: 's1', fc: 4, box: '{}' }
  assert.deepEqual(wireRoutingOf(hostScoped), { t: 'host', fc: 3 })
  assert.deepEqual(wireRoutingOf(sessionScoped), { t: 'host', sid: 's1', fc: 4 })
})
