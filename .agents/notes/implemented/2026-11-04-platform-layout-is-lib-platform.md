# 平台实现就住 `lib/platform/`，别再画一张不存在的 `packages/` 图

- 日期：2026-11-04
- 触发：文档漂移巡检——`app/packages/` 与 `app/lib/platform/registry.dart` 在 5 处文档与 1 个门禁里被当成存在的东西
- 状态：implemented

## 背景

2026-09-30 的三层拆分方案（`.agents/notes/archived/2026-09-30-capability-packages-over-per-platform-dirs.md`）
给"平台差异"划了一个落点：`app/packages/<能力>/`（纯 Dart 端口 + 兜底）+
`app/packages/<能力>_<端>/`（各端实现），`lib/platform/` 只做装配。

实际落地（10-02 起）走了另一条路：**实现直接住在 `app/lib/platform/`**，15 个文件，
按 `<能力>.dart` / `<能力>_<端>.dart` / `<能力>_memory.dart` 命名，装配点也在这一层
（`notify_factory.dart`、`transport_factory.dart`）。`app/packages/` 一天都没存在过。

2026-10-24 的调研已经记过这个缺口（`.agents/notes/proposed/2026-10-24-notifications-and-ui-gaps.md`
「能力包目录在磁盘上不存在」与「要么建、要么改图（**不许图上有、盘上没有**）」），
但它停在 `proposed/` 没定论，于是文档继续按图纸说话。

## 决定

**改图**。平台实现只有一处落点：`app/lib/platform/`。文档、`AGENTS.md`、`tools.md`、
门禁脚本全部对齐到磁盘。

## 被否掉的

- **建 `app/packages/`**：要搬 15 个文件、改全仓 import 与 158 个测试文件的路径，为一条
  **目录美学**规则支付一次全仓改名。而且三段式里"各端实现"那一段在安卓单端阶段根本填不满
  —— 建出来是空壳，只是把漂移从文档搬进代码。
- **只改总纲（`design-and-tech-plan.md`）**：判据散在总纲 / 子系统文档 / `AGENTS.md` /
  `tools.md` / cookbook 五处，只改一处等于下次继续各改各的。
- **把 `app/packages` 留在 `SCAN_DIRS` 里"以后可能要用"**：扫一个不存在的目录 =
  一条永不作废的假绿。删掉（实测数字不变，正好证明它一直没扫到任何东西）。

## 代价

- **`fallback-not-in-release` 当时仍然休眠**（已在 `tools.md` 与脚本里标注，不假装还在守门）：
  路径指向不存在的 `registry.dart`，且兜底已改名 `MemoryNotify`，与规则里的
  `InMemory` / `NullPush` / `Noop` 一个都对不上。

  **同日已唤醒**，并顺带把 `notify_factory.dart` 的静默降级改成 release fail-fast ——
  取舍与变异校验见 `.agents/notes/implemented/2026-11-04-notify-fallback-fails-fast-in-release.md`。

## 顺带唤醒的那条

`ui-no-impl-import` 原本只认 `packages/<能力>_<端>/` 的**目录形态**，改图之后它就再也不会命中。
现在一条正则同时认两种形态：

```js
/import\s+['"][^'"]*_(ios|android|ohos)(?:\/|\.dart['"])/
```

文件形态 `../platform/notify_android.dart` 与残留的目录形态都拦；端口/工厂
（`notify_factory.dart` / `photo_picker.dart`）放行 —— UI 该用的正是它们。

## 验证

- `node app/tools/verify-platform-boundary.mjs` → **715 项全绿**（28 条自检 + 164 个 Dart 文件）；
  当日稍后又唤醒 `fallback-not-in-release`，总数变成 **720 项 / 31 条自检**（见
  `2026-11-04-notify-fallback-fails-fast-in-release.md`）；
  从 `SCAN_DIRS` 里删掉 `app/packages` 后项数**不变** —— 那个目录从来就没被扫到过。
- 变异校验（唤醒后的 `ui-no-impl-import`）：临时在 `app/lib/ui/` 放一个
  `import '../platform/notify_android.dart';` → **1 条红**，恰好是它、且报出了那句 import；
  删掉 → 715 全绿。真正的 UI 文件里没有这种 import（`ui/` 只 import 端口：`photo_picker` /
  `gesture_exclusion` / `pairing_store`）。
- 全仓 `app/packages` 只剩 `docs/prompts/` 下的历史任务提示（不是现状文档，不吃这一套）。
