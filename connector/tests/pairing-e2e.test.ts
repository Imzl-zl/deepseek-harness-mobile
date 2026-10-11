/** 首配 v2：保留首配、业务互通、重连、清空中转与拒绝凭据等原有场景，并加入敌对中转反例。 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { deriveIdentity } from '../src/protocol/crypto.js'
import { pairingCodeHash } from '../src/pairing.js'
import { startChain, connectPhone, ticketByCandidate, waitFor } from './support/pairing-chain.js'

const PHONE = 'c3'.repeat(32)
const OTHER = 'd4'.repeat(32)

test('首配：握手不授权，确认后才登记，长期令牌只在密文中传输', async (t) => {
  const chain = await startChain(t)
  const offer = await chain.issueCode()
  const phone = await connectPhone(t, chain, { seed: PHONE, offer })
  assert.equal(chain.devices.size, 0, '握手结束仍是候选，未确认不能登记')
  const ack = await phone.commit()
  assert.ok(ack.ok)
  assert.match(ack.deviceToken, /^[A-Za-z0-9_-]{22}$/)
  assert.match(ack.refreshToken, /^[A-Za-z0-9_-]{22}$/)
  assert.equal(ack.devId, phone.deviceId)
  assert.equal(ack.pcId, 'conn-1')
  assert.match(ack.sas, /^\d{6}$/)
  const row = chain.devices.get(ack.devId)
  assert.ok(row)
  assert.equal(row.edPubHex, deriveIdentity(PHONE).sign.publicKeyHex)
  assert.equal(row.tokenHash?.length, 64)
  assert.notEqual(row.tokenHash, ack.deviceToken)
  const result = phone.raw.join('')
  assert.equal(result.includes(ack.deviceToken), false)
  assert.equal(result.includes(ack.refreshToken), false)
  assert.equal(result.includes(offer.code), false)
  assert.match(result, /pair-result/)
  assert.match(result, /"fc":/)
  assert.deepEqual(await phone.commit(), ack, '同一候选重试必须复用授权结果')
})

test('数据面：正式令牌换票后可以双向 AEAD，反复重连不重启连接器', async (t) => {
  const chain = await startChain(t)
  const offer = await chain.issueCode()
  const candidate = await connectPhone(t, chain, { seed: PHONE, offer })
  const ack = await candidate.commit()
  assert.ok(ack.ok)
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const phone = await connectPhone(t, chain, { seed: PHONE, offer, token: ack.deviceToken })
    const response = await phone.request('repo.info')
    assert.equal(response['ok'], true)
    assert.equal((response['result'] as { protocol: number }).protocol, 1)
    phone.socket.close()
    await waitFor('本设备数据连接关闭', () => chain.connections.get(phone.deviceId)?.state !== 'serving')
  }
})

test('多设备：第二台上线和第一台重连不会破坏另一条数据连接', async (t) => {
  const chain = await startChain(t)
  const firstOffer = await chain.issueCode()
  const firstCandidate = await connectPhone(t, chain, { seed: PHONE, offer: firstOffer })
  const firstAck = await firstCandidate.commit()
  assert.ok(firstAck.ok)
  const first = await connectPhone(t, chain, { seed: PHONE, offer: firstOffer, token: firstAck.deviceToken })
  const secondOffer = await chain.issueCode()
  const secondCandidate = await connectPhone(t, chain, { seed: OTHER, offer: secondOffer })
  const secondAck = await secondCandidate.commit()
  assert.ok(secondAck.ok)
  const second = await connectPhone(t, chain, { seed: OTHER, offer: secondOffer, token: secondAck.deviceToken })
  assert.equal((await first.request('repo.info'))['ok'], true)
  assert.equal((await second.request('repo.info'))['ok'], true)
  first.socket.close()
  const resumed = await connectPhone(t, chain, { seed: PHONE, offer: firstOffer, token: firstAck.deviceToken })
  assert.equal((await resumed.request('repo.info'))['ok'], true)
  assert.equal((await second.request('repo.info'))['ok'], true)
})

test('I7：中转真的换进程后，正式设备仅凭名册恢复；旧邀请失效', async (t) => {
  const chain = await startChain(t)
  const offer = await chain.issueCode()
  const candidate = await connectPhone(t, chain, { seed: PHONE, offer })
  const ack = await candidate.commit()
  assert.ok(ack.ok)
  await chain.restartRelay()
  const identity = deriveIdentity(PHONE)
  await assert.rejects(ticketByCandidate(chain, { offerId: offer.offerId, devPubEd: identity.sign.publicKeyHex, devPubDh: identity.dh.publicKeyHex, name: '测试手机' }), /409/)
  const resumed = await connectPhone(t, chain, { seed: PHONE, offer, token: ack.deviceToken })
  assert.equal((await resumed.request('repo.info'))['ok'], true)
})

test('公开邀请可重复发现，但不能用公开标识或旧哈希完成授权', async (t) => {
  const chain = await startChain(t)
  const offer = await chain.issueCode()
  const identity = deriveIdentity(PHONE)
  const publicCandidate = { offerId: offer.offerId, devPubEd: identity.sign.publicKeyHex, devPubDh: identity.dh.publicKeyHex, name: '测试手机' }
  assert.ok((await ticketByCandidate(chain, publicCandidate)).length > 0)
  assert.ok((await ticketByCandidate(chain, publicCandidate)).length > 0)
  const phone = await connectPhone(t, chain, { seed: PHONE, offer })
  assert.equal((await phone.commit(offer.offerId)).ok, false)
  assert.equal(chain.devices.size, 0)
  const legacy = await fetch(`${chain.httpBase}/ws-ticket`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ codeHash: pairingCodeHash(offer.code) }) })
  assert.equal(legacy.status, 426)
  assert.equal((await phone.commit()).ok, true)
})

test('中转替换候选签名公钥，手机不能完成配对握手', async (t) => {
  const chain = await startChain(t)
  const offer = await chain.issueCode()
  const own = deriveIdentity(PHONE)
  const foreign = deriveIdentity(OTHER)
  await assert.rejects(connectPhone(t, chain, {
    seed: PHONE, offer,
    advertised: { offerId: offer.offerId, devPubEd: foreign.sign.publicKeyHex, devPubDh: own.dh.publicKeyHex, name: '测试手机' },
  }))
  assert.equal(chain.devices.size, 0)
})

test('候选加密成功也不能调用业务；无效正式令牌仍是 401', async (t) => {
  const chain = await startChain(t)
  const offer = await chain.issueCode()
  const phone = await connectPhone(t, chain, { seed: PHONE, offer })
  await assert.rejects(phone.request('repo.info'), /关闭/)
  assert.equal(chain.devices.size, 0)
  const response = await fetch(`${chain.httpBase}/ws-ticket`, {
    method: 'POST', headers: { authorization: 'Bearer invalid', 'content-type': 'application/json' }, body: '{}',
  })
  assert.equal(response.status, 401)
})
