/**
 * 配对端点的回归（契约 §12.1 第 3 步）。
 *
 * 这一层是安全边界，所以断言围着三件事：**什么时候必须拒**、**拒了要能说清原因**、
 * 以及**先落行再回执**（顺序反了的表现是"配对成功但连不上"）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { PAIRING_TTL_MS, createPairing, pairingCodeHash } from '../src/pairing.js'
import {
  createPairingEndpoint,
  type PairedDeviceRow,
  type PairingReply,
} from '../src/pairing-endpoint.js'

const PC_ED = 'a'.repeat(64)
const PC_DH = 'b'.repeat(64)
const DEV_ED = 'c'.repeat(64)
const DEV_DH = 'd'.repeat(64)

/** 每次调用给出不同字节，免得两次出码相同（配对用例里"旧码立刻失效"依赖它）。 */
function varyingRandom(): (size: number) => Uint8Array {
  let round = 0
  return (size) => {
    round += 1
    return Uint8Array.from({ length: size }, (_, i) => (round * 37 + i) % 256)
  }
}

function setup(patch: { putDevice?: (devId: string, row: PairedDeviceRow) => Promise<void> } = {}) {
  const pairing = createPairing({
    relayUrl: 'wss://relay.example/ws',
    pcPubEd: PC_ED,
    pcPubDh: PC_DH,
    randomBytes: varyingRandom(),
  })
  const replies: { id: string; payload: PairingReply }[] = []
  const rows: { devId: string; row: PairedDeviceRow }[] = []
  /** 记录落行与回执的先后 —— 这是这一层唯一容易被写反的顺序。 */
  const order: string[] = []

  const endpoint = createPairingEndpoint({
    pairing,
    putDevice:
      patch.putDevice ??
      ((devId, row) => {
        order.push('put')
        rows.push({ devId, row })
        return Promise.resolve()
      }),
    reply: (frame) => {
      order.push('reply')
      replies.push(frame)
    },
  })
  return { pairing, endpoint, replies, rows, order }
}

const body = (code: string): string =>
  JSON.stringify({
    codeHash: pairingCodeHash(code),
    devPubEd: DEV_ED,
    devPubDh: DEV_DH,
    name: '我的手机',
  })

test('配对请求：校验通过就落设备行并回执（含 devId 与 6 位 SAS）', async () => {
  const { pairing, endpoint, replies, rows } = setup()
  const offer = pairing.offer()

  await endpoint.handle({ id: 'p1', box: body(offer.code) })

  assert.equal(rows.length, 1, '必须落一行设备记录')
  const device = rows[0]
  assert.ok(device !== undefined)
  assert.equal(device.row.name, '我的手机')
  assert.equal(device.row.edPubHex, DEV_ED)
  assert.equal(device.row.dhPubHex, DEV_DH)
  assert.equal(device.row.pairingId.length > 0, true, 'pairingId 要落进行里（握手要用它）')

  assert.equal(replies.length, 1)
  const payload = replies[0]?.payload
  assert.ok(payload !== undefined && payload.ok, `应当成功，实际 ${JSON.stringify(payload)}`)
  assert.equal(payload.devId, device.devId, '回执里的 devId 就是刚落的那个')
  assert.match(payload.sas, /^\d{6}$/, 'SAS 是 6 位数字，用户拿它做带外核对')
})

test('配对请求：先落行、后回执（顺序反了会出现"配对成功但连不上"）', async () => {
  const { pairing, endpoint, order } = setup()
  const offer = pairing.offer()
  await endpoint.handle({ id: 'p1', box: body(offer.code) })
  assert.deepEqual(order, ['put', 'reply'])
})

test('配对请求：过期 / 不对 / 已用过，都回一个用户看得懂的原因，且**从不抛**', async () => {
  let clock = 1_000_000
  const pairing = createPairing({
    relayUrl: 'wss://relay.example/ws',
    pcPubEd: PC_ED,
    pcPubDh: PC_DH,
    now: () => clock,
    randomBytes: varyingRandom(),
  })
  const replies: PairingReply[] = []
  const endpoint = createPairingEndpoint({
    pairing,
    putDevice: () => Promise.resolve(),
    reply: (frame) => replies.push(frame.payload),
  })

  const expired = pairing.offer()
  clock += PAIRING_TTL_MS + 1
  await endpoint.handle({ id: 'p1', box: body(expired.code) })
  assert.deepEqual(replies[0], { ok: false, reason: '配对码已过期，请在电脑上重新出码' })

  const fresh = pairing.offer()
  await endpoint.handle({ id: 'p2', box: body('wrong-code') })
  assert.deepEqual(replies[1], { ok: false, reason: '配对码不对，请核对后重试' })

  await endpoint.handle({ id: 'p3', box: body(fresh.code) })
  assert.equal(replies[2]?.ok, true)

  await endpoint.handle({ id: 'p4', box: body(fresh.code) })
  assert.deepEqual(replies[3], { ok: false, reason: '这个配对码已经用过了，请在电脑上重新出码' })
})

test('配对请求：载荷不是 JSON 只回原因，**不关连接**（配对失败不是协议错误）', async () => {
  const { endpoint, replies } = setup()
  await endpoint.handle({ id: 'p1', box: 'not json' })
  assert.deepEqual(replies, [{ id: 'p1', payload: { ok: false, reason: '配对请求格式不对' } }])
})

test('配对请求：设备行写不进去就**不许**回 ok（否则手机拿着不存在的身份去握手）', async () => {
  const { pairing, endpoint, replies } = setup({
    putDevice: () => Promise.reject(new Error('磁盘满了')),
  })
  const offer = pairing.offer()
  await endpoint.handle({ id: 'p1', box: body(offer.code) })

  const payload = replies[0]?.payload
  assert.equal(payload?.ok, false, '落行失败不是配对成功')
  assert.match(payload?.ok === false ? payload.reason : '', /没能保存/)
})
