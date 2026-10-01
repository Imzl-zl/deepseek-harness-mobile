/**
 * 配对帧在连接层的回归（契约 §3 的明文例外、§12.1）。
 *
 * 配对与握手一样发生在**密钥建立之前**，所以它要过两道与业务帧不同的闸：
 * ① 未握手时也能收（走 `onFrame`，那时还没有"这属于哪个设备"可言）；
 * ② 未握手时也能发，而且**不盖 `fc`**、不封箱（那时没有密钥，谈封箱没有意义）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { pairingCodeHash } from '../src/pairing.js'
import { waitFor } from './support/peer.js'
import { start } from './support/secure-connection.js'

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms))

test('配对帧：未握手就能收能发，明文且不盖 fc，全程不关连接', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')

  // 入站：手机发 `pair`。它必须在**服务态之前**送到上层 —— 否则配对永远做不成。
  f.peer.send({ v: 1, t: 'pair', id: 'p1', box: '{"codeHash":"abc"}' })
  await waitFor('上层收到 pair', () => f.frames.some((frame) => frame.t === 'pair'))
  assert.equal(f.connection.state, 'handshake', '配对本身不该把连接推进到服务态')

  // 出站：回执走**收窄**入口（`send()` 在这个阶段恒为 false，放宽它等于给"握手期发业务帧"开口子）。
  f.connection.sendPairingFrame({ v: 1, t: 'pair-ack', id: 'p1', box: '{"ok":true}' })
  await waitFor('对端收到 pair-ack', () => f.peer.received.some((frame) => frame.t === 'pair-ack'))

  const ack = f.peer.received.find((frame) => frame.t === 'pair-ack')
  assert.ok(ack !== undefined)
  assert.equal('fc' in ack, false, '配对帧不盖 fc（§3 的形状里没有它）')
  assert.equal(ack.box, '{"ok":true}', '明文：box 里就是载荷本身')
  assert.deepEqual(f.closes, [], '配对全程不该关连接（失败也要能回执，手机要能显示原因）')
})

test('端到端：手机发 pair → 电脑侧落设备行 → 明文回执（真 socket，不是单测替身）', async (t) => {
  const pcEd = 'a'.repeat(64)
  const pcDh = 'b'.repeat(64)
  const f = await start(t, { pairing: { pcPubEd: pcEd, pcPubDh: pcDh } })
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')

  const offer = f.pairing?.offer()
  assert.ok(offer !== undefined, '给了 pairing 就该能出码')

  f.peer.send({
    v: 1,
    t: 'pair',
    id: 'p1',
    box: JSON.stringify({
      codeHash: pairingCodeHash(offer.code),
      devPubEd: 'c'.repeat(64),
      devPubDh: 'd'.repeat(64),
      name: '我的手机',
    }),
  })
  await waitFor('收到回执', () => f.pairingReplies.length === 1)

  const payload = f.pairingReplies[0]
  assert.ok(payload !== undefined && payload.ok, `应当配对成功，实际 ${JSON.stringify(payload)}`)
  assert.equal(f.pairingDevices.size, 1, '设备行要落下来（握手靠它认人）')
  const [devId, row] = [...f.pairingDevices.entries()][0] ?? ['', undefined]
  assert.equal(devId, payload.devId, '回执里的 devId 就是落下的那一行')
  assert.equal(row?.edPubHex, 'c'.repeat(64))
  assert.equal(row?.pairingId.length > 0, true, 'pairingId 要落进行里 —— 握手用它参与密钥派生')

  // 明文回执真的过线了（并且没有 `fc`）。
  await waitFor('对端收到 pair-ack', () => f.peer.received.some((frame) => frame.t === 'pair-ack'))
  const ack = f.peer.received.find((frame) => frame.t === 'pair-ack')
  assert.ok(ack !== undefined)
  assert.equal('fc' in ack, false)
  assert.deepEqual(f.closes, [], '配对全程不关连接')
})

test('配对入口是收窄的：递别的帧进去只会留声，不会发出去', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')

  f.connection.sendPairingFrame({ v: 1, t: 'req', id: 'r1', fc: 0, box: '{}' })
  await sleep(50)
  assert.equal(
    f.peer.received.some((frame) => frame.t === 'req'),
    false,
    '业务帧不许借配对入口在握手期溜出去',
  )
})
