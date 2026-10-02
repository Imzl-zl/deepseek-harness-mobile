/**
 * "每连接状态"耦合面的门禁（第 66 轮的测量，笔记见
 * `.agents/notes/implemented/2026-10-01-per-connection-scope-is-an-extraction.md`）。
 *
 * 这条门禁存在的理由：每连接的构造物只允许通过**一个窄端口**碰连接，而"顺手多要一个能力"
 * 不会让任何行为用例变红 —— 它只会让那条缝悄悄变宽，直到"按连接装配"再也搬不动。
 *
 * 所以把测量**写成断言**：耦合面必须恰好是这 4 个成员（`ConnectionPort`）。
 * 加第 5 个时它会红，而红的时候正好提醒"要么纳入窄端口，要么说明这里真的需要更多能力"。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

/** 第 66 轮实测出来的耦合面（去重后的成员名）。 */
const EXPECTED = ['send', 'sendPairingFrame', 'state', 'whenWritable'] as const

/**
 * 扫描范围是**两处**，缺一不可：
 *
 * - `index.ts` —— 连接的持有者与生命周期（`next.start()`）；
 * - `connection-scope.ts` —— 每连接装配物所在处（抽取之后，成员访问都在这里）。
 *
 * 只扫一处的话门禁会"看起来通过"：抽取前只数 `index.ts`，抽取后它就一个成员也数不到了
 *（旧版扫的是 `next.` 与 `port.` 两条路，那是搬家**进行中**的形状）。
 */
const SCANNED = ['../src/index.ts', '../src/connection-scope.ts'] as const

test('每连接装配与连接之间的耦合面恰好是这 4 个成员（这条缝不许悄悄变宽）', () => {
  const members = new Set<string>()
  for (const file of SCANNED) {
    const source = readFileSync(new URL(file, import.meta.url), 'utf8')
    for (const match of source.matchAll(/\b(?:next|port)\.([A-Za-z_$][\w$]*)/g)) {
      const member = match[1]
      // 正则的捕获组在类型上是 `string | undefined`（`noUncheckedIndexedAccess`）——
      // 漏了这个判断 `tsc` 会红，而 `tsx` 剥类型**不做检查**，于是红了两轮才被发现。
      if (member === undefined) continue
      // `next.start()` 是**连接自己的生命周期**（不属于"每连接状态"的耦合面）；
      // `port.start()` 不该存在（窄端口里没有它）——所以这里只豁免 next 的那一个。
      if (member === 'start' && match[0].startsWith('next.')) continue
      members.add(member)
    }
  }

  assert.deepEqual(
    [...members].sort(),
    [...EXPECTED],
    '耦合面变了：新增的成员要么纳入窄端口 `ConnectionPort` 并同步这份清单，' +
      '要么说明这里真的需要更多能力 —— 两种情况都该先看那份笔记（它把抽取规模量化成"4 个成员 / 9 处调用"）',
  )
})
