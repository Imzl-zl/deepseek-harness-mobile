/**
 * 流控的连接级回归（契约 §4.3）。
 *
 * 这一层的两条规则**只有放在真连接上才测得到**：
 *
 * 1. **收到帧立刻回 `credit`**，而 `credit` 的箱里带的是**被确认的那个 `fc`**
 *    （不是本帧自己的序号）—— 两端理解不一致时，单侧测试全是绿的，只有互通才断。
 * 2. **满窗只压可补帧**（`ev` / `live`）：压住 `res` 会死锁（对端在等应答），
 *    压住 `credit` 会让两边的窗口永远松不开。
 *
 * 手机侧一律用 `support/phone.ts` 里自己那份封箱实现，所以这些用例同时也在验
 * "两个独立实现能不能对上"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { SEND_WINDOW_FRAMES } from '../src/protocol/flow.js'
import type { SessionKeys } from '../src/protocol/crypto.js'
import { waitFor } from './support/peer.js'
import { phoneOpenBox, phoneSealBox } from './support/phone.js'
import { completeHandshake, start, type Fixture } from './support/secure-connection.js'

/** 手机侧封一帧并直接发出去（`fc` 由调用方给：它就是手机自己的计数器）。 */
function sendSealed(
  f: Fixture,
  keys: SessionKeys,
  frame: { t: 'req' | 'credit'; fc: number; id?: string; sid?: string; seq?: number },
  plaintext: string,
): void {
  f.peer.send({
    v: 1,
    t: frame.t,
    ...(frame.id === undefined ? {} : { id: frame.id }),
    ...(frame.sid === undefined ? {} : { sid: frame.sid }),
    ...(frame.seq === undefined ? {} : { seq: frame.seq }),
    fc: frame.fc,
    box: phoneSealBox({ keys, header: { t: frame.t, fc: frame.fc, id: frame.id, sid: frame.sid, seq: frame.seq }, plaintext }),
  })
}

/** 从对端收到的帧里挑出电脑侧发出的 `credit`，并用**手机侧实现**解开它的 `ack`。 */
function ackOf(f: Fixture, keys: SessionKeys): number | undefined {
  const credit = f.peer.received.find((frame) => frame.t === 'credit')
  if (credit === undefined || credit.t !== 'credit') return undefined
  const opened = phoneOpenBox({
    keys,
    header: { t: 'credit', fc: credit.fc },
    box: credit.box,
  })
  return (JSON.parse(opened) as { ack: number }).ack
}

test('端到端：收到一帧立刻回 credit，且 ack 是被确认的那个 fc', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  sendSealed(f, keys, { t: 'req', fc: 0, id: 'req_0123456789ab' }, '{"method":"repo.info"}')
  await waitFor('上层收到 req', () => f.frames.length === 1)
  await waitFor('电脑侧回了 credit', () => f.peer.received.some((frame) => frame.t === 'credit'))

  const credit = f.peer.received.find((frame) => frame.t === 'credit')
  assert.ok(credit !== undefined && credit.t === 'credit')
  // `credit` 自己的 `fc` 是**电脑侧**的计数器（这里是它握手后的第一帧，所以是 0）。
  assert.equal(credit.fc, 0, 'credit 的 fc 是它自己的帧序号')
  // 被确认的序号在箱里 —— 手机侧用自己那份实现解开它。
  assert.equal(ackOf(f, keys), 0, '箱里应当是"我已收到 [0, 0]"')
})

test('端到端：credit 自己不再回 credit（否则两端互刷 ack）', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  const before = f.peer.received.length
  sendSealed(f, keys, { t: 'credit', fc: 0 }, '{"ack":0}')

  // 给对端足够的时间"如果它要回就回了"。
  await new Promise((resolve) => setTimeout(resolve, 120))
  assert.equal(
    f.peer.received.length,
    before,
    '收到 credit 之后不该再发任何帧 —— 回了就成了两端互相刷 ack',
  )
})

test('端到端：满窗压住可补帧，收到 credit 再放出去（暂停而不是丢弃）', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  // 一次性推 130 帧：窗口只有 128，多出来的两帧该被压住而不是丢掉。
  const total = SEND_WINDOW_FRAMES + 2
  for (let seq = 1; seq <= total; seq += 1) {
    assert.equal(
      f.connection.send({ v: 1, t: 'ev', sid: 'sid_0123456789ab', seq, box: `{"n":${seq}}` }),
      true,
      `第 ${seq} 帧应当被接受（入队）`,
    )
  }

  await waitFor('前 128 帧到达', () => f.peer.received.filter((frame) => frame.t === 'ev').length >= SEND_WINDOW_FRAMES)
  // 停一会儿确认没有第 129 帧偷跑出去。
  await new Promise((resolve) => setTimeout(resolve, 120))
  assert.equal(
    f.peer.received.filter((frame) => frame.t === 'ev').length,
    SEND_WINDOW_FRAMES,
    '满窗之后不该再发可补帧',
  )

  // 窗口满时 `send` 必须如实回 false（调用方据此暂停，而不是以为发出去了）。
  assert.equal(
    f.connection.send({ v: 1, t: 'ev', sid: 'sid_0123456789ab', seq: 999, box: '{}' }),
    false,
    '满窗时 send 应当拒绝可补帧',
  )

  // 手机确认到 127 → 窗口松开 → 被压住的两帧立刻放出去。
  sendSealed(f, keys, { t: 'credit', fc: 0 }, '{"ack":127}')
  await waitFor(
    '被压住的两帧到达',
    () => f.peer.received.filter((frame) => frame.t === 'ev').length === total,
  )
})

test('端到端：满窗时 res 照发（压住它会死锁）', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  await completeHandshake(f)

  // 先把窗口塞满。
  for (let seq = 1; seq <= SEND_WINDOW_FRAMES; seq += 1) {
    f.connection.send({ v: 1, t: 'ev', sid: 'sid_0123456789ab', seq, box: `{"n":${seq}}` })
  }
  await waitFor('窗口被塞满', () => f.peer.received.filter((frame) => frame.t === 'ev').length >= SEND_WINDOW_FRAMES)
  assert.equal(f.connection.send({ v: 1, t: 'live', sid: 'sid_0123456789ab', stream: 1, rev: 1, box: '{}' }), false)

  // `res` 是对端在等的应答：窗口满也照发，否则手机永远等不到回应。
  assert.equal(
    f.connection.send({ v: 1, t: 'res', id: 'req_0123456789ab', ok: true, box: '{"result":1}' }),
    true,
    '满窗时 res 必须照发',
  )
  await waitFor('res 到达', () => f.peer.received.some((frame) => frame.t === 'res'))

  // `persisted` 是正确性依赖的水位，同理不该被压住。
  assert.equal(
    f.connection.send({ v: 1, t: 'persisted', sid: 'sid_0123456789ab', seq: 5, box: '' }),
    true,
    '满窗时 persisted 必须照发',
  )
})
