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
import { waitFor } from './support/peer.js'
import { phoneOpenBox, phoneSealBox } from './support/phone.js'
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
  assert.deepEqual(info.methods, ['devices.list', 'repo.info'], '实现了哪些方法也由同一张表报出')
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
