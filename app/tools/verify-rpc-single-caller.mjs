// 判据：`app/lib/data/` 与 `app/lib/ui/` 里**零** `client.call<` —— 零例外的绝对规则。
//
// Note: 为什么是"会归零的数"而不是"名单表" —— 见
// `.agents/notes/implemented/2026-10-25-wire-golden-and-session-list.md`
//
// ## 它数的是什么
//
// 每有一处 `client.call<`，就说明还有"方法名 + 参数形状"这两样协议知识漏在 `wire/` 外面
// （`wire/rpc/<面>.dart` 才是唯一该发请求、唯一该断言应答的地方）。
//
// **这条门禁走完了它的预算**：2026-10-25 从 39 降到 0，于是那行 `BUDGET` 被删了
// —— 规则从"等于某个数"变成"必须为 0"。要加回一个例外，就得在这里写第二个数，
// 而评审一眼就能看见（这比"名单表"难隐藏得多）。
//
// ## 口径
//
// - **行首是注释就不算用法**。不剥注释是为了保住行号（块注释会被整段吞掉）。
// - 正则取 `client\.call<` 是精确的：`wire/rpc/` 里所有 RPC 调用都带显式泛型，
//   而 `onEndpointsChanged?.call(...)` 那类回调不带 `<`，不会误命中。
// - 路径全部相对仓库根（`verify-tool-paths.mjs` 会拦盘符字面量），跑之前先 cd 到仓库根。
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

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

const ok = hits.length === 0
console.log(
  ok
    ? 'PASS — `data/` 与 `ui/` 里没有 client.call<（协议知识只在 wire/rpc/）'
    : `FAIL — 实测 ${hits.length} 处 client.call< 漏在 wire/ 外面（规则是零例外）`,
)
if (!ok) {
  for (const hit of hits) console.log('  ', hit)
  process.exitCode = 1
}
