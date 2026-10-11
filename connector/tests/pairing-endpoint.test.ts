import assert from 'node:assert/strict'
import { test, type TestContext } from 'node:test'
import { createPairing, type PairingCandidate } from '../src/pairing.js'
import { createPairingEndpoint, type PairedDeviceRow } from '../src/pairing-endpoint.js'

function setup(t: TestContext, options: { now?: () => number; putDevice?: (id: string, row: PairedDeviceRow) => Promise<void> } = {}) {
  const pairing = createPairing({ pcId: 'pc-1', relayUrl: 'wss://relay.example', pcPubEd: 'a'.repeat(64), pcPubDh: 'b'.repeat(64), ...(options.now === undefined ? {} : { now: options.now }) })
  const rows: PairedDeviceRow[] = []
  const order: string[] = []
  const endpoint = createPairingEndpoint({
    pcId: 'pc-1', pairing,
    putDevice: options.putDevice ?? (async (_id, row) => { order.push('put'); rows.push(row) }),
    announce: async () => { order.push('announce') },
  })
  t.after(() => endpoint.dispose())
  const offer = pairing.offer()
  const candidate: PairingCandidate = { offerId: offer.offerId, devPubEd: 'c'.repeat(64), devPubDh: 'd'.repeat(64), name: '我的手机' }
  const body = (code = offer.code) => JSON.stringify({ v: 2, offerId: offer.offerId, code })
  return { endpoint, pairing, offer, candidate, rows, order, body }
}

test('正确秘密与候选身份登记一行，设备记录只存令牌摘要', async (t) => {
  const f = setup(t)
  const result = await f.endpoint.handle(f.body(), f.candidate)
  assert.ok(result.ok)
  assert.equal(f.rows.length, 1)
  const row = f.rows[0]!
  assert.equal(row.name, f.candidate.name)
  assert.equal(row.edPubHex, f.candidate.devPubEd)
  assert.equal(row.dhPubHex, f.candidate.devPubDh)
  assert.equal(row.pairingId.length, 43)
  assert.match(row.tokenHash!, /^[0-9a-f]{64}$/)
  assert.notEqual(row.tokenHash, result.deviceToken)
  assert.equal(JSON.stringify(f.rows).includes(result.deviceToken), false)
  assert.equal(result.pcId, 'pc-1')
  assert.match(result.sas, /^\d{6}$/)
  assert.match(result.deviceToken, /^[A-Za-z0-9_-]{22}$/)
  assert.match(result.refreshToken, /^[A-Za-z0-9_-]{22}$/)
})

test('成功结果必须在设备落盘和名册发布之后返回', async (t) => {
  const f = setup(t)
  const result = await f.endpoint.handle(f.body(), f.candidate)
  assert.ok(result.ok)
  f.order.push('reply')
  assert.deepEqual(f.order, ['put', 'announce', 'reply'])
})

test('过期、错误秘密与已归属另一候选都有明确拒绝结果', async (t) => {
  let now = 1000
  const expired = setup(t, { now: () => now })
  now = expired.offer.expiresAt
  const expiredResult = await expired.endpoint.handle(expired.body(), expired.candidate)
  assert.ok(!expiredResult.ok)
  assert.match(expiredResult.reason, /过期/)
  assert.equal(expired.rows.length, 0)

  const f = setup(t)
  const wrong = await f.endpoint.handle(f.body('Z'.repeat(22)), f.candidate)
  assert.ok(!wrong.ok)
  assert.match(wrong.reason, /不匹配/)
  assert.equal(f.rows.length, 0)
  assert.ok((await f.endpoint.handle(f.body(), f.candidate)).ok)
  const consumed = await f.endpoint.handle(f.body(), { ...f.candidate, devPubEd: 'e'.repeat(64) })
  assert.ok(!consumed.ok)
  assert.match(consumed.reason, /另一台/)
  assert.equal(f.rows.length, 1)
})

test('坏 JSON 返回配对错误而不写库', async (t) => {
  const f = setup(t)
  const result = await f.endpoint.handle('not json', f.candidate)
  assert.ok(!result.ok)
  assert.match(result.reason, /JSON/)
  assert.equal(f.rows.length, 0)
})

test('设备写库失败不能返回成功或伪称已登记', async (t) => {
  const f = setup(t, { putDevice: async () => { throw new Error('磁盘满了') } })
  const result = await f.endpoint.handle(f.body(), f.candidate)
  assert.ok(!result.ok)
  assert.equal(result.registered, false)
  assert.match(result.reason, /未能保存/)
})
