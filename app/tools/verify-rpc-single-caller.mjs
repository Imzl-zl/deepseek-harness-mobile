// 判据：协议知识（方法名 + 参数形状）只许待在 wire/ 外面 —— 这个数只许降，终态 0。
// Note: 为什么是"会归零的数"而不是"名单表" —— 见 .agents/notes/proposed/2026-10-25-wire-design-review.md
//
// ## 它数的是什么，怎么读结果
//
// `app/lib/data/` 与 `app/lib/ui/` 里 `client.call<` 的**代码**出现次数：
// 每有一处，就说明还有"方法名 + 参数形状"这两样协议知识漏在 `wire/` 外面
// （`wire/rpc/<family>.dart` 才是唯一该发请求、唯一该断言应答的地方）。
// 搬走一个方法 ⇒ 把这个常量减到底 —— **`BUDGET` 就是进度表，只许降**；
// 想加回去就等于把协议知识放回界面层，评审看这一个数就能拦住。
// 终态 0 时删掉常量，规则变成零例外的绝对规则。
//
// **不要改成"剥注释再数"**：块注释会被整段吞掉、行号就没了，而这条门禁的价值
// 一半在"报出是哪一行"。行首是注释的行直接跳过就够（见 COMMENT_LINE）。
// 正则取 `client\.call<` 是精确的：这两个目录里所有 RPC 调用都带显式泛型，
// 而 `onEndpointsChanged?.call(...)` 那类回调不带 `<`，不会误命中。
//
// 路径全部相对仓库根（`verify-tool-paths.mjs` 会拦盘符字面量），跑之前先 cd 到仓库根。
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const BUDGET = 24
const DIRS = ['app/lib/data', 'app/lib/ui']
/** 行首是注释就不算用法。不剥注释是为了保住行号（块注释会被整段吞掉）。 */
const COMMENT_LINE = /^\s*(\/\/|\*|\/\*)/

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) walk(full, out)
    else if (entry.endsWith('.dart')) out.push(full)
  }
  return out
}

const hits = []
for (const dir of DIRS) {
  for (const file of walk(dir)) {
    readFileSync(file, 'utf8').split('\n').forEach((line, index) => {
      if (COMMENT_LINE.test(line)) return
      if (/client\.call</.test(line)) hits.push(`${relative('.', file)}:${index + 1}`)
    })
  }
}

const ok = hits.length === BUDGET
console.log(`${ok ? 'PASS' : 'FAIL'} — 实测 ${hits.length} 处，预算 ${BUDGET}`)
if (!ok) {
  for (const hit of hits) console.log('  ', hit)
  process.exitCode = 1
}
