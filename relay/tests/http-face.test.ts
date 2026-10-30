/**
 * 中转 HTTP 面的回归（契约 §2 / §12.1；`docs/subsystems/pairing-v2.md` §3）。
 *
 * 断言围着**状态码**：客户端要按它分行为（401 换凭据、409 让电脑重新出码、
 * 426 是版本不支持、400 是你自己发错了），所以每个码都要有一条用例钉住。
 * 另外几条是安全性质：**配对不可用时不许发票**、**连接器与设备不接受对方的凭据**、
 * **票上的设备 id 只能由设备公钥派生或由名册给出**（自报的 id 进不了票）。
 *
 * ## 两条换票路径（首配 vs 重连）
 *
 * `/ws-ticket` 有两种形态，它们的**认证方式完全不同**，所以要对症下药地测：
 * - 带 `offerId`（v2 候选）：凭**公开邀请**（无令牌）—— 首配唯一的入口；
 * - 不带：凭**设备令牌** —— 已配对设备的重连路径（不再需要码，也不需要邀请）。
 *
 * 旧版本的 `codeHash` 请求一律 426：让手机明确"升级版本"，而不是被含糊地当成"配对不可用"。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { createRelayCore } from '../src/core.ts'
import { createDeviceRegistry } from '../src/device-registry.ts'
import { createHttpFace, type Authenticated } from '../src/http-face.ts'
import { createTicketStore } from '../src/tickets.ts'
import { deviceIdOf } from '../../protocol/relay-control.mjs'

const TOKENS: Record<string, Authenticated> = {
  'connector-token-1': { kind: 'connector', id: 'conn-1' },
}

/** 首配候选：设备 id 由 `devPubDh` 派生（中转自己算，不接受请求方指定）。 */
const CANDIDATE = {
  offerId: 'A'.repeat(22),
  devPubEd: 'c'.repeat(64),
  devPubDh: 'd'.repeat(64),
  name: '我的手机',
}
const OFFER_ID = CANDIDATE.offerId

/** 设备令牌：由**名册**认，不走摘要表（它与连接器令牌是两套凭据面）。 */
const DEVICE_TOKEN = 'device-token-1'
const DEVICE_ID = 'dev-1'

/** 名册里的一行。设备公钥与 id 的对应关系由电脑侧负责，中转只记账（§12.1）。 */
const rosterRow = (id: string, token: string) => ({
  id,
  pairingId: `pair-${id}`,
  devPubEd: 'a'.repeat(64),
  devPubDh: 'b'.repeat(64),
  name: '我的手机',
  tokenHash: createHash('sha256').update(token, 'utf8').digest('hex'),
})

function setup() {
  let round = 0
  const core = createRelayCore()
  const devices = createDeviceRegistry()
  devices.register('conn-1', [rosterRow(DEVICE_ID, DEVICE_TOKEN)])
  const tickets = createTicketStore({
    randomBytes: (size) => {
      round += 1
      return Uint8Array.from({ length: size }, (_, i) => (round * 43 + i) % 256)
    },
  })
  const face = createHttpFace({
    tickets,
    core,
    devices,
    authenticate: (token) => TOKENS[token],
  })
  core.attachConnector('conn-1')
  return { core, tickets, devices, face }
}

/** 首配形态：凭**公开邀请**换票（没有令牌）。 */
const ticketByOffer = (candidate: Record<string, unknown> = CANDIDATE) => ({
  method: 'POST',
  path: '/ws-ticket',
  body: { v: 2, ...candidate },
})

/** 重连形态：凭设备令牌换票。 */
const ticketByToken = (token: string) => ({
  method: 'POST',
  path: '/ws-ticket',
  token,
  body: {},
})

test('首配换票：凭公开邀请（无令牌）→ 201，票绑**候选自己**的身份、用途与公钥元数据', () => {
  const { core, tickets, face } = setup()
  core.registerPairing('conn-1', OFFER_ID)

  const response = face.handle(ticketByOffer())
  assert.equal(response.status, 201)
  const body = response.body as { ticket: string; expiresAt: number }
  assert.match(body.ticket, /^[A-Za-z0-9_-]{22}$/)
  assert.deepEqual(
    tickets.consume(body.ticket),
    { connectorId: 'conn-1', deviceId: deviceIdOf(CANDIDATE), purpose: 'pairing', candidate: CANDIDATE },
    '设备 id 由设备公钥派生 —— 候选不是已配对设备，票也不许绑一个它自报的身份',
  )

  // 请求方自报的 `deviceId` 不参与派生：字段压根不被采纳（§3"不接受请求方任意指定"）。
  const spoofed = face.handle(ticketByOffer({ ...CANDIDATE, deviceId: DEVICE_ID }))
  assert.equal(spoofed.status, 201)
  const spoofedTicket = (spoofed.body as { ticket: string }).ticket
  assert.equal(tickets.consume(spoofedTicket)?.deviceId, deviceIdOf(CANDIDATE), '自报的 id 被丢掉')

  // 公开邀请**不因换票而作废**（它不是一次性凭据；一次性的是电脑侧的配对秘密）。
  assert.equal(face.handle(ticketByOffer()).status, 201)
})

test('重连换票：凭**设备令牌** → 201，票绑名册里的真实设备与它的连接器', () => {
  const { tickets, face } = setup()
  const response = face.handle(ticketByToken(DEVICE_TOKEN))
  assert.equal(response.status, 201)
  const { ticket } = response.body as { ticket: string }
  assert.deepEqual(
    tickets.consume(ticket),
    { connectorId: 'conn-1', deviceId: DEVICE_ID, purpose: 'paired' },
    '设备 id 是按令牌摘要查名册得来的，不是请求里带的',
  )
})

test('一台手机配了两台电脑 = 两条独立名册行：票各绑各的连接器，停用一台不影响另一台', () => {
  // 这是"一个用户多台电脑 + 一台手机连多台电脑"在中转侧的真实形状：
  // 每次配对都是**新的设备身份**（2026-10-15「每次配对换新身份」），于是同一台手机
  // 在名册里是两条行、两枚令牌，分属两台连接器。中转要做的只有一件事：
  // 票里写死 `(connectorId, deviceId)`，绝不按"这台手机"去猜。
  const core = createRelayCore()
  const devices = createDeviceRegistry()
  const tickets = createTicketStore({
    randomBytes: (size) => Uint8Array.from({ length: size }, (_, i) => (i * 37 + 11) % 256),
  })
  const face = createHttpFace({
    tickets,
    core,
    devices,
    authenticate: (token) => TOKENS[token],
  })
  core.attachConnector('conn-1')
  core.attachConnector('conn-2')

  // 电脑 A：这台手机 + 一台平板；电脑 B：同一台手机的第二次配对（新身份）。
  devices.register('conn-1', [rosterRow('phone-on-a', 'tok-a'), rosterRow('tablet-on-a', 'tok-tablet')])
  devices.register('conn-2', [rosterRow('phone-on-b', 'tok-b')])

  const ticketFor = (token: string) => {
    const response = face.handle(ticketByToken(token))
    assert.equal(response.status, 201, `${token} 应当换得到票`)
    return tickets.consume((response.body as { ticket: string }).ticket)
  }

  assert.deepEqual(ticketFor('tok-a'), { connectorId: 'conn-1', deviceId: 'phone-on-a', purpose: 'paired' })
  assert.deepEqual(ticketFor('tok-tablet'), { connectorId: 'conn-1', deviceId: 'tablet-on-a', purpose: 'paired' })
  assert.deepEqual(ticketFor('tok-b'), { connectorId: 'conn-2', deviceId: 'phone-on-b', purpose: 'paired' })
  // 两枚令牌不能互换身份：各自解出自己那条行，解出的设备 id 不同。
  assert.equal(devices.authenticate('tok-a'), 'phone-on-a')
  assert.equal(devices.authenticate('tok-b'), 'phone-on-b')
  assert.notEqual(devices.authenticate('tok-a'), devices.authenticate('tok-b'))

  // 停用电脑 A 上那台：只有它变 revoked；平板的、电脑 B 的都不动。
  devices.register('conn-1', [
    { ...rosterRow('phone-on-a', 'tok-a'), revokedAt: 1 },
    rosterRow('tablet-on-a', 'tok-tablet'),
  ])
  assert.equal(devices.classify('tok-a'), 'revoked')
  assert.equal(devices.classify('tok-tablet'), 'ok')
  assert.equal(devices.classify('tok-b'), 'ok')
  assert.deepEqual(face.handle(ticketByToken('tok-a')).body, { error: 'device-revoked' })
  assert.equal(face.handle(ticketByToken('tok-b')).status, 201, '另一台电脑的票照发')
})

test('限流桶的键：连接器配了 owner 就按人分桶，没配按连接器，设备按设备', () => {
  // 键由 `http-face` 拼、桶由 `server.ts` 的 limiter 存。这里钉住"拼出来的是什么"，
  // 否则 `owner` 配了也白配（一个人多开电脑就等于多领预算）。
  const seen: string[] = []
  const core = createRelayCore()
  const devices = createDeviceRegistry()
  const tickets = createTicketStore({ randomBytes: (size) => new Uint8Array(size).fill(7) })
  const face = createHttpFace({
    tickets,
    core,
    devices,
    authenticate: (token) => TOKENS[token],
    rateLimit: (key) => { seen.push(key); return { allowed: true, retryAfterMs: null } },
  })
  core.attachConnector('conn-1')
  devices.register('conn-1', [rosterRow(DEVICE_ID, DEVICE_TOKEN)])

  face.handle(ticketByToken(DEVICE_TOKEN))
  assert.equal(seen.at(-1), `device:${DEVICE_ID}`, '设备按它自己的 id 分桶')

  face.handle({ method: 'POST', path: '/devices', token: 'connector-token-1', body: { devices: [] } })
  assert.equal(seen.at(-1), 'connector:conn-1', '连接器没配 owner 时按连接器分桶')
})

test('凭据不对 → 401（客户端据此换凭据，而不是拿同一个重试）', () => {
  const { face } = setup()
  // 既不是连接器令牌、也不在名册里
  assert.equal(face.handle(ticketByToken('nope')).status, 401)
  assert.equal(face.handle({ method: 'POST', path: '/ws-ticket', body: {} }).status, 401)
})

test('401 带原因：没见过 → device-unknown，已停用 → device-revoked（手机据此说不同的话）', () => {
  const { devices, face } = setup()
  // 没见过：多半是名册还没同步（电脑刚启动 / 刚重配完），重试可能就好。
  assert.deepEqual(face.handle(ticketByToken('nope')).body, { error: 'device-unknown' })
  // 已停用：行还在、只是带 `revokedAt` —— 这一步能分辨，是因为软吊销保留了原行。
  devices.register('conn-1', [{ ...rosterRow(DEVICE_ID, DEVICE_TOKEN), revokedAt: 1 }])
  assert.deepEqual(face.handle(ticketByToken(DEVICE_TOKEN)).body, { error: 'device-revoked' })
})

test('名册**走 HTTP** 带上 revokedAt：停用才会变成 device-revoked（不是 unknown）', () => {
  // 这一条钉的是**名册的形状**：`device-registry` 早就支持带 revokedAt 的行，
  // 但真正决定"手机看得见停用"的是两处过滤 —— 连接器上报时有没有把停用行带上、
  // 中转解析时有没有保留 `revokedAt`。任何一处漏掉，401 都会退化成 device-unknown
  // （与"名册还没同步"同一个症状 ⇒ 手机一直重试，停用在他那边等于没发生）。
  const { face } = setup()
  const roster = {
    method: 'POST',
    path: '/devices',
    token: 'connector-token-1',
    body: { devices: [{ ...rosterRow(DEVICE_ID, DEVICE_TOKEN), revokedAt: 1760000000000 }] },
  }
  assert.equal(face.handle(roster).status, 201, '带 revokedAt 的名册是合法形状')
  assert.deepEqual(
    face.handle(ticketByToken(DEVICE_TOKEN)).body,
    { error: 'device-revoked' },
    '停用的设备换票必须说"被停用"，而不是"没见过"',
  )

  // 形状不合（revokedAt 不是数字）→ 400，而不是静默丢掉这个字段。
  const bad = { ...roster, body: { devices: [{ ...rosterRow(DEVICE_ID, DEVICE_TOKEN), revokedAt: 'yesterday' }] } }
  assert.equal(face.handle(bad).status, 400)
})

test('配对登记不可用 → 409 / 候选不合形状 → 400，而且**一张票都不许发**', () => {
  const { core, tickets, face } = setup()
  assert.equal(face.handle(ticketByOffer()).status, 409, '没登记')
  assert.deepEqual(tickets.stats, { tickets: 0 }, '拒绝时不许留下任何票')

  core.registerPairing('conn-1', OFFER_ID)
  assert.equal(face.handle(ticketByOffer()).status, 201)
  // 登记在、但请求不是合法的 v2 候选：400（"你发错了"与"现在没有"是两件事）
  assert.equal(face.handle(ticketByOffer({ ...CANDIDATE, v: 1 })).status, 400, '版本不对')
  assert.equal(face.handle(ticketByOffer({ ...CANDIDATE, devPubDh: undefined })).status, 400, '缺设备公钥')
  assert.equal(face.handle(ticketByOffer({ ...CANDIDATE, offerId: 'short' })).status, 400, '公开标识形状不对')
  assert.deepEqual(tickets.stats, { tickets: 1 }, '三次拒绝都不许发票（只有那次 201 留了一张）')
})

test('连接器不走换票（403）；设备不能替连接器登记（403）', () => {
  const { face } = setup()
  assert.equal(face.handle(ticketByToken('connector-token-1')).status, 403, '连接器不走换票')
  assert.equal(
    face.handle({
      method: 'POST',
      path: '/pairing/register',
      token: DEVICE_TOKEN,
      body: { v: 2, offerId: OFFER_ID },
    }).status,
    403,
    '设备不能替连接器登记',
  )
})

test('登记形状：缺 offerId / 版本不对 → 400；登记之后那台候选真换得到票', () => {
  const { face } = setup()
  assert.equal(
    face.handle({ method: 'POST', path: '/pairing/register', token: 'connector-token-1' }).status,
    400,
  )
  assert.equal(
    face.handle({
      method: 'POST',
      path: '/pairing/register',
      token: 'connector-token-1',
      body: { v: 1, offerId: OFFER_ID },
    }).status,
    400,
    'v1 的登记不接受（旧明文 pair 已下线，手机据此升级版本）',
  )
  assert.equal(
    face.handle({
      method: 'POST',
      path: '/pairing/register',
      token: 'connector-token-1',
      body: { v: 2, offerId: OFFER_ID },
    }).status,
    201,
  )
  assert.equal(face.handle(ticketByOffer()).status, 201)
})

test('旧版本的 codeHash 请求 → 426（手机据此升级，而不是被含糊地当成"配对不可用"）', () => {
  const { tickets, face } = setup()
  assert.equal(face.handle({ method: 'POST', path: '/ws-ticket', body: { codeHash: 'hash-a' } }).status, 426)
  assert.equal(
    face.handle({
      method: 'POST',
      path: '/pairing/register',
      token: 'connector-token-1',
      body: { codeHash: 'hash-a' },
    }).status,
    426,
  )
  assert.deepEqual(tickets.stats, { tickets: 0 })
})

test('名册：连接器报名册 → 201，且那台设备**立刻**换得到票', () => {
  const { devices, face } = setup()
  const registered = face.handle({
    method: 'POST',
    path: '/devices',
    token: 'connector-token-1',
    // **整份名册**：`setup()` 里那台也要一起报 —— 名册是全量快照，
    // 差集即删除（见 `device-registry.test.ts` 的收敛用例）。
    body: { devices: [rosterRow(DEVICE_ID, DEVICE_TOKEN), rosterRow('dev-2', 'token-2')] },
  })
  assert.equal(registered.status, 201)
  assert.equal((registered.body as { accepted: number }).accepted, 2)
  assert.equal(devices.stats.devices, 2)
  assert.equal(face.handle(ticketByToken('token-2')).status, 201)
  assert.equal(face.handle(ticketByToken(DEVICE_TOKEN)).status, 201, '原来那台还在')
})

test('名册是全量快照：这次没报到的行被收敛，那台设备**再也换不到票**', () => {
  const { devices, face } = setup()
  const pruned = face.handle({
    method: 'POST',
    path: '/devices',
    token: 'connector-token-1',
    body: { devices: [rosterRow('dev-2', 'token-2')] },
  })
  assert.equal(pruned.status, 201)
  assert.equal(devices.stats.devices, 1, 'setup 那台被收敛掉了')
  assert.equal(face.handle(ticketByToken(DEVICE_TOKEN)).status, 401, '电脑侧删了它，中转就不该再认')
  assert.equal(face.handle(ticketByToken('token-2')).status, 201)
})

test('空名册也报：那正是"这台电脑上没有设备了"', () => {
  const { devices, face } = setup()
  const cleared = face.handle({
    method: 'POST',
    path: '/devices',
    token: 'connector-token-1',
    body: { devices: [] },
  })
  assert.equal(cleared.status, 201)
  assert.equal(devices.stats.devices, 0, '旧的收敛干净')
  assert.equal(face.handle(ticketByToken(DEVICE_TOKEN)).status, 401)
})

test('名册形状不对 → 400（**不静默跳过坏行**：少一台设备的症状是那台再也连不上）', () => {
  const { devices, face } = setup()
  const bad = face.handle({
    method: 'POST',
    path: '/devices',
    token: 'connector-token-1',
    body: { devices: [{ id: 'dev-2', tokenHash: 'x' }] },
  })
  assert.equal(bad.status, 400)
  assert.equal(devices.stats.devices, 1, '整份拒掉，一行都不许落')
})

test('方法和路径：非 POST → 405，未知路径 → 404', () => {
  const { face } = setup()
  assert.equal(face.handle({ method: 'GET', path: '/ws-ticket' }).status, 405)
  assert.equal(face.handle({ method: 'POST', path: '/nope', token: 'connector-token-1' }).status, 404)
})
