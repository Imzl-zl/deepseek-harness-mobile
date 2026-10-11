import assert from 'node:assert/strict'
import { test } from 'node:test'
import { PAIRING_TTL_MS, createPairing, pairingCodeHash, pairingIdOf, sasOf, type PairingOffer } from '../src/pairing.js'

const PC_ED = 'a'.repeat(64)
const PC_DH = 'b'.repeat(64)
function setup(now?: () => number) {
  let round = 0
  return createPairing({
    pcId: 'pc-test', relayUrl: 'wss://relay.example/ws', pcPubEd: PC_ED, pcPubDh: PC_DH,
    randomBytes: (size) => { round += 1; return Uint8Array.from({ length: size }, (_, i) => (round * 31 + i) % 256) },
    ...(now === undefined ? {} : { now }),
  })
}
const candidate = (offer: PairingOffer) => ({ offerId: offer.offerId, devPubEd: 'c'.repeat(64), devPubDh: 'd'.repeat(64), name: '我的手机' })
const request = (offer: PairingOffer, code = offer.code) => ({ v: 2 as const, offerId: offer.offerId, code })

test('offer：二维码固定电脑身份，对外登记只拿公开邀请', () => {
  const offer = setup().offer()
  const payload = JSON.parse(offer.payload)
  assert.equal(payload.relay, 'wss://relay.example/ws')
  assert.equal(payload.pcPubEd, PC_ED)
  assert.equal(payload.pcPubDh, PC_DH)
  assert.equal(payload.pcId, 'pc-test')
  assert.equal(payload.code, offer.code)
  assert.equal(payload.offerId, offer.offerId)
  assert.equal(payload.v, 2)
  assert.equal('codeHash' in offer, false)
  assert.ok(offer.expiresAt - Date.now() <= PAIRING_TTL_MS)
})

test('accept：身份来自候选，正常业务 pairingId 派生不变', () => {
  const pairing = setup()
  const offer = pairing.offer()
  const peer = candidate(offer)
  const accepted = pairing.accept(request(offer), peer)
  assert.ok('device' in accepted)
  assert.equal(accepted.device.name, peer.name)
  assert.equal(accepted.device.edPubHex, peer.devPubEd)
  assert.equal(accepted.device.dhPubHex, peer.devPubDh)
  assert.equal(accepted.device.pairingId, pairingIdOf(pairingCodeHash(offer.code)))
  assert.match(accepted.sas, /^\d{6}$/)
  assert.equal(pairing.pending, false)
})

test('一次性授权：同候选恢复同一结果，不能再授权另一候选', () => {
  const pairing = setup()
  const offer = pairing.offer()
  const first = pairing.accept(request(offer), candidate(offer))
  assert.ok('device' in first)
  assert.deepEqual(pairing.accept(request(offer), candidate(offer)), first)
  assert.deepEqual(pairing.accept(request(offer), { ...candidate(offer), devPubEd: 'e'.repeat(64) }), { rejected: 'consumed' })
})

test('过期邀请不再有效', () => {
  let now = 1000
  const pairing = setup(() => now)
  const offer = pairing.offer()
  now = offer.expiresAt
  assert.deepEqual(pairing.accept(request(offer), candidate(offer)), { rejected: 'expired' })
  assert.equal(pairing.pending, false)
})

test('错误秘密不消费合法邀请', () => {
  const pairing = setup()
  const offer = pairing.offer()
  assert.deepEqual(pairing.accept(request(offer, 'Z'.repeat(22)), candidate(offer)), { rejected: 'mismatch' })
  assert.equal(pairing.pending, true)
  assert.ok('device' in pairing.accept(request(offer), candidate(offer)))
})

test('重新出码使上次尚未完成的邀请失效', () => {
  const pairing = setup()
  const first = pairing.offer()
  const second = pairing.offer()
  assert.deepEqual(pairing.accept(request(first), candidate(first)), { rejected: 'mismatch' })
  assert.ok('device' in pairing.accept(request(second), candidate(second)))
})

test('既有 pairingId 与辅助 SAS 保持确定性，身份改变会改变摘要', () => {
  assert.equal(pairingIdOf('code-1'), pairingIdOf('code-1'))
  assert.notEqual(pairingIdOf('code-1'), pairingIdOf('code-2'))
  assert.equal(pairingIdOf('code-1').length, 43)
  assert.equal(pairingCodeHash('code-1').length, 64)
  assert.equal(sasOf(PC_ED, 'c'.repeat(64)), sasOf(PC_ED, 'c'.repeat(64)))
  assert.notEqual(sasOf(PC_ED, 'c'.repeat(64)), sasOf(PC_ED, 'e'.repeat(64)))
  assert.notEqual(sasOf(PC_ED, 'c'.repeat(64)), sasOf('f'.repeat(64), 'c'.repeat(64)))
})
