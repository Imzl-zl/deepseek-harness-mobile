# Agent Note: 任务输出缓冲的两个真缺陷 —— 重开流叠加、无限增长

Status: implemented

## Problem

`data/job_book.dart` 的输出缓冲原来是 `Map<String, StringBuffer>`，两条判据都错：

### 1. 重新展开任务，日志会**重复一遍**

宿主 `job.follow` 的契约（`packages/api/job-controller/src/types.ts:55-62`）：

> *Absolute byte offset to resume from (a prior frame's `next`). **Omitted, the stream
> starts at the oldest retained byte**.*

而手机侧展开任务是 `follow`、收起是 `unfollow`（`ui/chat_page.dart:2877-2879`）。
于是"展开 → 收起 → 再展开"时宿主会**从头重放**，而原来的写法是
`_output.putIfAbsent(row.id, StringBuffer.new)` —— 保留旧缓冲，重放**追加**上去。

用户看到的是同一段日志出现两遍。`JobOpened` 帧带着 `from`（这条流从哪开始），
原来那个字段解析出来之后**没有任何消费者**（`core/job.dart:145-154` 有 `from`，
`job_book.dart` 不读它）。

### 2. 缓冲只增不减

`unfollow` 只清 `_followed`，不清 `_output`；整个 `JobBook` 也没有任何裁剪。
一条跑了半小时的构建任务，其输出会**在 App 的整个生命周期里一直留着**。

而宿主自己只留：`DEFAULT_RETAIN_BYTES = 256 * 1024`（跑着时）、
`DEFAULT_SETTLED_RETAIN_BYTES = 16 * 1024`（结算后收紧，`jobs-local/src/index.ts:37,40,624-628`）。
**手机留得比宿主更久，等于在保留宿主已经判定"不值得留"的字节。**

## Decision

两条一起改，都**跟着宿主的语义走**，一个新概念都不加：

1. **`JobOpened` 整份重置缓冲**，并按 `from` 决定要不要标"前面有洞"：
   - `from == 0`：干净重置；
   - `from > 0`：宿主已淘汰前面一段 ⇒ 重置 + 正文最前面内联
     `…（较早的输出已被淘汰）`（与 `gapBefore` 同一句话）。
2. **裁剪跟着宿主的两档**：跑着时封顶 `kJobOutputLiveChars = 256 KiB`（字符），
   结算后收紧到 `kJobOutputSettledChars = 16 KiB`。裁掉之后同样内联标出缺口，
   并 `dropPartialHead()` 丢掉半行。
3. **单位是字符而不是字节**：宿主按 UTF-8 字节算，这里是一个 Dart `String`。
   逐 chunk 编 UTF-8 只为了数长度不值，而任务输出绝大多数是 ASCII（两者相等）；
   中文日志下上限更宽松 —— 但**仍然有界**，这条判据要的是"不会无限涨"。
4. **`jobError` 通道只留给"流本身出过问题"**（订阅中断 / 宿主报 `lossy`），
   裁掉的缺口内联在正文里。两件事挤一个管道会让"为什么有洞"说不清。

准入判据（`app/test/job_output_buffer_test.dart`，四个用例写完先跑红再修绿）：

- 重开流**不叠加**（重放替换）；
- `from > 0` 时**不再出现上一条流的残余**，且显式标注有洞；
- 600 KiB 输入下缓冲**有界**且留的是尾巴；
- 结算后长度**变短**（收到 16 KiB 那一档）。

变异校验（两条都实测命中）：

- `JobOpened` 改回 `putIfAbsent` → 用例 1、2 红；
- `trim()` 改成恒 `false` → 用例 3 红。

## Alternatives considered

1. **只修叠加，不裁剪**
   - 最强的理由：改动最小，不引入任何数字。
   - 为何被否：那 256 KiB / 16 KiB 不是我们发明的最长保留量，是**宿主的**；不跟它走
     就等于自造一份比宿主更长的保留策略。两个缺陷同源（都是"缓冲的生命周期没跟流走"），
     分开做会让人以为裁剪是可选的。
2. **精确按 UTF-8 字节数裁剪**
   - 最强的理由：与宿主完全同单位，界限一致。
   - 为何被否：每个 chunk 都要 `utf8.encode` 只为了数长度；而多字节字符被从中间切开会
     产生半个码点（用字符切不会）。偏差方向是"中文日志留得多一点"，仍然有界。
3. **`unfollow` 时直接丢弃缓冲**
   - 最强的理由：最省内存，收起就没人看。
   - 为何被否：再展开会读到空的，而宿主**会**重放它的保留窗 —— 于是"先空一帧再突然全出来"，
     比现在更闪。保留 + 重置的代价只是多留最多 256 KiB。

## Consequences

- 收益：**重复日志**（可复现、看得见）消失；**长期任务的内存**从无上界变成跟宿主同档。
- 代价：重开一个长任务时，面板只剩宿主那一窗（最多少于 256 KiB / 结算后 16 KiB），
  前面被我们多留的那部分**没了**。这是有意的：桌面端看到的也是这一窗。
- 代价：字符 ≈ 字节的近似写在常量注释里，别当成"精确对齐"。
- 未做：`JobBook` 里 `_jobs` / `_followed` 仍按会话累积（体积与任务数线性，且都已由
  `job.list` 重拉覆盖），不在这一批范围。
- 关联：`implemented/2026-11-11-session-memory-compaction.md`（另一处内存上限）、
  `implemented/2026-11-11-job-book-extraction.md`（这一簇是怎么搬出来的）。
