/**
 * 方法面的连接级回归（契约 §5.7、§9）。
 *
 * 这组用例回答的是"手机真的能问一句、拿到一句吗"：手机侧封一个 `req` 发过来，
 * 电脑侧解箱 → 分发 → 封 `res` 回去，手机侧再用**自己那份实现**解开。
 * 两侧的容器、AAD、方向密钥任一处理解不同，这里就会断。
 *
 * 另一条同样重要：**结构化错误不关连接**（§9）。手机问一个不存在的方法，
 * 该拿到 `ok:false` 的信封并继续用这条连接 —— 而不是被断线重连。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import { createIdempotency } from '../src/idempotency.js'
import { waitFor } from './support/peer.js'
import { phoneOpenBox, phoneSealBox } from './support/phone.js'
import { createMemoryDedupeRows } from './support/dedupe-rows.js'
import { createFakeAliases } from './support/fake-aliases.js'
import { ProtocolError } from '../src/protocol/errors.js'
import { completeHandshake, start, type Fixture } from './support/secure-connection.js'
import type { SessionKeys } from '../src/protocol/crypto.js'
import type { JobSubscriptions } from '../src/job-subscriptions.js'
import type { SessionSubscriptions } from '../src/session-subscriptions.js'
import { createControllableSource } from './support/job-stream.js'
import { createControllableSessionSource } from './support/session-stream.js'

const CAPS = {
  sessions: true,
  storage: true,
  approval: false,
  questions: false,
  jobs: false,
  subagents: false,
  settings: false,
  credentials: true,
} as const

function fixtureHandlers(
  subscriptions: JobSubscriptions | null = null,
  sessionSubscriptions: SessionSubscriptions | null = null,
  /** 数一数真实的 `session.prompt` 被调用了几次（I8 的证据）。 */
  promptBox?: { count: number },
) {
  return createHandlers({
    caps: () => ({ ...CAPS }),
    aliasVersion: () => 7,
    devices: () => [{ id: 'dev-1', name: '我的手机', pairedAt: 1000, revoked: false }],
    sessions: {
      list: () =>
        Promise.resolve([
          {
            dshSessionId: 'dsh-1',
            updatedAt: 200,
            running: false,
            blank: false,
            subagent: false,
            cwd: '/repo/a',
          },
        ]),
      prompt: () => {
        if (promptBox !== undefined) promptBox.count += 1
        return Promise.resolve({ accepted: true })
      },
    },
    aliases: createFakeAliases({
      // 别名是**不透明的**：刻意不把 DSH 会话 id 编进去，否则"id 不过线"的断言会失去意义
      // （拿一个含 id 的 sid 去查 `includes(id)`，永远为真）。
      sidFor: (dshSessionId) => (dshSessionId === 'dsh-1' ? 'sid_0123456789abcd' : 'sid_ffffffffffff'),
    }),
    jobs: {
      listOwnedBy: (dshSessionId) =>
        dshSessionId === 'dsh-1'
          ? [
              {
                id: 'j1',
                kind: 'shell',
                label: '构建',
                status: 'running',
                progress: '2/5',
                startedAt: 10,
                outputTotal: 42,
              },
            ]
          : [],
      readOutput: () => ({ chunks: [], next: 0, lossy: false }),
      subscribe: () => () => {},
    },
    // 端口层面的替身：真实端口会把宿主的 job/not-found 转成协议码（见 dsh/jobs.ts），这里照样。
    jobControl: {
      kill: (_sessionId, jobId) => {
        if (jobId === 'j-foreign') throw new ProtocolError('job/not-found', '不属于这个会话')
        return jobId === 'j-done' ? 'already-finished' : 'requested'
      },
      follow: () => (async function* () {})(),
    },
    ...(subscriptions === null ? {} : { jobSubscriptions: subscriptions }),
    ...(sessionSubscriptions === null ? {} : { sessionSubscriptions }),
  })
}

/** 手机侧解出收到的所有 `job` 帧载荷（用手机侧自己那份封箱实现）。 */
function jobPayloadsOf(f: Fixture, keys: SessionKeys): unknown[] {
  return f.peer.received
    .filter((frame) => frame.t === 'job')
    .map((frame) =>
      JSON.parse(
        phoneOpenBox({
          keys,
          header: { t: 'job', fc: frame.fc, sid: frame.sid },
          box: frame.box,
        }),
      ),
    )
}

/** 手机侧发一个封装好的 `req`。 */
function sendRequest(f: Fixture, keys: SessionKeys, fc: number, id: string, payload: string): void {
  f.peer.send({
    v: 1,
    t: 'req',
    id,
    fc,
    box: phoneSealBox({ keys, header: { t: 'req', fc, id }, plaintext: payload }),
  })
}

/** 取对端收到的第 n 个 `res`，用手机侧实现解出信封。 */
function responseOf(
  f: Fixture,
  keys: SessionKeys,
  index = 0,
): { id: string; ok: boolean; envelope: Record<string, unknown> } {
  const responses = f.peer.received.filter((frame) => frame.t === 'res')
  const frame = responses[index]
  assert.ok(frame !== undefined && frame.t === 'res', `第 ${index + 1} 个 res 还没到`)
  return {
    id: frame.id,
    ok: frame.ok,
    envelope: JSON.parse(
      phoneOpenBox({ keys, header: { t: 'res', fc: frame.fc, id: frame.id }, box: frame.box }),
    ) as Record<string, unknown>,
  }
}

test('端到端：手机问 repo.info，电脑侧回一个可解的 res（id 对得上，能力位在里面）', async (t) => {
  const f = await start(t, { handlers: fixtureHandlers() })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  sendRequest(f, keys, 0, 'req_0123456789ab', '{"method":"repo.info"}')
  await waitFor('收到 res', () => f.peer.received.some((frame) => frame.t === 'res'))

  const res = responseOf(f, keys)
  assert.equal(res.id, 'req_0123456789ab', 'id 必须回带 —— 它就是请求与应答的唯一关联')
  assert.equal(res.ok, true)
  assert.equal(res.envelope['ok'], true, '帧头与信封必须同源')
  const info = res.envelope['result'] as {
    protocol: number
    caps: unknown
    aliasVersion: number
    methods: string[]
  }
  assert.equal(info.protocol, 1)
  assert.equal(info.aliasVersion, 7)
  assert.deepEqual(info.caps, CAPS, '能力位要在结果里（手机据此置灰按钮）')
  assert.deepEqual(
    info.methods,
    ["devices.list", 'job.kill', 'job.list', 'repo.info', 'session.list', 'session.prompt'],
    '实现了哪些方法也由同一张表报出',
  )
})

test('端到端：方法不存在 → ok:false 的 connector/unsupported，且**连接留着**', async (t) => {
  const f = await start(t, { handlers: fixtureHandlers() })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  sendRequest(f, keys, 0, 'req_aaaaaaaaaaaa', '{"method":"session.typo"}')
  await waitFor('收到 res', () => f.peer.received.some((frame) => frame.t === 'res'))

  const res = responseOf(f, keys)
  assert.equal(res.ok, false)
  assert.equal(res.envelope['code'], 'connector/unsupported')
  assert.equal(f.connection.state, 'serving', '结构化错误不是断连理由（§9）')
  assert.deepEqual(f.closes, [], '不该有任何关闭')
})

test('端到端：载荷不是 JSON → protocol/bad-frame 信封，连接同样留着', async (t) => {
  const f = await start(t, { handlers: fixtureHandlers() })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  sendRequest(f, keys, 0, 'req_bbbbbbbbbbbb', '这不是 JSON')
  await waitFor('收到 res', () => f.peer.received.some((frame) => frame.t === 'res'))

  const res = responseOf(f, keys)
  assert.equal(res.ok, false)
  assert.equal(res.envelope['code'], 'protocol/bad-frame')
  assert.equal(f.connection.state, 'serving')
})

test('端到端：手机问 session.list，拿到的是 sid（DSH 会话 id 不过线）', async (t) => {
  const f = await start(t, { handlers: fixtureHandlers() })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  sendRequest(f, keys, 0, 'req_gggggggggggg', '{"method":"session.list"}')
  await waitFor('收到 res', () => f.peer.received.some((frame) => frame.t === 'res'))

  const res = responseOf(f, keys)
  assert.equal(res.ok, true)
  const rows = (res.envelope['result'] as { sessions: Record<string, unknown>[] }).sessions
  assert.equal(rows.length, 1)
  const row = rows[0]
  assert.ok(row !== undefined)
  assert.equal(row['sid'], 'sid_0123456789abcd', '手机只见别名')
  assert.equal(row['updatedAt'], 200)
  assert.equal(row['cwd'], '/repo/a')
  // 中继与手机都只见 sid：DSH 的会话 id 绝不能出现在线上载荷里。
  assert.equal(JSON.stringify(res.envelope).includes('dsh-1'), false, 'DSH 会话 id 泄漏了')
  assert.equal('dshSessionId' in row, false)
})

test('端到端：同一个幂等键重发 → 只执行一次，第二次回上次的结果（I8）', async (t) => {
  const rows = createMemoryDedupeRows()
  let calls = 0
  const f = await start(t, {
    handlers: {
      'session.prompt': () => {
        calls += 1
        return { accepted: true, nth: calls }
      },
    },
    idempotency: createIdempotency({ rows }),
  })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  const payload = '{"method":"session.prompt","requestId":"p1","params":{"text":"你好"}}'
  // 手机的"重发"：同一个 requestId，两个不同的 fc（新的一帧）。
  sendRequest(f, keys, 0, 'req_eeeeeeeeeeee', payload)
  await waitFor('第一个应答到达', () => f.peer.received.filter((frame) => frame.t === 'res').length === 1)
  sendRequest(f, keys, 1, 'req_ffffffffffff', payload)
  await waitFor('第二个应答到达', () => f.peer.received.filter((frame) => frame.t === 'res').length === 2)

  assert.equal(calls, 1, '同一个幂等键只能生效一次 —— 否则就是第二条消息')
  const first = responseOf(f, keys, 0)
  const second = responseOf(f, keys, 1)
  assert.equal(first.id, 'req_eeeeeeeeeeee')
  assert.equal(second.id, 'req_ffffffffffff', '重发的应答回的是**这次**的 id')
  assert.deepEqual(second.envelope, first.envelope, '内容与第一次相同（命中即回上次结果）')
  assert.equal(rows.size, 1, '表里只留一行')
})

test('端到端：手机问 job.list —— sid 反解回会话，未知 sid 回 session/not-found 且连接留着', async (t) => {
  const f = await start(t, { handlers: fixtureHandlers() })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  // 真实流程就是这样：先列会话拿到 sid，再拿它问任务。
  // （顺带是一道活的门槛：**别名没分配过就反解不出来**，跳过列会话直接问 `job.list` 会得到 not-found。）
  sendRequest(f, keys, 0, 'req_gggggggggggg', '{"method":"session.list"}')
  await waitFor('收到会话清单', () => f.peer.received.some((frame) => frame.t === 'res'))
  const sessions = responseOf(f, keys, 0)
  const sid = (sessions.envelope['result'] as { sessions: { sid: string }[] }).sessions[0]?.sid
  assert.equal(sid, 'sid_0123456789abcd')

  sendRequest(f, keys, 1, 'req_hhhhhhhhhhhh', `{"method":"job.list","params":{"sid":"${String(sid)}"}}`)
  await waitFor('收到第二个 res', () => f.peer.received.filter((frame) => frame.t === 'res').length === 2)
  const listed = responseOf(f, keys, 1)
  assert.equal(listed.ok, true)
  assert.deepEqual((listed.envelope['result'] as { jobs: unknown[] }).jobs, [
    { id: 'j1', kind: 'shell', label: '构建', status: 'running', startedAt: 10, outputTotal: 42, progress: '2/5' },
  ])

  // 未知别名：回结构化错误，连接留着（§9）—— 手机据此把那个会话从列表移除。
  sendRequest(f, keys, 2, 'req_iiiiiiiiiiii', '{"method":"job.list","params":{"sid":"sid_nobody"}}')
  await waitFor('收到第三个 res', () => f.peer.received.filter((frame) => frame.t === 'res').length === 3)
  const missing = responseOf(f, keys, 2)
  assert.equal(missing.ok, false)
  assert.equal(missing.envelope['code'], 'session/not-found')
  assert.equal(f.connection.state, 'serving')
  assert.deepEqual(f.closes, [])
})

test('端到端：手机点停止 —— 受理回执，外来任务回 job/not-found 且连接留着', async (t) => {
  const f = await start(t, { handlers: fixtureHandlers() })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  // 先拿 sid（真实流程：列会话 → 操作其中的任务）。
  sendRequest(f, keys, 0, 'req_jjjjjjjjjjjj', '{"method":"session.list"}')
  await waitFor('收到会话清单', () => f.peer.received.some((frame) => frame.t === 'res'))
  const sid = (responseOf(f, keys, 0).envelope['result'] as { sessions: { sid: string }[] })
    .sessions[0]?.sid

  sendRequest(
    f,
    keys,
    1,
    'req_kkkkkkkkkkkk',
    `{"method":"job.kill","params":{"sid":"${String(sid)}","jobId":"j1"}}`,
  )
  await waitFor('收到第二个 res', () => f.peer.received.filter((frame) => frame.t === 'res').length === 2)
  const killed = responseOf(f, keys, 1)
  assert.equal(killed.ok, true)
  assert.deepEqual(
    killed.envelope['result'],
    { outcome: 'requested' },
    '受理与否由注册表说了算，不做乐观更新',
  )

  // 不属于这个会话（或已不存在）的任务：回 job/not-found，手机据此刷新列表；连接留着。
  sendRequest(
    f,
    keys,
    2,
    'req_llllllllllll',
    `{"method":"job.kill","params":{"sid":"${String(sid)}","jobId":"j-foreign"}}`,
  )
  await waitFor('收到第三个 res', () => f.peer.received.filter((frame) => frame.t === 'res').length === 3)
  const foreign = responseOf(f, keys, 2)
  assert.equal(foreign.ok, false)
  assert.equal(foreign.envelope['code'], 'job/not-found')
  assert.equal(f.connection.state, 'serving')
  assert.deepEqual(f.closes, [])
})

test('端到端：手机订任务输出 —— 三帧解得出，unfollow 停流，连接断开全停', async (t) => {
  const { source, streams } = createControllableSource()
  const f = await start(t, {
    handlers: ({ job }) => fixtureHandlers(job),
    jobSource: source,
  })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  // 先拿 sid（真实流程：列会话 → 展开任务）。
  sendRequest(f, keys, 0, 'req_mmmmmmmmmmmm', '{"method":"session.list"}')
  await waitFor('收到会话清单', () => f.peer.received.some((frame) => frame.t === 'res'))
  const sid = (responseOf(f, keys, 0).envelope['result'] as { sessions: { sid: string }[] })
    .sessions[0]?.sid

  // 订阅：手机要等宿主的 opened 帧才有应答，所以先发请求、再推帧。
  sendRequest(
    f,
    keys,
    1,
    'req_nnnnnnnnnnnn',
    `{"method":"job.follow","params":{"sid":"${String(sid)}","jobId":"j1"}}`,
  )
  await waitFor('宿主流开起来了', () => streams.length === 1)
  streams[0]?.push({
    kind: 'opened',
    jobId: 'j1',
    from: 0,
    job: { id: 'j1', kind: 'shell', label: '构建', status: 'running', startedAt: 10, outputTotal: 0 },
  })
  await waitFor('收到 follow 的应答', () => f.peer.received.filter((frame) => frame.t === 'res').length >= 2)
  const followed = responseOf(f, keys, 1)
  assert.equal(followed.ok, true)
  assert.deepEqual(followed.envelope['result'], { from: 0 }, '起点由宿主说了算，插件只转达')

  streams[0]?.push({
    kind: 'output',
    jobId: 'j1',
    chunks: [{ at: 0, text: '编译中…', channel: 'stdout' }],
    next: 12,
  })
  await waitFor('收到输出帧', () => f.peer.received.filter((frame) => frame.t === 'job').length >= 2)

  // 手机侧用自己的封箱实现解开这些帧（两端独立实现能对上，才算真的通了）。
  assert.deepEqual(jobPayloadsOf(f, keys), [
    {
      kind: 'opened',
      jobId: 'j1',
      from: 0,
      job: { id: 'j1', kind: 'shell', label: '构建', status: 'running', startedAt: 10, outputTotal: 0 },
    },
    { kind: 'output', jobId: 'j1', chunks: [{ at: 0, text: '编译中…', channel: 'stdout' }], next: 12 },
  ])

  // 收起面板 → 停流（宿主那条流必须被中止，不能让它为没人看的输出白跑）。
  sendRequest(
    f,
    keys,
    2,
    'req_oooooooooooo',
    `{"method":"job.unfollow","params":{"sid":"${String(sid)}","jobId":"j1"}}`,
  )
  await waitFor('收到 unfollow 的应答', () => f.peer.received.filter((frame) => frame.t === 'res').length >= 3)
  assert.deepEqual(responseOf(f, keys, 2).envelope['result'], { stopped: true })
  assert.equal(streams[0]?.signal.aborted, true, 'unfollow 必须真的中止宿主流')
  assert.equal(f.subscriptions?.active, 0)
  assert.deepEqual(f.closes, [], '整个过程连接都不该被关掉')
})

test('端到端：连接断开时任务输出订阅全停（手机收不到，重连后自己按 from 重订）', async (t) => {
  const { source, streams } = createControllableSource()
  const f = await start(t, {
    handlers: ({ job }) => fixtureHandlers(job),
    jobSource: source,
  })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  sendRequest(f, keys, 0, 'req_pppppppppppp', '{"method":"session.list"}')
  await waitFor('收到会话清单', () => f.peer.received.some((frame) => frame.t === 'res'))
  const sid = (responseOf(f, keys, 0).envelope['result'] as { sessions: { sid: string }[] })
    .sessions[0]?.sid

  sendRequest(
    f,
    keys,
    1,
    'req_qqqqqqqqqqqq',
    `{"method":"job.follow","params":{"sid":"${String(sid)}","jobId":"j1"}}`,
  )
  await waitFor('宿主流开起来了', () => streams.length === 1)
  streams[0]?.push({
    kind: 'opened',
    jobId: 'j1',
    from: 0,
    job: { id: 'j1', kind: 'shell', label: '构建', status: 'running', startedAt: 10, outputTotal: 0 },
  })
  await waitFor('订阅就位', () => f.subscriptions?.active === 1)

  f.connection.stop()
  await waitFor('订阅被清空', () => f.subscriptions?.active === 0)
  assert.equal(streams[0]?.signal.aborted, true, '断开即中止宿主流')
})

test('端到端：手机订会话 —— 快照补课事件逐条 ev、assistant 流走 live，退订即停', async (t) => {
  const { source, streams } = createControllableSessionSource()
  const f = await start(t, { handlers: ({ session }) => fixtureHandlers(null, session), sessionSource: source })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  sendRequest(f, keys, 0, 'req_rrrrrrrrrrrr', '{"method":"session.list"}')
  await waitFor('收到会话清单', () => f.peer.received.some((frame) => frame.t === 'res'))
  const sid = String(
    (responseOf(f, keys, 0).envelope['result'] as { sessions: { sid: string }[] }).sessions[0]?.sid,
  )

  sendRequest(
    f,
    keys,
    1,
    'req_ssssssssssss',
    `{"method":"session.subscribe","params":{"sid":"${sid}"}}`,
  )
  await waitFor('会话流开起来了', () => streams.length === 1)
  streams[0]?.push({
    kind: 'opening',
    cursor: 100,
    header: { id: 'dsh-1' } as never,
    records: [
      { event: { type: 'user/message', seq: 98, time: 1 } },
      { event: { type: 'user/message', seq: 99, time: 2 } },
    ] as never,
    hasMore: true,
  })
  await waitFor(
    '收到订阅应答与两条补课事件',
    () =>
      f.peer.received.filter((frame) => frame.t === 'res').length >= 2 &&
      f.peer.received.filter((frame) => frame.t === 'ev').length >= 2,
  )
  assert.deepEqual(
    responseOf(f, keys, 1).envelope['result'],
    { since: 100, hasMore: true },
    '回的是基线水位与"还有更早的历史"',
  )

  streams[0]?.push({
    kind: 'live',
    frame: { type: 'chunk', attemptId: 'att-1', revision: 1, index: 1, time: 9, chunk: { text: '你' } } as never,
  })
  await waitFor('收到流式帧', () => f.peer.received.some((frame) => frame.t === 'live'))

  // 手机侧用自己的实现解箱（`ev` 的 AAD 含 seq，`live` 的 AAD 只含 sid 与 fc）。
  const events = f.peer.received
    .filter((frame) => frame.t === 'ev')
    .map((frame) =>
      JSON.parse(
        phoneOpenBox({
          keys,
          header: { t: 'ev', fc: frame.fc, sid: frame.sid, seq: frame.t === 'ev' ? frame.seq : undefined },
          box: frame.box,
        }),
      ),
    )
  assert.deepEqual(
    events.map((payload) => (payload as { seq: number }).seq),
    [98, 99],
    '补课事件一条都不能少',
  )

  const liveFrame = f.peer.received.find((frame) => frame.t === 'live')
  assert.ok(liveFrame !== undefined && liveFrame.t === 'live')
  assert.equal(liveFrame.stream, 1, '`stream` 由电脑侧分配')
  assert.equal(liveFrame.rev, 1, '`rev` 用宿主的 index（手机侧据此 +1 追加）')
  assert.deepEqual(
    JSON.parse(
      phoneOpenBox({
        keys,
        header: { t: 'live', fc: liveFrame.fc, sid: liveFrame.sid },
        box: liveFrame.box,
      }),
    ),
    { type: 'chunk', time: 9, chunk: { text: '你' } },
  )

  sendRequest(
    f,
    keys,
    2,
    'req_tttttttttttt',
    `{"method":"session.unsubscribe","params":{"sid":"${sid}"}}`,
  )
  await waitFor('收到退订应答', () => f.peer.received.filter((frame) => frame.t === 'res').length >= 3)
  assert.deepEqual(responseOf(f, keys, 2).envelope['result'], { stopped: true })
  assert.equal(streams[0]?.signal.aborted, true, '退订必须真的中止会话流')
  assert.equal(f.sessionSubscriptions?.active, 0)
})

test('端到端：同一条消息重发 —— 真方法面 + 真幂等只让它入队一次（I8）', async (t) => {
  // 这条用例与上一轮那条"假 handler"的区别：这里走的是**真的** `session.prompt` 方法
  // （真的参数校验、真的信封、真的 `IDEMPOTENT_METHODS` 判定），只有最底下的 DSH 端口是替身。
  const rows = createMemoryDedupeRows()
  const promptBox = { count: 0 }
  const f = await start(t, {
    handlers: () => fixtureHandlers(null, null, promptBox),
    idempotency: createIdempotency({ rows }),
  })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  sendRequest(f, keys, 0, 'req_uuuuuuuuuuuu', '{"method":"session.list"}')
  await waitFor('收到会话清单', () => f.peer.received.some((frame) => frame.t === 'res'))
  const sid = String(
    (responseOf(f, keys, 0).envelope['result'] as { sessions: { sid: string }[] }).sessions[0]?.sid,
  )

  const payload = JSON.stringify({
    method: 'session.prompt',
    requestId: 'req-prompt-1',
    params: { sid, content: [{ type: 'text', text: '你好' }] },
  })
  // 手机的"重发"：同一个 requestId，两个不同的 fc（新的一帧）。
  sendRequest(f, keys, 1, 'req_vvvvvvvvvvvv', payload)
  await waitFor('第一个应答到达', () => f.peer.received.filter((frame) => frame.t === 'res').length >= 2)
  sendRequest(f, keys, 2, 'req_wwwwwwwwwwww', payload)
  await waitFor('第二个应答到达', () => f.peer.received.filter((frame) => frame.t === 'res').length >= 3)

  assert.equal(promptBox.count, 1, '同一个幂等键只能入队一次 —— 否则就是第二条消息')
  assert.deepEqual(responseOf(f, keys, 1).envelope['result'], { accepted: true })
  assert.deepEqual(
    responseOf(f, keys, 2).envelope,
    responseOf(f, keys, 1).envelope,
    '第二个应答是**重放**上次的结果（内容相同、id 是这一次的）',
  )
  assert.equal(responseOf(f, keys, 2).id, 'req_wwwwwwwwwwww')
})

test('端到端：连着问两件事，两个应答各自对得上自己的 id', async (t) => {
  const f = await start(t, { handlers: fixtureHandlers() })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  // 同一个手机侧计数器：两帧分别是 fc=0 / fc=1（每发一帧 +1）。
  sendRequest(f, keys, 0, 'req_cccccccccccc', '{"method":"repo.info"}')
  sendRequest(f, keys, 1, 'req_dddddddddddd', '{"method":"devices.list"}')
  await waitFor('收到两个 res', () => f.peer.received.filter((frame) => frame.t === 'res').length === 2)

  const first = responseOf(f, keys, 0)
  const second = responseOf(f, keys, 1)
  assert.equal(first.id, 'req_cccccccccccc')
  assert.equal(second.id, 'req_dddddddddddd', '并发请求也必须各回各的 id')
  assert.deepEqual(
    (second.envelope['result'] as { devices: unknown[] }).devices,
    [{ devId: 'dev-1', name: '我的手机', pairedAt: 1000, revoked: false }],
  )
})
