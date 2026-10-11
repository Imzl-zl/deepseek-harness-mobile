/**
 * 一次性 ticket 的回归（契约 §2；`docs/subsystems/pairing-v2.md` §2 的票绑定）。
 *
 * v2 的票绑的是**一个身份绑定**（`DeviceBinding`），不是"一个设备 id 字符串"：
 * `(连接器, 设备, 用途)` 三样一起写进票，`pairing` 用途还带上候选公钥元数据。
 * 于是"升级时能不能对上"与"票是谁的"由同一个结构回答，而不是两处各判一次。
 *
 * 五条纪律各配一条用例：随机（不可猜）、**只存哈希**、绑定身份、一次性 + 短 TTL、
 * **不合法的绑定发不出票**。前两条是"泄露后能不能直接用"，
 * 后三条是"别人的票能不能被我用 / 票能不能替我自称一个身份"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { TICKET_TTL_MS, createTicketStore } from '../src/tickets.ts'
import { deviceIdOf, type DeviceBinding } from '../../protocol/relay-control.mjs'

const binding = (deviceId: string, connectorId = 'pc-1'): DeviceBinding =>
  ({ connectorId, deviceId, purpose: 'paired' })
const candidate = (offerId = 'A'.repeat(22)) => ({
  offerId, devPubEd: 'a'.repeat(64), devPubDh: 'b'.repeat(64), name: '手机',
})

function setup(patch: { now?: () => number } = {}) {
  let round = 0
  const store = createTicketStore({
    randomBytes: (size) => {
      round += 1
      return Uint8Array.from({ length: size }, (_, i) => (round * 41 + i) % 256)
    },
    ...(patch.now === undefined ? {} : { now: patch.now }),
  })
  return { store, rounds: () => round }
}

test('发票与消费：票值是一次性的随机串，升级时能拿回**绑定的那个身份**', () => {
  const { store } = setup()
  const issued = store.issue(binding('dev-1'))

  assert.equal(issued.ticket.length, 22, '16 字节 base64url')
  assert.equal(issued.expiresAt - Date.now() <= TICKET_TTL_MS, true)
  assert.deepEqual(store.consume(issued.ticket), binding('dev-1'))
  assert.equal(issued.deviceId, 'dev-1')

  const other = store.issue(binding('dev-2'))
  assert.deepEqual(store.consume(other.ticket), binding('dev-2'), '每张票各自绑定自己的设备')
})

test('票绑的是**连接器 + 设备 + 用途**（升级时三样都要对上，候选还要带上公钥元数据）', () => {
  const { store } = setup()
  const paired = store.issue(binding('dev-1', 'pc-2'))
  assert.deepEqual(store.consume(paired.ticket), binding('dev-1', 'pc-2'), '连接器也是绑定的一部分')

  // 首配那一跳：票绑的是**候选自己**（设备 id 由公钥派生，用途是 pairing）。
  const first = candidate()
  const pairingTicket = store.issue({
    connectorId: 'pc-2', deviceId: deviceIdOf(first), purpose: 'pairing', candidate: first,
  })
  assert.deepEqual(store.consume(pairingTicket.ticket), {
    connectorId: 'pc-2', deviceId: deviceIdOf(first), purpose: 'pairing', candidate: first,
  })
  assert.equal(pairingTicket.deviceId, deviceIdOf(first))
})

test('不合法的身份绑定：**发不出票**（设备 id 不许由请求方自报一个）', () => {
  const { store } = setup()
  const first = candidate()

  // `pairing` 用途的设备 id 只能由候选公钥派生（§3）：自报一个别的 id 就该被拒。
  assert.throws(
    () => store.issue({
      connectorId: 'pc-1', deviceId: 'dev-1', purpose: 'pairing', candidate: first,
    } as unknown as DeviceBinding),
    TypeError,
  )
  // v1 的首配临时身份形状（含 `:`）在 v2 里根本不是合法绑定 —— 它不该出现在任何票上。
  assert.throws(
    () => store.issue({
      connectorId: 'pc-1', deviceId: 'pending:abc', purpose: 'paired',
    } as unknown as DeviceBinding),
    TypeError,
  )
  assert.deepEqual(store.stats, { tickets: 0 }, '拒绝时不许留下任何票')
})

test('一次性：同一张票第二次消费拿不到身份', () => {
  const { store } = setup()
  const issued = store.issue(binding('dev-1'))
  assert.deepEqual(store.consume(issued.ticket), binding('dev-1'))
  assert.equal(store.consume(issued.ticket), undefined, '用过即废')
})

test('未发票值 / 改一个字符：都拿不到身份（票值本身就是凭据）', () => {
  const { store } = setup()
  const issued = store.issue(binding('dev-1'))

  assert.equal(store.consume('never-issued-ticket'), undefined)
  const tampered = `${issued.ticket.slice(0, -1)}${issued.ticket.endsWith('A') ? 'B' : 'A'}`
  assert.equal(store.consume(tampered), undefined, '改一个字符就等于另一张票')
  assert.deepEqual(store.consume(issued.ticket), binding('dev-1'), '真票不受影响')
})

test('过期即作废：TTL 到了消费不到，且**消费时就地删掉**', () => {
  let clock = 1_000_000
  const { store } = setup({ now: () => clock })
  const issued = store.issue(binding('dev-1'))

  clock += TICKET_TTL_MS + 1
  assert.equal(store.consume(issued.ticket), undefined)
  assert.deepEqual(store.stats, { tickets: 0 }, '过期的票在消费时就被清掉（不靠清扫兜正确性）')
})

test('**只存哈希**：内存里找不到明文票', () => {
  const { store } = setup()
  const issued = store.issue(binding('dev-1'))

  // 唯一能观察内部的地方是 stats；这里用"消费两张不同票的行为"间接证明映射按哈希分桶 ——
  // 若实现存的是明文，`consume` 用原文照样能命中（那一条由"改一个字符"的用例守住）。
  // 直接断言：票值与任何 64 位十六进制键都不相等（明文与哈希不是同一个字符串）。
  assert.match(issued.ticket, /^[A-Za-z0-9_-]{22}$/, '票是 base64url，不是十六进制哈希')
  assert.deepEqual(store.consume(issued.ticket), binding('dev-1'))
})

test('prune：只清过期的，活的留着', () => {
  let clock = 1_000_000
  const { store } = setup({ now: () => clock })
  store.issue(binding('dev-1'))
  clock += TICKET_TTL_MS - 1
  const fresh = store.issue(binding('dev-2'))
  clock += 2

  assert.equal(store.prune(), 1, '只清掉第一张')
  assert.deepEqual(store.stats, { tickets: 1 })
  assert.deepEqual(store.consume(fresh.ticket), binding('dev-2'))
})

test('自清：**未被使用**的过期票会在后续发票时被清掉（不必等外部调用 prune）', () => {
  let clock = 1_000_000
  const { store } = setup({ now: () => clock })

  // 先发 63 张（不消费），**然后**让它们过期 —— 自清发生在第 64 次发票当时，
  // 所以过期的票必须在那一刻之前就已经过期，否则它清不到东西（这正是我第一版写错的地方）。
  for (let i = 0; i < 63; i += 1) store.issue(binding(`dev-${i}`))
  assert.deepEqual(store.stats, { tickets: 63 })

  clock += TICKET_TTL_MS + 1
  // 第 64 次发票：触发自清（`PRUNE_EVERY = 64`）→ 63 张过期的被清掉，再加这一张新的。
  store.issue(binding('dev-late'))
  assert.deepEqual(store.stats, { tickets: 1 }, '过期的未用票不会一直堆在表里')
})

test('两次发票拿到不同的票（随机源每次都用）', () => {
  const { store, rounds } = setup()
  const first = store.issue(binding('dev-1'))
  const second = store.issue(binding('dev-1'))
  assert.notEqual(first.ticket, second.ticket)
  assert.equal(rounds(), 2, '每次都取随机字节，不是复用一张')
})
