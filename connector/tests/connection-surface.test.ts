/**
 * "每连接状态"耦合面的门禁（第 66 轮的测量，笔记见
 * `.agents/notes/proposed/2026-10-01-per-connection-scope-is-an-extraction.md`）。
 *
 * 这条门禁存在的理由：抽取（把每连接的构造物搬进 `createConnectionScope(port, deps)`）**还没做**，
 * 而它的规模完全取决于"那条缝有多宽"。如果在这之前有人往 `start-transport` 里再加一处
 * `next.xxx`，抽取的规模就悄悄变大 —— 而那种变化不会让任何测试变红。
 *
 * 所以把测量**写成断言**：耦合面必须恰好是这 4 个成员。加第 5 个时它会红，
 * 而红的时候正好提醒"顺手把它一起纳入 port"（那是抽取要用的窄端口）。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

/** 第 66 轮实测出来的耦合面（去重后的成员名）。 */
const EXPECTED = ['send', 'sendPairingFrame', 'state', 'whenWritable'] as const

test('start-transport 与连接之间的耦合面恰好是这 4 个成员（抽取的规模不许悄悄变大）', () => {
  const source = readFileSync(new URL('../src/index.ts', import.meta.url), 'utf8')

  // 只统计"被当作连接用的那个变量"上的成员访问：源码里它就是 `next.`
  // （`next` 只在 `start-transport` 里指连接；`next.start()` 是连接自己的生命周期，不算耦合面）。
  const members = new Set<string>()
  for (const match of source.matchAll(/\bnext\.([A-Za-z_$][\w$]*)/g)) {
    const member = match[1]
    if (member === undefined || member === 'start') continue
    members.add(member)
  }

  assert.deepEqual(
    [...members].sort(),
    [...EXPECTED],
    '耦合面变了：新增的成员要么纳入抽取用的窄端口，要么说明这里真的需要更多能力 —— ' +
      '两种情况都该先看一眼那份笔记（它把抽取的规模量化成了"4 个成员 / 9 处调用"）',
  )
})
