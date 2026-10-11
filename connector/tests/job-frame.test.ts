/**
 * `job` 帧的回归（契约 §3 的术语表、§5.3 的订阅规则）。
 *
 * 新增一种帧类型要同时过四道闸，而**漏掉哪一道都不会报错**，只会表现成内容错乱或明文外泄：
 *
 * 1. **真值只有一份**：帧类型清单在 `protocol/frame.ts` 的 `FRAME_TYPES`；编解码只是别名。
 *    （此前两份各自维护过，已经漂移出化石 `'ack'`。）
 * 2. **要封箱**：`job` 与 `ev` / `live` 一样必须走 AEAD —— 联合里加了、封箱判据里漏了，
 *    它就会**明文**发出去，而且没人会发现。
 * 3. **AAD 拼串正确**：`job` 没有 `id` / `seq`（它们是空串），但 `sid` 与 `fc` **必须**在里面；
 *    少一个字段，两端算出的 AAD 不同、帧解不开；而 `sid` 漏了会让帧可以被换会话重放。
 * 4. **可补帧集合一致**：攒批与"满窗可暂停"两处必须同时含它。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { FRAME_TYPES, needsBox } from '../src/protocol/frame.js'
import { pausable } from '../src/protocol/flow.js'
import { KNOWN_FRAME_TYPES, assertHandshakePhase } from '../src/transport/codec.js'
import { waitFor } from './support/peer.js'
import { phoneOpenBox } from './support/phone.js'
import { completeHandshake, start } from './support/secure-connection.js'

test('帧类型清单只有一份：与契约 §3 的联合逐项相等', () => {
  // 手写下期望值（而不是从别处再取一次）：这份清单是契约，改它必须是有意的。
  const contract = [
    'hello',
    'hello-ack',
    'confirm',
    'pair-commit',
    'pair-result',
    'ping',
    'pong',
    'credit',
    'req',
    'res',
    'ev',
    'live',
    'job',
    'persisted',
    'presence',
  ]
  assert.deepEqual([...FRAME_TYPES], contract)
  // 编解码那份**不是**第二份真值：同一个对象。
  assert.equal(KNOWN_FRAME_TYPES, FRAME_TYPES, 'KNOWN_FRAME_TYPES 必须是 FRAME_TYPES 的别名，不许另起一份')
})

test('配对 v2 帧必须封箱，而且握手完成前不能通过门禁', () => {
  assert.equal(needsBox('pair-commit'), true)
  assert.equal(needsBox('pair-result'), true)
  assert.equal(needsBox('req'), true)
  for (const t of ['pair-commit', 'pair-result'] as const) {
    assert.throws(() => assertHandshakePhase({ v: 1, t, id: 'p1', fc: 0, box: '{}' }, false), /只接受/)
    assert.doesNotThrow(() => assertHandshakePhase({ v: 1, t, id: 'p1', fc: 0, box: '{}' }, true))
  }
  assert.throws(() => assertHandshakePhase({ v: 1, t: 'req', id: 'r1', fc: 0, box: '{}' }, false), /只接受/)
})

test('可补帧集合：job 与 ev / live 同类（满窗时可暂停），res 不可暂停', () => {
  assert.equal(pausable('job'), true, '任务输出可以按 from 重订，所以满窗时压住它是安全的')
  assert.equal(pausable('ev'), true)
  assert.equal(pausable('live'), true)
  assert.equal(pausable('res'), false, '压住应答会死锁')
  assert.equal(pausable('credit'), false, '压住信用会让两边的窗口永远松不开')
  assert.equal(pausable('persisted'), false)
})

test('端到端：job 帧要封箱，且手机侧能用 AAD(sid|fc) 解开（漏了 sid 就能被换会话重放）', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  const payload = '{"kind":"opened","jobId":"j1","from":0}'
  assert.equal(
    f.connection.send({ v: 1, t: 'job', sid: 'sid_0123456789ab', box: payload }),
    true,
    'job 是已知帧类型，且满窗前应当被接受',
  )
  await waitFor('job 帧到达', () => f.peer.received.some((frame) => frame.t === 'job'))

  const frame = f.peer.received.find((received) => received.t === 'job')
  assert.ok(frame !== undefined && frame.t === 'job')

  // 手机侧**自己那份**实现解箱：AAD 由 (t, id, sid, seq, fc) 拼出，其中 id/seq 为空串。
  const opened = phoneOpenBox({
    keys,
    header: { t: 'job', fc: frame.fc, sid: frame.sid },
    box: frame.box,
  })
  assert.equal(opened, payload, '解出来必须是明文载荷 —— 解不开说明封箱的 AAD 与手机侧不一致')

  // 反过来：换个 sid 就解不开（AAD 里确实带了 sid，而不是只带 t 与 fc）。
  const swapped =
    f.peer.received.find((received) => received.t === 'job') ?? frame
  assert.throws(
    () =>
      phoneOpenBox({
        keys,
        header: { t: 'job', fc: swapped.fc, sid: 'sid_ffffffffffff' },
        box: swapped.box,
      }),
    'AAD 里漏掉 sid 会让同一帧能被另一个会话重放',
  )
})
