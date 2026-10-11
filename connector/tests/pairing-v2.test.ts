import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createPairing, pairingCodeHash } from '../src/pairing.js'

const PC_ED = 'a'.repeat(64)
const PC_DH = 'b'.repeat(64)
const DEV_ED = 'c'.repeat(64)
const DEV_DH = 'd'.repeat(64)

function setup() {
  let clock = 1000
  let round = 0
  const pairing = createPairing({
    pcId: 'pc-test',
    pcPubEd: PC_ED,
    pcPubDh: PC_DH,
    relayUrl: 'wss://relay.example/ws/connector',
    now: () => clock,
    randomBytes: (size) => Uint8Array.from({ length: size }, () => ++round % 256),
  })
  const offer = pairing.offer()
  const candidate = { offerId: offer.offerId, devPubEd: DEV_ED, devPubDh: DEV_DH, name: '测试手机' }
  const commit = { v: 2 as const, offerId: offer.offerId, code: offer.code }
  return { pairing, offer, candidate, commit, advance: (ms: number) => { clock += ms } }
}

test('安全回归：中转可见的旧 codeHash 不能登记设备', () => {
  const { pairing, offer, candidate } = setup()
  const result = pairing.accept({
    codeHash: pairingCodeHash(offer.code),
    devPubEd: DEV_ED,
    devPubDh: DEV_DH,
    name: '中转自行构造的设备',
  } as never, candidate)
  assert.ok('rejected' in result, '哈希不是秘密的安全替身，旧明文请求必须拒绝')
  assert.equal(pairing.pending, true, '无效请求不能消费真正的二维码')
})

test('首配 v2：公开邀请与秘密独立，二维码固定电脑身份', () => {
  const { offer } = setup()
  const qr = JSON.parse(offer.payload)
  assert.equal(qr.v, 2)
  assert.equal(qr.pcId, 'pc-test')
  assert.equal(qr.offerId, offer.offerId)
  assert.notEqual(qr.offerId, qr.code)
  assert.equal('codeHash' in offer, false, '登记端不得从 offer 取得授权校验值')
  assert.match(qr.offerId, /^[A-Za-z0-9_-]{22}$/)
  assert.match(qr.code, /^[A-Za-z0-9_-]{22}$/)
})

test('首配 v2：公开 offerId 不能代替秘密', () => {
  const { pairing, candidate, commit, offer } = setup()
  assert.deepEqual(pairing.accept({ ...commit, code: offer.offerId }, candidate), { rejected: 'mismatch' })
  assert.equal(pairing.pending, true)
  assert.ok(!('rejected' in pairing.accept(commit, candidate)))
})

test('首配 v2：同候选可恢复结果，另一公钥不能认领同一授权', () => {
  const { pairing, candidate, commit } = setup()
  const first = pairing.accept(commit, candidate)
  assert.ok(!('rejected' in first))
  assert.equal(pairing.pending, false)
  assert.deepEqual(pairing.accept(commit, candidate), first)
  assert.deepEqual(pairing.accept(commit, { ...candidate, devPubEd: 'e'.repeat(64) }), { rejected: 'consumed' })
})

test('首配 v2：候选与邀请绑定，坏公钥不能消费合法邀请', () => {
  const { pairing, candidate, commit } = setup()
  assert.deepEqual(pairing.accept(commit, { ...candidate, offerId: 'z'.repeat(22) }), { rejected: 'mismatch' })
  assert.deepEqual(pairing.accept(commit, { ...candidate, devPubDh: 'not-a-key' }), { rejected: 'invalid' })
  assert.equal(pairing.pending, true)
})

test('首配 v2：过期与重新出码不会恢复旧授权', () => {
  const { pairing, offer, candidate, commit, advance } = setup()
  advance(offer.expiresAt)
  assert.deepEqual(pairing.accept(commit, candidate), { rejected: 'expired' })
  pairing.offer()
  assert.deepEqual(pairing.accept(commit, candidate), { rejected: 'mismatch' })
})
