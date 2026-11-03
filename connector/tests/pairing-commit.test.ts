import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createPairing } from '../src/pairing.js'
import { createPairingEndpoint, type PairedDeviceRow } from '../src/pairing-endpoint.js'

function setup(failAnnouncement = false) {
  const pairing = createPairing({ pcId: 'pc-test', pcPubEd: 'a'.repeat(64), pcPubDh: 'b'.repeat(64), relayUrl: 'wss://relay.example' })
  const offer = pairing.offer()
  const candidate = { offerId: offer.offerId, devPubEd: 'c'.repeat(64), devPubDh: 'd'.repeat(64), name: '手机' }
  const rows: PairedDeviceRow[] = []
  let issued = 0
  let announcements = 0
  const endpoint = createPairingEndpoint({
    pcId: 'pc-test', pairing,
    issueCredentials: async () => { issued += 1; return { deviceToken: 'test-device-token', refreshToken: 'test-refresh-token' } },
    putDevice: async (_id, row) => { rows.push(row) },
    findPreviousPairing: () => null,
    announce: async () => {
      announcements += 1
      if (failAnnouncement && announcements === 1) throw new Error('临时离线')
    },
  })
  const box = JSON.stringify({ v: 2, offerId: offer.offerId, code: offer.code })
  return { endpoint, offer, candidate, rows, box, issued: () => issued, announcements: () => announcements }
}

test('配对提交：未提交秘密时不登记，重复提交不换令牌', async (t) => {
  const fixture = setup()
  t.after(() => fixture.endpoint.dispose())
  assert.equal(fixture.rows.length, 0)
  const [first, second] = await Promise.all([
    fixture.endpoint.handle(fixture.box, fixture.candidate),
    fixture.endpoint.handle(fixture.box, fixture.candidate),
  ])
  assert.equal(first.ok, true)
  assert.deepEqual(first, second)
  assert.equal(fixture.rows.length, 1)
  assert.equal(fixture.issued(), 1)
  assert.equal(JSON.stringify(fixture.rows).includes('test-device-token'), false)
  assert.deepEqual(await fixture.endpoint.handle(fixture.box, fixture.candidate), first)
  assert.equal(fixture.issued(), 1)
})

test('配对提交：名册上报失败不算配对失败（令牌照发，重试不重复登记）', async (t) => {
  const fixture = setup(true)
  t.after(() => fixture.endpoint.dispose())
  const first = await fixture.endpoint.handle(fixture.box, fixture.candidate)
  // 设备行已落盘、令牌已签发 —— 名册只是"中转那边还认不认这台设备"，
  // 而纯局域网配对根本没有中转。把它说成失败会让手机丢掉刚拿到的凭据、
  // 用户重扫，电脑侧却已经写了一行（同一台手机攒出第二行）。
  assert.equal(first.ok, true)
  assert.equal(fixture.rows.length, 1)
  assert.equal(fixture.issued(), 1)
  assert.equal(fixture.announcements(), 1)

  // 同一候选再提交：合流到同一结果，不再写行、不再发令牌，但**会重报名册**
  // （失败的那一次是"中转此刻不可用"，恢复后由重连或下一次提交补上）。
  const retried = await fixture.endpoint.handle(fixture.box, fixture.candidate)
  assert.deepEqual(retried, first)
  assert.equal(fixture.rows.length, 1)
  assert.equal(fixture.issued(), 1)
  assert.equal(fixture.announcements(), 2, '名册失败要能被下一次提交/重连补上')
})

test('配对提交：另一个候选不能取回完成结果', async (t) => {
  const fixture = setup()
  t.after(() => fixture.endpoint.dispose())
  await fixture.endpoint.handle(fixture.box, fixture.candidate)
  const foreign = await fixture.endpoint.handle(fixture.box, { ...fixture.candidate, devPubEd: 'e'.repeat(64) })
  assert.equal(foreign.ok, false)
  assert.equal(JSON.stringify(foreign).includes('test-device-token'), false)
  assert.equal(fixture.issued(), 1)
})
