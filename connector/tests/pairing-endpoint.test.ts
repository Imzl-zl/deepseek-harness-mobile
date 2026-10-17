import assert from 'node:assert/strict'
import { test, type TestContext } from 'node:test'
import { createPairing, type PairingCandidate } from '../src/pairing.js'
import {
  createPairingEndpoint,
  findPreviousPairingRow,
  type PairedDeviceRow,
} from '../src/pairing-endpoint.js'

/** 测试用的设备表：`devId → 行`，另记操作顺序（put/remove）供断言。 */
function setup(t: TestContext, options: {
  now?: () => number
  putDevice?: (id: string, row: PairedDeviceRow) => Promise<void>
  /** 候选密钥。**第二次配对照例要换一对** —— 真实的手机每次扫码生成新密钥。 */
  keys?: { ed: string; dh: string }
} = {}) {
  const pairing = createPairing({ pcId: 'pc-1', relayUrl: 'wss://relay.example', pcPubEd: 'a'.repeat(64), pcPubDh: 'b'.repeat(64), ...(options.now === undefined ? {} : { now: options.now }) })
  const table = new Map<string, PairedDeviceRow>()
  const order: string[] = []
  const putDevice = options.putDevice ?? (async (id: string, row: PairedDeviceRow) => {
    order.push(`put:${id}`)
    table.set(id, row)
  })
  const endpoint = createPairingEndpoint({
    pcId: 'pc-1', pairing,
    putDevice,
    // 与装配层（`index.ts`）用**同一个纯函数**，别在测试里重写一份查找逻辑。
    findPreviousPairing: (pairingId) => findPreviousPairingRow([...table], pairingId),
    removeDevice: async (id: string) => {
      order.push(`remove:${id}`)
      table.delete(id)
    },
    announce: async () => { order.push('announce') },
  })
  t.after(() => endpoint.dispose())
  const offer = pairing.offer()
  const candidate: PairingCandidate = {
    offerId: offer.offerId,
    devPubEd: options.keys?.ed ?? 'c'.repeat(64),
    devPubDh: options.keys?.dh ?? 'd'.repeat(64),
    name: '我的手机',
  }
  const body = (code = offer.code, previousPairingId?: string) =>
    JSON.stringify({ v: 2, offerId: offer.offerId, code, ...(previousPairingId === undefined ? {} : { previousPairingId }) })
  return { endpoint, pairing, offer, candidate, table, order, body }
}

/** 第二次（重新）配对的密钥：与首次不同，模拟"手机扫码时生成新密钥对"。 */
const NEW_KEYS = { ed: 'e'.repeat(64), dh: 'f'.repeat(64) }

test('正确秘密与候选身份登记一行，设备记录只存令牌摘要', async (t) => {
  const f = setup(t)
  const result = await f.endpoint.handle(f.body(), f.candidate)
  assert.ok(result.ok)
  assert.equal(f.table.size, 1)
  const row = [...f.table.values()][0]!
  assert.equal(row.name, f.candidate.name)
  assert.equal(row.edPubHex, f.candidate.devPubEd)
  assert.equal(row.dhPubHex, f.candidate.devPubDh)
  assert.equal(row.pairingId.length, 43)
  assert.match(row.tokenHash!, /^[0-9a-f]{64}$/)
  assert.notEqual(row.tokenHash, result.deviceToken)
  assert.equal(JSON.stringify([...f.table]).includes(result.deviceToken), false)
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
  assert.deepEqual(f.order, [`put:${result.devId}`, 'announce', 'reply'])
})

test('过期、错误秘密与已归属另一候选都有明确拒绝结果', async (t) => {
  let now = 1000
  const expired = setup(t, { now: () => now })
  now = expired.offer.expiresAt
  const expiredResult = await expired.endpoint.handle(expired.body(), expired.candidate)
  assert.ok(!expiredResult.ok)
  assert.match(expiredResult.reason, /过期/)
  assert.equal(expired.table.size, 0)

  const f = setup(t)
  const wrong = await f.endpoint.handle(f.body('Z'.repeat(22)), f.candidate)
  assert.ok(!wrong.ok)
  assert.match(wrong.reason, /不匹配/)
  assert.equal(f.table.size, 0)
  assert.ok((await f.endpoint.handle(f.body(), f.candidate)).ok)
  const consumed = await f.endpoint.handle(f.body(), { ...f.candidate, devPubEd: 'e'.repeat(64) })
  assert.ok(!consumed.ok)
  assert.match(consumed.reason, /另一台/)
  assert.equal(f.table.size, 1)
})

test('坏 JSON 返回配对错误而不写库', async (t) => {
  const f = setup(t)
  const result = await f.endpoint.handle('not json', f.candidate)
  assert.ok(!result.ok)
  assert.match(result.reason, /JSON/)
  assert.equal(f.table.size, 0)
})

test('设备写库失败不能返回成功或伪称已登记', async (t) => {
  const f = setup(t, { putDevice: async () => { throw new Error('磁盘满了') } })
  const result = await f.endpoint.handle(f.body(), f.candidate)
  assert.ok(!result.ok)
  assert.equal(result.registered, false)
  assert.match(result.reason, /未能保存/)
})

// ---- 重新配对：换凭证、替换旧行（2026-10-17 用户："为啥每次扫都是一个新设备"）----

/** 先正常配一对（旧行），返回它的 devId 与 pairingId。 */
async function pairOnce(t: TestContext): Promise<{
  table: Map<string, PairedDeviceRow>
  oldDevId: string
  oldPairingId: string
  oldPairedAt: number
}> {
  const f = setup(t)
  const result = await f.endpoint.handle(f.body(), f.candidate)
  assert.ok(result.ok)
  const old = [...f.table.entries()][0]!
  return { table: f.table, oldDevId: old[0], oldPairingId: old[1].pairingId, oldPairedAt: old[1].pairedAt }
}

test('previousPairingId 命中旧行：换密钥换令牌写进行，旧行删除，pairedAt 保留首次配对', async (t) => {
  const first = await pairOnce(t)
  // 第二次配对：新密钥（新 devId）+ 自报旧 pairingId。用同一份 pairing 再出一张码。
  const f = setup(t, { keys: NEW_KEYS })
  // 把第一次的表搬过来（两个 setup 各有一份 pairing；这里只用第二次的 offer）。
  for (const [id, row] of first.table) f.table.set(id, row)
  const result = await f.endpoint.handle(
    f.body(f.offer.code, first.oldPairingId),
    f.candidate,
  )
  assert.ok(result.ok)
  assert.equal(f.table.size, 1, '替换而不是新增：还是 1 行')
  const row = f.table.get(result.devId)
  assert.ok(row !== undefined, '新行按新 devId 写入')
  assert.notEqual(result.devId, first.oldDevId, '密钥换了 ⇒ devId 换')
  assert.equal(row.pairingId.length, 43)
  assert.notEqual(row.pairingId, first.oldPairingId, 'pairingId 换了（新配对码派生）')
  assert.equal(row.pairedAt, first.oldPairedAt, 'pairedAt 保留首次配对时刻')
  assert.equal(f.table.has(first.oldDevId), false, '旧行被删除')
  assert.equal(f.order.includes(`remove:${first.oldDevId}`), true, '删的是旧 devId 那一行')
})

test('previousPairingId 没命中（首配/凭据丢过/被清理过）：照旧写新行，不删任何行', async (t) => {
  const first = await pairOnce(t)
  const f = setup(t, { keys: NEW_KEYS })
  for (const [id, row] of first.table) f.table.set(id, row)
  const result = await f.endpoint.handle(f.body(f.offer.code, 'X'.repeat(43)), f.candidate)
  assert.ok(result.ok)
  assert.equal(f.table.size, 2, '没有旧行可替换就写新行')
  assert.equal(f.table.has(first.oldDevId), true, '旧行原样留着')
  assert.equal(f.order.some((entry) => entry.startsWith('remove:')), false, '没有删除动作')
})

test('不带 previousPairingId（首配形状）：行为与从前一致', async (t) => {
  const f = setup(t)
  const result = await f.endpoint.handle(f.body(), f.candidate)
  assert.ok(result.ok)
  assert.equal(f.table.size, 1)
  assert.equal(f.order.some((entry) => entry.startsWith('remove:')), false)
})

test('previousPairingId 格式不对 → 拒（invalid），不写库也不删行', async (t) => {
  const first = await pairOnce(t)
  const f = setup(t)
  for (const [id, row] of first.table) f.table.set(id, row)
  // 43 字符 base64url 之外的一切形状（含 42/44 字符、非法字符、非字符串）。
  for (const bad of ['X'.repeat(42), 'X'.repeat(44), 'X'.repeat(43).replace('X', '!'), 42]) {
    const result = await f.endpoint.handle(
      JSON.stringify({ v: 2, offerId: f.offer.offerId, code: f.offer.code, previousPairingId: bad }),
      f.candidate,
    )
    // 第一个坏值之后 offer 已被本次 accept 绑定/消耗，后续只验证"都没写新行"。
    assert.ok(!result.ok, `${JSON.stringify(bad)} 应被拒`)
    if (result.ok === false && 'reason' in result) assert.match(result.reason, /不合法|拒绝/)
  }
  assert.equal(f.table.size, 1, '表还是原来那一行')
})

test('替换是幂等的：同一候选重复提交不会删第二次或写第二行', async (t) => {
  const first = await pairOnce(t)
  const f = setup(t, { keys: NEW_KEYS })
  for (const [id, row] of first.table) f.table.set(id, row)
  const payload = f.body(f.offer.code, first.oldPairingId)
  const [a, b] = await Promise.all([
    f.endpoint.handle(payload, f.candidate),
    f.endpoint.handle(payload, f.candidate),
  ])
  assert.ok(a.ok && b.ok)
  assert.deepEqual(a, b)
  assert.equal(f.table.size, 1, '还是 1 行')
  assert.equal(f.order.filter((entry) => entry.startsWith('remove:')).length, 1, '旧行只删一次')
})

test('findPreviousPairingRow：停用的旧行也命中（重新扫码就是恢复路径）', () => {
  const rows = new Map<string, { pairingId: string; pairedAt: number; revokedAt?: number }>([
    ['dev-a', { pairingId: 'p'.repeat(43), pairedAt: 1000 }],
    ['dev-b', { pairingId: 'q'.repeat(43), pairedAt: 2000, revokedAt: 3000 }],
  ])
  assert.deepEqual(findPreviousPairingRow(rows, 'q'.repeat(43)), { devId: 'dev-b', pairedAt: 2000 })
  assert.equal(findPreviousPairingRow(rows, 'z'.repeat(43)), null)
})
