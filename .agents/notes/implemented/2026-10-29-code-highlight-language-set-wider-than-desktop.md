# Agent Note: 代码高亮认 28 种语言，比桌面的三种宽

Status: implemented

## Problem

`58cf5f2` 给手机接了代码高亮（纯 Dart 的 `re_highlight`），注册了 28 种语言；
桌面 DSH 的 shiki 只高亮 **ts / bash / json** 三种（`markdown/highlight.ts:42`），
标签判据是 `supportsHighlighting(lang) ? lang : codeBlock.title`（`CodeToolbar.tsx:44`）。
两边判据同一条，但"认识哪些语言"这张表不同，于是同一个块会出现两种形态：

| 围栏 | 桌面 | 手机 |
|---|---|---|
| ```` ```rust ```` | 「代码块」+ 单色 | 「rust」+ 彩色 |
| ```` ```toml ```` | 「代码块」+ 单色 | 「代码块」+ 单色（不在表里，一致） |

这张差异只写在代码注释里时，下一个会话很容易把它当 bug 修回去 ——
要么把手机收敛到三种（白丢能力），要么把桌面判据改成"有 info string 就报语言名"
（那会让 ```` ```foo ```` 报「foo」，与宿主不一致）。

## Decision

**保留 28 种**。标签判据的结构与桌面逐条相同（认得的语言报语言名、认不得报「代码块」），
只把"认得哪些"这张表放大；差异写进 `docs/subsystems/app-channel-client.md` §4.1 的
「有意偏离」表，并在 `dsh_code_highlight.dart` 的语言表处回指本篇。

准入门槛（可机械判定）：

1. 数据源只有一处：围栏的 CommonMark info string（`dsh_markdown.dart` 的
   `^language-([\w-]+)`）。不按文件扩展名、不按正文内容猜语言。
2. 判据结构不许分叉：仍是"表里有 ⇒ 报语言名 + 高亮；表里没有 ⇒ 报「代码块」+ 纯文本"。
   扩展只改表（`_languages`），不改判断。
3. 表里新增一门语言必须同时满足：`re_highlight` 自带该语言定义、且手机上有读它的真实场景
   （Dart / JSON / YAML / SQL / shell 这类）。不为"看起来支持得多"堆语言。

## Alternatives considered

1. 收敛到桌面的三种（ts / bash / json）
   - 最强的理由：与桌面逐块一致，验收时不用解释任何差异；包体也最小。
   - 为何被否：数据源相同，多认几种只是渲染更细 —— 手机是"读代码"的高频场景（会话里
    贴的示例、文件预览），把 rust/python/go 打成单色纯文本是白丢能力。差异只出现在
     桌面不认的边缘语言上，写进文档即可。
2. 按文件扩展名猜语言（`.rs` → rust）
   - 最强的理由：info string 缺省时也能上色，覆盖面更大。
   - 为何被否：那是第二套真值。宿主给的只有 info string，扩展名是另一条链路
     （文件预览用），两套一起用会出现"同一个块在聊天里是 rust、在预览里是 toml"。
3. 把 `re_highlight` 的语言全注册
   - 最强的理由：覆盖面最大，永远不用再补表。
   - 为何被否：启动时要建 190 多个 grammar，注册表越大越慢；常用集 28 种已经覆盖
     会话里真会出现的代码。

## Consequences

- 收益：手机上 `rust` / `python` / `go` / `sql` 这类块能读；判据仍与桌面同构，
  将来桌面扩语言集时只需扩表。
- 代价：与桌面在边缘语言上**标签与颜色都不同**，验收时必须解释；这条差异是"渲染扩展"，
  不是数据面差异，所以不进 `wire/`、不影响任何字段。
- 代价：token 结果不缓存（`highlightCode` 在 `build` 里跑），长会话滚动会重复算 ——
  与桌面的"首次进视口算一次并缓存"（`useViewportHighlighting.ts:17,48`）不同，
  已在 `app-channel-client.md` §4 的"代码高亮开销"一行写明。
