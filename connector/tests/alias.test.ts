/**
 * 别名映射的回归（契约 §5.1）。
 *
 * 重点在**两个方向的一致性**：一次写入跨不了两张表，崩在中间会留下单向条目，
 * 而两种残缺的后果完全不同（重复分配别名 / 有效别名被拒）。所以 `reconcile` 必须
 * 真的能修好两种残缺 —— 这里用假表把它们逐个构造出来。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { SID_BYTES, createAliases, newSid, type AliasTable } from '../src/alias.js'
import { ID_PATTERN } from '../src/protocol/frame.js'

/** 内存表，可注入初始内容来构造"崩在中间"的状态。 */
function table(initial: Record<string, string> = {}): AliasTable {
  const map = new Map(Object.entries(initial))
  return {
    get: (key) => map.get(key),
    put: async (key, value) => {
      // **时序必须忠实**：真实域表的写入走单写链，是"先落盘 → 再改内存"
      // （`store/index.ts` 引的 `packages/storage/storage-domain/src/domain.ts:263-270`）。
      // 这个 await 边界正是并发 `ensure` 撞车的窗口 —— 替身若在这里同步改内存，
      // 并发用例就永远撞不上，等于没测（变异校验抓出过这一点）。
      await Promise.resolve()
      map.set(key, value)
    },
    delete: async (key) => map.delete(key),
    keys: () => map.keys(),
  }
}

/** 确定性的"随机"源，便于断言。 */
const seqRandom = (() => {
  let n = 0
  return (size: number): Uint8Array => {
    n += 1
    return Uint8Array.from({ length: size }, (_, i) => (n * 31 + i) % 256)
  }
})()

test('别名：16 字节 base64url，且满足 AAD 的字符集要求', () => {
  const sid = newSid((size) => Uint8Array.from({ length: size }, (_, i) => i))
  assert.equal(Buffer.from(sid, 'base64url').length, SID_BYTES)
  // sid 是 AAD 的组成部分：字符集不对会让两端算出的 AAD 不同，症状是"解不开"。
  assert.match(sid, ID_PATTERN)
})

test('ensure：同一会话重复调用返回同一个别名，且两个方向都写好', async () => {
  const bySid = table()
  const bySession = table()
  const aliases = createAliases({ bySid, bySession }, { randomBytes: seqRandom })

  const first = await aliases.ensure('sess-1')
  const again = await aliases.ensure('sess-1')
  assert.equal(again, first, '不得重复分配')
  assert.equal(aliases.sidOf('sess-1'), first)
  assert.equal(aliases.sessionOf(first), 'sess-1')
  assert.equal(aliases.version, 1, '只分配了一次，版本只推进一次')

  const other = await aliases.ensure('sess-2')
  assert.notEqual(other, first, '不同会话要有不同别名')
  assert.equal(aliases.version, 2)
})

test('reconcile：清掉指向"没有回指"的残留 sid', async () => {
  // 构造：by_sid 里有一条孤儿（上次崩在两次 put 之间）。
  const bySid = table({ 'orphan-sid': 'sess-1' })
  const bySession = table({ 'sess-1': 'real-sid' })
  const aliases = createAliases({ bySid, bySession }, { randomBytes: seqRandom })

  const cleaned = await aliases.reconcile()
  assert.equal(cleaned, 1)
  assert.equal(aliases.sessionOf('orphan-sid'), undefined, '孤儿必须被清掉')
  assert.equal(aliases.sessionOf('real-sid'), 'sess-1', '补回了权威方向的反向条目')
  assert.equal(aliases.version, 1, '清理要推进版本，别名映射变了')
})

test('reconcile：给缺了反向条目的会话补回 by_sid', async () => {
  // 构造：权威方向有，反向缺失。
  const bySid = table()
  const bySession = table({ 'sess-1': 'sid-a' })
  const aliases = createAliases({ bySid, bySession }, { randomBytes: seqRandom })

  assert.equal(aliases.sessionOf('sid-a'), undefined, '构造出的状态确实是残缺的')
  const cleaned = await aliases.reconcile()
  // 补回不算"清理"，所以计数为 0 —— 但反向条目必须补上，
  // 否则手机端拿着有效别名会被校验拒掉。
  assert.equal(cleaned, 0)
  assert.equal(aliases.sessionOf('sid-a'), 'sess-1')
  assert.equal(aliases.sidOf('sess-1'), 'sid-a')
})

test('reconcile：干净状态下不动任何东西', async () => {
  const bySid = table()
  const bySession = table()
  const aliases = createAliases({ bySid, bySession }, { randomBytes: seqRandom })
  await aliases.ensure('sess-1')
  const before = aliases.version

  assert.equal(await aliases.reconcile(), 0)
  assert.equal(aliases.version, before, '没有变化就不该推进版本')
  // 往返一致：sid → session → sid 回到原值。
  const sid = aliases.sidOf('sess-1')
  assert.ok(sid !== undefined)
  assert.equal(aliases.sessionOf(sid), 'sess-1')
})

test('版本可以从持久化的 meta 读回来', () => {
  const aliases = createAliases(
    { bySid: table(), bySession: table() },
    { randomBytes: seqRandom, initialVersion: 7 },
  )
  assert.equal(aliases.version, 7)
})

test('ensure：同一会话**并发**调用合流成一个 sid（否则会分配出两个）', async () => {
  // 真实触发路径：`session.list` 与将来的 `session.subscribe` 并发时会撞上同一个会话。
  // 不合流的话，两个调用都在内存里查不到 → 各生成一个 sid → 各写一遍，
  // 结果是同一个会话有两个别名（`bySid` 里多一个孤儿），而那正是别名机制要防的事。
  const bySid = table()
  const bySession = table()
  const aliases = createAliases({ bySid, bySession }, { randomBytes: seqRandom })

  const [a, b, c] = await Promise.all([
    aliases.ensure('sess-1'),
    aliases.ensure('sess-1'),
    aliases.ensure('sess-1'),
  ])

  assert.equal(a, b)
  assert.equal(b, c)
  assert.equal(aliases.sessionOf(a), 'sess-1')
  assert.equal(aliases.version, 1, '只该分配一次')
  const pointing = [...bySid.keys()].filter((sid) => bySid.get(sid) === 'sess-1')
  assert.deepEqual(pointing, [a], '反向表里不能留下第二个指向同一会话的孤儿条目')
})
