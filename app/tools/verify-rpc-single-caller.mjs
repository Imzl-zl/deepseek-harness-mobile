// 判据：`app/lib/`（`wire/` 除外）里**零** `client.call<` —— 零例外的绝对规则。
//
// Note: 为什么是"会归零的数"而不是"名单表" —— 见
// `.agents/notes/implemented/2026-10-25-wire-golden-and-session-list.md`；
// 为什么范围从 `data/`+`ui/` 扩到全域 —— 见
// `.agents/notes/proposed/2026-10-26-wire-review-fixes.md`（第 5 批）。
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
// **范围在 2026-10-26 扩到全域**：`core/` 原来还有 `session.page` / `session.refetch`
// 两处 `call<`，门禁看不见它们（设计评审写的是"`app/lib/` 除 `wire/rpc/` 外零"）。
// 那两个调用搬进 `wire/rpc/session_page.dart` 的 `load*` 之后，这里就不需要白名单。
// 连接层的 `session.subscribe` / `session.unsubscribe` 走 outbox 的 `method:` 字段，
// 不是 `call<`，因此天然不在本规则里（它们是连接生命周期，不是请求面）。
//
// ## 口径
//
// - **行首是注释就不算用法**。不剥注释是为了保住行号（块注释会被整段吞掉）。
// - 正则取 `call<`（**排除 `call<T>` 声明**）：适配器写 `client.call<…>`，
//   连接层实现里是无前缀的 `call<Object?>` —— 只认 `client.` 会漏掉后者
//   （2026-10-26 实测：扩目录后仍 PASS，因为 page/refetch 正是这种形态）。
//   端口自己的声明是 `Future<T> call<T>(`，靠 `<T>` 排除；回调用法不带 `<`，不误命中。
// - 路径全部相对仓库根（`verify-tool-paths.mjs` 会拦盘符字面量），跑之前先 cd 到仓库根。
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = 'app/lib'
/** 协议层自己当然有 `call<`：它是唯一允许出现的地方。 */
const WIRE = join('app/lib', 'wire')
/** 行首是注释就不算用法。不剥注释是为了保住行号（块注释会被整段吞掉）。 */
const COMMENT_LINE = /^\s*(\/\/|\*|\/\*)/

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    if (full === WIRE) continue
    if (statSync(full).isDirectory()) walk(full, out)
    else if (entry.endsWith('.dart')) out.push(full)
  }
  return out
}

const hits = []
for (const file of walk(ROOT)) {
  readFileSync(file, 'utf8').split('\n').forEach((line, index) => {
    if (COMMENT_LINE.test(line)) return
    // `call<T>` 是端口声明的类型参数，不是一次调用。
    if (/call<(?!T>)/.test(line)) hits.push(`${relative('.', file)}:${index + 1}`)
  })
}

const ok = hits.length === 0
console.log(
  ok
    ? 'PASS — `app/lib`（`wire/` 除外）里没有 client.call<（协议知识只在 wire/）'
    : `FAIL — 实测 ${hits.length} 处 client.call< 漏在 wire/ 外面（规则是零例外）`,
)
if (!ok) {
  for (const hit of hits) console.log('  ', hit)
  process.exitCode = 1
}
