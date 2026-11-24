import assert from 'node:assert/strict'
import { test, type TestContext } from 'node:test'
import { createPairing, type PairingCandidate } from '../src/pairing.js'
import {
  createPairingEndpoint,
  findPreviousPairingRow,
  replacedRowsOf,
  type PairedDeviceRow,
} from '../src/pairing-endpoint.js'

/** 测试用的设备表：`devId → 行`，另记 put 顺序供断言（提交这一步**不删行**）。 */
function setup(t: TestContext, options: {
  now?: () => number
  putDevice?: (id: string, row: PairedDeviceRow) => Promise<void>
  /** 候选密钥。**第二次配对照例要换一对** —— 真实的手机每次扫码生成新密钥。 */
  keys?: { ed: string; dh: string }
  announce?: () => Promise<void>
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
    findPreviousPairing: (pairingId, deviceCode) => findPreviousPairingRow([...table], pairingId, deviceCode),
    announce: options.announce ?? (async () => { order.push('announce') }),
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
  assert.match(result.reason, /未能保存/)
  assert.equal(f.table.size, 0, '写库失败 = 这台设备没配上，表里不能有它')
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

test('previousPairingId 命中旧行：新行记下 replaces，旧行**先留着**（等新身份连上再裁）', async (t) => {
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
  const row = f.table.get(result.devId)
  assert.ok(row !== undefined, '新行按新 devId 写入')
  assert.notEqual(result.devId, first.oldDevId, '密钥换了 ⇒ devId 换')
  assert.equal(row.pairingId.length, 43)
  assert.notEqual(row.pairingId, first.oldPairingId, 'pairingId 换了（新配对码派生）')
  assert.equal(row.pairedAt, first.oldPairedAt, 'pairedAt 保留首次配对时刻')
  assert.equal(row.replaces, first.oldDevId, '新行写明它替换了谁')
  // **旧行必须还在**：`pair-result` 可能没送到手机，那时手机手里仍是旧凭据；
  // 提前删掉就成了孤儿（现场症状："凭据莫名失效" → 清凭据 → 白扫一次码）。
  assert.equal(f.table.has(first.oldDevId), true, '旧行留到新身份握手成功')
  assert.equal(replacedRowsOf([...f.table], result.devId).length, 1, '连上之后能算出要裁的那一行')
  assert.deepEqual(replacedRowsOf([...f.table], result.devId), [first.oldDevId])
})

test('previousPairingId 没命中（首配/凭据丢过/被清理过）：照旧写新行，不删任何行', async (t) => {
  const first = await pairOnce(t)
  const f = setup(t, { keys: NEW_KEYS })
  for (const [id, row] of first.table) f.table.set(id, row)
  const result = await f.endpoint.handle(f.body(f.offer.code, 'X'.repeat(43)), f.candidate)
  assert.ok(result.ok)
  assert.equal(f.table.size, 2, '没有旧行可替换就写新行')
  assert.equal(f.table.has(first.oldDevId), true, '旧行原样留着')
})

test('不带 previousPairingId（首配形状）：行为与从前一致', async (t) => {
  const f = setup(t)
  const result = await f.endpoint.handle(f.body(), f.candidate)
  assert.ok(result.ok)
  assert.equal(f.table.size, 1)
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

test('替换是幂等的：同一候选重复提交不会写第二行新行', async (t) => {
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
  assert.equal(f.table.size, 2, '旧行 + 新行；旧行的裁剪等新身份连上（不是提交这一步）')
  assert.equal(
    f.order.filter((entry) => entry === `put:${a.devId}`).length,
    1,
    '同一次邀请只写一次新行',
  )
})

test('findPreviousPairingRow：停用的旧行也命中（重新扫码就是恢复路径）', () => {
  const rows = new Map<string, { pairingId: string; pairedAt: number; revokedAt?: number }>([
    ['dev-a', { pairingId: 'p'.repeat(43), pairedAt: 1000 }],
    ['dev-b', { pairingId: 'q'.repeat(43), pairedAt: 2000, revokedAt: 3000 }],
  ])
  assert.deepEqual(findPreviousPairingRow(rows, 'q'.repeat(43)), { devId: 'dev-b', pairedAt: 2000 })
  assert.equal(findPreviousPairingRow(rows, 'z'.repeat(43)), null)
})


const DEVICE_CODE = 'abcdefghijklmnopqrstuv'
test('仅设备码也能定位上次配对，仍写新鉴权身份并保留旧行到握手', { timeout: 60_000 }, async (t) => {
  const first = setup(t)
  const a = await first.endpoint.handle(JSON.stringify({ v: 2, offerId: first.offer.offerId, code: first.offer.code, deviceCode: DEVICE_CODE }), first.candidate)
  assert.ok(a.ok)
  const next = setup(t, { keys: NEW_KEYS })
  for (const row of first.table) next.table.set(...row)
  const b = await next.endpoint.handle(JSON.stringify({ v: 2, offerId: next.offer.offerId, code: next.offer.code, deviceCode: DEVICE_CODE }), next.candidate)
  assert.ok(b.ok)
  assert.notEqual(a.devId, b.devId)
  assert.equal(next.table.get(b.devId)?.deviceCode, DEVICE_CODE)
  assert.equal(next.table.get(b.devId)?.replaces, a.devId)
  assert.equal(next.table.size, 2)
  assert.deepEqual(replacedRowsOf(next.table, b.devId), [a.devId])
})
test('精确 previousPairingId 将旧无设备码行关联到新设备码', { timeout: 60_000 }, async (t) => {
  const first = await pairOnce(t)
  const next = setup(t, { keys: NEW_KEYS })
  for (const row of first.table) next.table.set(...row)
  const result = await next.endpoint.handle(JSON.stringify({ v: 2, offerId: next.offer.offerId, code: next.offer.code, previousPairingId: first.oldPairingId, deviceCode: DEVICE_CODE }), next.candidate)
  assert.ok(result.ok)
  assert.equal(next.table.get(result.devId)?.deviceCode, DEVICE_CODE)
  assert.equal(next.table.get(result.devId)?.replaces, first.oldDevId)
  assert.equal(next.table.get(result.devId)?.pairedAt, first.oldPairedAt)
})
test('同名不同设备码不定位成同一个设备', { timeout: 60_000 }, async (t) => {
  const first = setup(t)
  const a = await first.endpoint.handle(JSON.stringify({ v: 2, offerId: first.offer.offerId, code: first.offer.code, deviceCode: DEVICE_CODE }), first.candidate)
  assert.ok(a.ok)
  const next = setup(t, { keys: NEW_KEYS })
  for (const row of first.table) next.table.set(...row)
  const b = await next.endpoint.handle(JSON.stringify({ v: 2, offerId: next.offer.offerId, code: next.offer.code, deviceCode: 'ZYXWVUTSRQPONMLKJIHGFE' }), next.candidate)
  assert.ok(b.ok)
  assert.equal(next.table.get(b.devId)?.replaces, undefined)
  assert.deepEqual(replacedRowsOf(next.table, b.devId), [])
})
test('设备码多行全部列入旧集合，不用pairedAt猜代次，精确旧标识支持迁移', { timeout: 60_000 }, () => {
  const rows = new Map([
    ['newer', { pairingId: 'b'.repeat(43), pairedAt: 20, deviceCode: DEVICE_CODE }],
    ['first', { pairingId: 'a'.repeat(43), pairedAt: 10, deviceCode: DEVICE_CODE }],
    ['legacy', { pairingId: 'l'.repeat(43), pairedAt: 5 }],
  ])
  assert.deepEqual(findPreviousPairingRow(rows, '', DEVICE_CODE), { devId: 'newer', pairedAt: 20, replacesAll: ['first', 'newer'] })
  assert.deepEqual(findPreviousPairingRow(rows, 'l'.repeat(43), DEVICE_CODE), { devId: 'legacy', pairedAt: 5, replacesAll: ['first', 'legacy', 'newer'] })
})
test('多代未用身份：沿 replaces 传递裁旧行，不遗留最初 legacy 行', { timeout: 60_000 }, () => {
  const rows = new Map([
    ['a', {}], ['b', { replaces: 'a' }], ['c', { replaces: 'b' }], ['unrelated', {}],
  ])
  assert.deepEqual(replacedRowsOf(rows, 'c').sort(), ['a', 'b'])
})
test('同设备码全部旧代次加 legacy 传递关联，其他设备与自己保留', { timeout: 60_000 }, () => {
  const rows = new Map([
    ['legacy', {}],
    ['a', { deviceCode: DEVICE_CODE, replaces: 'legacy' }],
    ['b', { deviceCode: DEVICE_CODE, replaces: 'a' }],
    ['c', { deviceCode: DEVICE_CODE, replaces: 'a', replacesAll: ['a', 'b', 'legacy'] }],
    ['other', { deviceCode: 'ZYXWVUTSRQPONMLKJIHGFE' }],
    ['another-legacy', {}],
  ])
  assert.deepEqual(replacedRowsOf(rows, 'c').sort(), ['a', 'b', 'legacy'])
  assert.deepEqual(replacedRowsOf(rows, 'other'), [])
})
test('替换关联有环不回头裁掉新身份，缺行/自己也不产生删除目标', { timeout: 60_000 }, () => {
  assert.deepEqual(replacedRowsOf(new Map([['a', { replaces: 'b' }], ['b', { replaces: 'a' }]]), 'a'), ['b'])
  assert.deepEqual(replacedRowsOf(new Map([['a', { replaces: 'missing' }]]), 'a'), [])
  assert.deepEqual(replacedRowsOf(new Map([['a', { replaces: 'a' }]]), 'a'), [])
  assert.deepEqual(replacedRowsOf(new Map(), 'missing'), [])
})

test('不同安装设备码的精确旧标识与替换边不跨设备归并', { timeout: 60_000 }, () => {
  const otherCode = 'ZYXWVUTSRQPONMLKJIHGFE'
  const rows = new Map([
    ['new', { pairingId: 'n'.repeat(43), pairedAt: 2, deviceCode: DEVICE_CODE, replaces: 'other' }],
    ['other', { pairingId: 'o'.repeat(43), pairedAt: 1, deviceCode: otherCode }],
  ])
  assert.deepEqual(findPreviousPairingRow(rows, 'o'.repeat(43), DEVICE_CODE), { devId: 'new', pairedAt: 2, replacesAll: ['new'] })
  assert.deepEqual(replacedRowsOf(rows, 'new'), [])
})

test('旧身份重连不能裁掉尚未正式连接的新身份', { timeout: 60_000 }, async (t) => {
  const first = setup(t)
  const a = await first.endpoint.handle(JSON.stringify({ v: 2, offerId: first.offer.offerId, code: first.offer.code, deviceCode: DEVICE_CODE }), first.candidate)
  assert.ok(a.ok)
  const next = setup(t, { keys: NEW_KEYS })
  for (const row of first.table) next.table.set(...row)
  const b = await next.endpoint.handle(JSON.stringify({ v: 2, offerId: next.offer.offerId, code: next.offer.code, deviceCode: DEVICE_CODE }), next.candidate)
  assert.ok(b.ok)
  assert.equal(next.table.get(b.devId)?.replaces, a.devId)
  assert.deepEqual(replacedRowsOf(next.table, a.devId), [], '旧凭据仍可重连，但不能让待用的新凭据成为孤儿')
  assert.deepEqual(replacedRowsOf(next.table, b.devId), [a.devId])
})

test('登记替换集合快照：B旧重连不裁未来C，C只裁登记前的A/B', { timeout: 60_000 }, async (t) => {
  const first = setup(t)
  const a = await first.endpoint.handle(JSON.stringify({ v: 2, offerId: first.offer.offerId, code: first.offer.code, deviceCode: DEVICE_CODE }), first.candidate)
  assert.ok(a.ok)
  const second = setup(t, { keys: NEW_KEYS })
  for (const row of first.table) second.table.set(...row)
  const b = await second.endpoint.handle(JSON.stringify({ v: 2, offerId: second.offer.offerId, code: second.offer.code, deviceCode: DEVICE_CODE }), second.candidate)
  assert.ok(b.ok)
  assert.deepEqual(second.table.get(b.devId)?.replacesAll, [a.devId])
  const third = setup(t, { keys: { ed: '1'.repeat(64), dh: '2'.repeat(64) } })
  for (const row of second.table) third.table.set(...row)
  const c = await third.endpoint.handle(JSON.stringify({ v: 2, offerId: third.offer.offerId, code: third.offer.code, previousPairingId: first.table.get(a.devId)!.pairingId, deviceCode: DEVICE_CODE }), third.candidate)
  assert.ok(c.ok)
  assert.deepEqual(third.table.get(c.devId)?.replacesAll?.slice().sort(), [a.devId, b.devId].sort())
  assert.deepEqual(replacedRowsOf(third.table, a.devId), [])
  assert.deepEqual(replacedRowsOf(third.table, b.devId), [a.devId])
  assert.deepEqual(replacedRowsOf(third.table, c.devId).sort(), [a.devId, b.devId].sort())
  // 新注册的D是将来的授权，不得被C连接时的旧快照实时扫进去。
  third.table.set('future', { ...third.table.get(c.devId)!, replaces: c.devId, replacesAll: [c.devId] })
  assert.deepEqual(replacedRowsOf(third.table, c.devId).sort(), [a.devId, b.devId].sort())
})
test('并发offer的登记找旧集合与put串行，后一个快照包含前一个已登记ID', { timeout: 60_000 }, async (t) => {
  let entered!: () => void
  let release!: () => void
  const waiting = new Promise<void>(r => { entered = r })
  const gate = new Promise<void>(r => { release = r })
  let table!: Map<string, PairedDeviceRow>
  let puts = 0
  const f = setup(t, { putDevice: async (id, row) => {
    puts += 1
    if (puts === 1) { entered(); await gate }
    table.set(id, row)
  } })
  table = f.table
  t.after(() => release())
  const first = f.endpoint.handle(JSON.stringify({ v: 2, offerId: f.offer.offerId, code: f.offer.code, deviceCode: DEVICE_CODE }), f.candidate)
  await waiting
  const offer = f.pairing.offer()
  const second = f.endpoint.handle(JSON.stringify({ v: 2, offerId: offer.offerId, code: offer.code, deviceCode: DEVICE_CODE }), { ...f.candidate, offerId: offer.offerId, devPubEd: NEW_KEYS.ed, devPubDh: NEW_KEYS.dh })
  await new Promise<void>(r => setImmediate(r))
  release()
  const [a, b] = await Promise.all([first, second])
  assert.ok(a.ok && b.ok)
  assert.deepEqual(table.get(b.devId)?.replacesAll, [a.devId])
  assert.deepEqual(replacedRowsOf(table, a.devId), [])
})
test('名册announce网络等待不拖住下一offer的登记写链', { timeout: 60_000 }, async (t) => {
  let entered!: () => void
  let release!: () => void
  const waiting = new Promise<void>(r => { entered = r })
  const gate = new Promise<void>(r => { release = r })
  let announces = 0
  const f = setup(t, { announce: async () => {
    announces += 1
    if (announces === 1) { entered(); await gate }
  } })
  t.after(() => release())
  const first = f.endpoint.handle(JSON.stringify({ v: 2, offerId: f.offer.offerId, code: f.offer.code, deviceCode: DEVICE_CODE }), f.candidate)
  await waiting
  const aId = [...f.table.keys()][0]!
  const offer = f.pairing.offer()
  const second = f.endpoint.handle(JSON.stringify({ v: 2, offerId: offer.offerId, code: offer.code, deviceCode: DEVICE_CODE }), { ...f.candidate, offerId: offer.offerId, devPubEd: NEW_KEYS.ed, devPubDh: NEW_KEYS.dh })
  await new Promise<void>(r => setImmediate(r))
  assert.equal(f.table.size, 2, '网络上报未完成时后续授权仍应可登记')
  release()
  const [, b] = await Promise.all([first, second])
  assert.ok(b.ok)
  assert.deepEqual(f.table.get(b.devId)?.replacesAll, [aId])
})

test('当代快照不跟随旧目标被后续改写的新替换边', { timeout: 60_000 }, () => {
  const rows = new Map([
    ['new', { deviceCode: DEVICE_CODE, replaces: 'old', replacesAll: ['old'] }],
    ['old', { deviceCode: DEVICE_CODE, replaces: 'future' }],
    ['future', { deviceCode: DEVICE_CODE }],
  ])
  assert.deepEqual(replacedRowsOf(rows, 'new'), ['old'])
})

test('不带设备码的旧客户端登记也捕获已知legacy替换链', { timeout: 60_000 }, async (t) => {
  const first = await pairOnce(t)
  const old = { ...first.table.get(first.oldDevId)!, replaces: 'older' }
  delete old.replacesAll
  first.table.set(first.oldDevId, old)
  first.table.set('older', { ...old, pairingId: 'q'.repeat(43), replaces: undefined })
  const next = setup(t, { keys: NEW_KEYS })
  for (const row of first.table) next.table.set(...row)
  const b = await next.endpoint.handle(next.body(next.offer.code, first.oldPairingId), next.candidate)
  assert.ok(b.ok)
  assert.deepEqual(next.table.get(b.devId)?.replacesAll?.slice().sort(), [first.oldDevId, 'older'].sort())
})
