# Agent Note: 会话标题只有电脑侧一个真值源（`_touchSummary` 不再用本地推导覆盖）

Status: implemented

## Problem

真机反馈（2026-10-17）："APP 的会话还是选中会话就会自动变名字（这个该好几遍了…
本地都有源码还一直不对）"。

**根因不是 2026-10-16 修的那一半**。commit `a9b83c8` 把 `currentTitle` 改成读
`SessionSummary.displayTitle`，但**写侧还有第二个真值源**：
`AppModel._touchSummary` 在**每条 delta 到达时**用构造函数重建整行，
`title: store.title`（`deriveTitle` = 首条用户消息前 30 字）——
于是打开会话 → 订阅 → 快照事件到达 → 标题从 DSH 的投影提示标题变成本地推导名。
列表与顶栏倒是一致的：**一致地错**。

同一处重建还把 `model` / `running` / `blank` / `subagent` / `cwd` 全部掉成默认值
（构造函数缺省值）——点进会话模型 chip 变"未选择"、`running` 丢假，
都是同一个 bug 的其它面。

此前单测抓不到：假客户端的 `sessionUpdates` 恒回空流，`_touchSummary` 从未被调用。

## Decision

1. **标题的唯一来源是电脑侧**：`session.list` 行的投影提示
   （`projections.values.title`）、`session.projections` 的 `title` 投影
   （DSH `session-title/src/index.ts:269-281`，wire view 就是 `string | null`）、
   会话事件流里的 `session/title` 事件。三者都通向 `_applySessionTitle`。
2. **`_touchSummary` 只换计数**：新增 `SessionSummary.withCounters`
   （更新时间 / 条目数 / 待处理数），身份字段一条不动。
3. **删掉本地推导**（`deriveTitle` / `SessionStore.title`）：DSH Web 侧栏对
   无标题会话显示「未命名」而不用目录名兜底（`ui-workspace/README.zh.md:32`），
   推导标题是 Web 没有的第二份真值。
4. **`session/title` 与 `agent/inbox/spliced` 事件在 `_onDelta` 里截住**：
   前者落地成标题，后者触发投影重读（排队队列的变化）——它们进条目表只会
   渲染成不可见的"其它事件"。

## Alternatives（否掉的）

- **只在 `currentTitle` 里优先读投影**：写侧照样覆盖，治标。
- **`_touchSummary` 里保留旧标题**（而不是只换计数）：model/running 那几个字段
  照样掉，只修一半。
- **推导标题降级成兜底**：与 Web 的「未命名」规则分叉，且兜底值在列表里看不见。

## Consequences

- 顶栏与列表**永远同一个字符串**（同一个 `SessionSummary.title`）。
- 切换会话 / 断线重连 / 快照重放都不改标题；DSH 生成标题后（第一条消息落盘后
  异步生成）经 `session/title` 事件或下次开会话更新。
- 回归用例用**能推 delta 的假客户端** + 真实事件形状（`user/message` 的 `data`
  带 `id`、`assistant/message` 的消息在 `data.message` 上），并做过变异校验
  （临时恢复旧行为 → 恰好那两条标题用例红）。
