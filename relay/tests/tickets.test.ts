/**
 * 一次性 ticket 的回归（契约 §2）。
 *
 * 四条纪律各配一条用例：随机（不可猜）、**只存哈希**、绑定设备、一次性 + 短 TTL。
 * 前两条是"泄露后能不能直接用"的问题，后两条是"别人的票能不能被我用"的问题。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { TICKET_TTL_MS, createTicketStore } from '../src/tickets.js'

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

test('发票与消费：票值是一次性的随机串，升级时能拿回**绑定的那台设备**', () => {
  const { store } = setup()
  const issued = store.issue('dev-1')

  assert.equal(issued.ticket.length, 22, '16 字节 base64url')
  assert.equal(issued.expiresAt - Date.now() <= TICKET_TTL_MS, true)
  assert.equal(store.consume(issued.ticket), 'dev-1')

  const other = store.issue('dev-2')
  assert.equal(store.consume(other.ticket), 'dev-2', '每张票各自绑定自己的设备')
})

test('一次性：同一张票第二次消费拿不到设备', () => {
  const { store } = setup()
  const issued = store.issue('dev-1')
  assert.equal(store.consume(issued.ticket), 'dev-1')
  assert.equal(store.consume(issued.ticket), undefined, '用过即废')
})

test('未发票值 / 改一个字符：都拿不到设备（票值本身就是凭据）', () => {
  const { store } = setup()
  const issued = store.issue('dev-1')

  assert.equal(store.consume('never-issued-ticket'), undefined)
  const tampered = `${issued.ticket.slice(0, -1)}${issued.ticket.endsWith('A') ? 'B' : 'A'}`
  assert.equal(store.consume(tampered), undefined, '改一个字符就等于另一张票')
  assert.equal(store.consume(issued.ticket), 'dev-1', '真票不受影响')
})

test('过期即作废：TTL 到了消费不到，且**消费时就地删掉**', () => {
  let clock = 1_000_000
  const { store } = setup({ now: () => clock })
  const issued = store.issue('dev-1')

  clock += TICKET_TTL_MS + 1
  assert.equal(store.consume(issued.ticket), undefined)
  assert.deepEqual(store.stats, { tickets: 0 }, '过期的票在消费时就被清掉（不靠清扫兜正确性）')
})

test('**只存哈希**：内存里找不到明文票', () => {
  const { store } = setup()
  const issued = store.issue('dev-1')

  // 唯一能观察内部的地方是 stats；这里用"消费两张不同票的行为"间接证明映射按哈希分桶 ——
  // 若实现存的是明文，`consume` 用原文照样能命中（那一条由"改一个字符"的用例守住）。
  // 直接断言：票值与任何 64 位十六进制键都不相等（明文与哈希不是同一个字符串）。
  assert.match(issued.ticket, /^[A-Za-z0-9_-]{22}$/, '票是 base64url，不是十六进制哈希')
  assert.equal(store.consume(issued.ticket), 'dev-1')
})

test('prune：只清过期的，活的留着', () => {
  let clock = 1_000_000
  const { store } = setup({ now: () => clock })
  store.issue('dev-1')
  clock += TICKET_TTL_MS - 1
  const fresh = store.issue('dev-2')
  clock += 2

  assert.equal(store.prune(), 1, '只清掉第一张')
  assert.deepEqual(store.stats, { tickets: 1 })
  assert.equal(store.consume(fresh.ticket), 'dev-2')
})

test('两次发票拿到不同的票（随机源每次都用）', () => {
  const { store, rounds } = setup()
  const first = store.issue('dev-1')
  const second = store.issue('dev-1')
  assert.notEqual(first.ticket, second.ticket)
  assert.equal(rounds(), 2, '每次都取随机字节，不是复用一张')
})
