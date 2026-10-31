/**
 * 帧类型清单**只有一份**：契约 §3 的联合类型必须与代码里的 `FRAME_TYPES` 逐项一致。
 *
 * 为什么值得一条门禁（而不是靠人记得）：
 * - 本仓已经因为"两处来源"栽过几次（帧类型清单、攒批集合、失效规则、一句文案里的有效期）。
 *   帧类型是最贵的那个：漏一种，中继会把它判成未知帧、连接层会按 `needsBox` 猜它的形状 ——
 *   而**症状是某一帧静默消失**，最难查的那一类。
 * - 第 19 轮加 `pair` / `pair-ack` 时是**手改**的契约；第 47 轮又靠它推导出"无 `sid` 的帧按绑定路由"。
 *   所以这份清单一旦漂移，影响的不是一处判断，而是**一条规则的前提**。
 *
 * 门禁口径：从契约 §3 里抽出所有 `| { v: 1; t: '...'` 行（那是联合类型的写法，正文不会那样排），
 * 断言集合与 `FRAME_TYPES` **完全相等**（多一个少一个都红）。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

import { FRAME_TYPES } from '../src/protocol/frame.js'

const CONTRACT = new URL('../../docs/subsystems/remote-channel.md', import.meta.url)
const DART_FRAME = new URL('../../app/lib/core/frame.dart', import.meta.url)

/** 契约 §3 里声明的帧类型（联合类型的写法 `| { v: 1; t: '...'`，正文不会那样排）。 */
function contractFrameTypes(): Set<string> {
  const markdown = readFileSync(CONTRACT, 'utf8')
  const declared = new Set<string>()
  for (const match of markdown.matchAll(/^[ \t]*\|[ \t]*\{[ \t]*v:[ \t]*1;[ \t]*t:[ \t]*'([a-z-]+)'/gm)) {
    const name = match[1]
    if (name !== undefined) declared.add(name)
  }
  return declared
}

/** 手机侧 `frameTypes` 清单（`app/lib/core/frame.dart`）。 */
function dartFrameTypes(): string[] {
  const source = readFileSync(DART_FRAME, 'utf8')
  const block = /const List<String> frameTypes = <String>\[([\s\S]*?)\];/.exec(source)
  assert.ok(block !== null, '没能在 frame.dart 里找到 frameTypes 清单 —— 先检查解析口径')
  return [...block[1]!.matchAll(/'([a-z-]+)'/g)].map((match) => match[1]!)
}

test('契约 §3 的帧类型清单与代码的 FRAME_TYPES 完全一致（唯一一份来源）', () => {
  const declared = contractFrameTypes()

  // 契约里必须**至少**出现一次那份清单（否则是解析口径坏了，不是"一致"）。
  assert.equal(declared.size > 0, true, '没能从契约 §3 里抽出任何帧类型 —— 先检查解析口径，别当成通过')

  assert.deepEqual(
    [...declared].sort(),
    [...FRAME_TYPES].sort(),
    '契约与代码的帧类型清单漂移了：改任何一侧都要同步另一侧 —— ' +
      '漏一种的症状是"某一帧在中继/连接层静默消失"，而不是报错',
  )
})

test('手机侧的 frameTypes 与电脑侧 FRAME_TYPES 逐项一致（三处一份清单）', () => {
  // 两侧各写一份清单是**必须的**（Dart 不读 TS），但"两份"必须能被机械判定相等：
  // 少一项的症状是手机把这一帧当未知帧——**静默忽略**（对 `host` 这类通知恰好是
  // 可接受的降级，对 `ev` / `live` 就是"会话页永远不更新"）。
  assert.deepEqual(
    dartFrameTypes().sort(),
    [...FRAME_TYPES].sort(),
    '手机侧与电脑侧的帧类型清单漂移了：改任何一侧都要同步另一侧',
  )
})
