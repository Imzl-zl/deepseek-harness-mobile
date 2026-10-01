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

function fixtureHandlers() {
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
    },
  })
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
    ['devices.list', 'job.kill', 'job.list', 'repo.info', 'session.list'],
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
