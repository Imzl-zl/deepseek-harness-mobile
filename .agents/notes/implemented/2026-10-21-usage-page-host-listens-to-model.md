# Agent Note: 用量页的数据缝收进 `UsagePageHost` —— 独立路由必须自己听 `AppModel`

Status: implemented

## Problem

用户 2026-10-21 真机：「我看用量都没有东西啊？」——用量页永远显示
「还没有用量数据」，而同屏的统计条摆着 92.7K tok、电脑侧两处会话加起来 578K。

根因在接线（`main.dart` 的 `_openUsage`）：

```dart
unawaited(app.refreshUsageSummary());         // ① 异步开始拉
push(MaterialPageRoute(
  builder: (_) => UsagePage(summary: app.usageSummary),  // ② 立刻读 —— null
));
```

`UsagePage` 是 `StatelessWidget`、只拿一份快照、**不监听 `AppModel`**；
拉回来的数据没有任何东西触发重画。于是它**必然**是空的 —— 不是"这台电脑没用量"。

单元测试全绿是因为它们直接 `UsagePage(summary: _summary)`，从来没走"拉取 → 重画"这条路。

## Decision

把"拉 + 听"收进一个 host widget：`UsagePageHost`（`app/lib/ui/usage_page.dart`）
—— `initState` 里拉一次，`build` 里 `ListenableBuilder(listenable: app)` 包住
`UsagePage`。`main.dart` 只 push 这个 host，**不再先拉再传快照**。

顺带把 `refreshUsageSummary` 的 `on ProtocolException` 改成 `catch (error)`：
与 `refreshSessions` 同一条纪律（解析 / 类型 / 超时不该逃逸成未处理的异步错误，
界面停在空态且不报错正是最难查的形态）。

## Alternatives considered

1. **把 `UsagePage` 改成 `StatefulWidget` 自己拉**
   - 最强的理由：一页一处，不必多一个类。
   - 为何被否：本仓已定的约定是"页面不发请求，拉取是 `AppModel` 的事"
     （`ui/usage_page.dart` 文件头、设置页同一条）。让页面自己发请求会多出
     第二个"谁负责拉"的答案，而下一个页面会照着抄。
2. **在 `_openUsage` 里 `await app.refreshUsageSummary()` 再 push**
   - 最强的理由：改动最小，一行 `await`。
   - 为何被否：进页面会先卡在一个没有反馈的等待里（网络慢时是一片白）；
     而且"打开时拉一次"之后**再也不会更新** —— 用户在页面上时别的会话还在跑。
3. **只在 `main.dart` 的 route builder 里套 `ListenableBuilder`**
   - 最强的理由：不用新类。
   - 为何被否：那样"拉一次"的时机就得留在 `_openUsage` 里，
     而它每次重建都会被 route builder 调一次 —— 拉取与重画散在两个地方，
     谁先谁后只能靠读代码。收进 host 之后只有一处。

## Consequences

- 收益：用量页真机上显示出真数（578K / 两个项目 / 两个会话）；
  与统计条、`session.projections` 同源，不引入第二份账。
- 代价：多一个 widget（`UsagePageHost`），`UsagePage` 仍是纯展示（测试照旧直接喂 fixture）。
- 代价：`refreshUsageSummary` 现在会把**任何**异常记进 `lastError`，
  页面的空态会带上原因（"拉不到用量：…"）——这是有意的：空与失败必须分开说。
- 同类排查：pushed `SettingsPage` 与 `showArchiveSheet` 本来就有 `ListenableBuilder`，
  所以这一类**只有用量页一处**（判据写进了 `tools.md` 的 Pitfalls）。
- 验证：`app/test/usage_page_test.dart` 的「UsagePageHost：拉到的数据会自己画出来」
  （先断言空态、再 pump 两帧断言总量 `10.2K`）；做过变异校验 ——
  把 `listenable` 换成常量后该用例精确变红（页面停在「还没有用量数据」）。
