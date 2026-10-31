# Agent Note: 界面卡顿审查（打字重建整页）

Status: implemented

## Problem

用户反馈"APP 有点卡卡的"，要求审查是不是设计不好、方法用错、不符合 Flutter 规范。

两条先摆清的事实：

1. **他们试的是 `flutter build apk --debug` 的包**。debug 是 JIT + 全断言，比 AOT 的
   profile/release 慢 2–5 倍是常态，用它判断"手感"会冤枉代码。
2. **`dumpsys gfxinfo` 对本工程不作数**：Flutter 自己画在 `FlutterSurfaceView`
   （Impeller/Vulkan）上，HWUI 统计拿到的是 `Total frames rendered: 0`。所以"卡"不能靠
   `gfxinfo` 证伪或证实，得用 Flutter 自己的帧时间（profile + DevTools 的 Frame chart，
   或 `flutter run --profile` 里按 `P` 的性能覆盖层）。

## Decision

**只修一处确定性的浪费，其余记下不动**：`_onInputChanged` 不再 `setState(() {})`，
输入栏改用 `ListenableBuilder(listenable: _input)` 局部重画（`ui/chat_page.dart`）。

原来那句 `setState(() {})` 的代价：`ChatPage.build` 的产物包含整个 `Scaffold`
（左抽屉 sections、右抽屉面板、会话列表、统计条、输入栏），**每敲一个字重建一次**。
代码注释还写着"打字不会把整页带起来"—— 那句话说的是不调 `AppModel.notifyListeners`，
而 `setState` 自己就把整页带起来了，注释与代码矛盾，这是本轮修的根因。

## Alternatives considered

1. **顺带把 `ListenableBuilder(listenable: widget.app)` 换成"每帧最多通知一次"的合并器**
   - 最强理由：流式输出时 `AppModel` 一秒通知几十次，每次重建整页（`chat_page.dart:709`），
     而抽屉内容**即使没打开也会重建** —— SDK 的 `DrawerControllerState.build` 无条件构造
     `widget.child`（`packages/flutter/lib/src/material/drawer.dart:711-745`），于是
     `_drawerSections(app)`（`main.dart:1255`：过滤 + 分组 + 每行拼副标题 + `DateTime.now()`）
     跟着每秒算几十遍。
   - 为何本轮没做：它改的是**全 App 最热的通知路径**，而当前没有任何可靠的前后帧时间
     数据（见上，gfxinfo 不可用）。在没量到的情况下改通知时序，等于拿手感赌时序；
     而且延迟一帧的重建会波及一堆"pump 一次就断言"的 widget 用例。先让用户在 profile 包上
     对比"打字"和"流式输出"两种卡是否都还在，再决定动哪一条。
2. **把流式文字改成节流刷新（如 10Hz）**
   - 最强理由：直接砍掉 80% 的重绘。
   - 为何被否：那是**产品行为变更**（字会一顿一顿地出），用户没要求；而且真正该省的是
     "整页重建"，不是"更新频率"。
3. **去掉输入栏那条 `BackdropFilter`（毛玻璃）**
   - 最强理由：σ=20 的全宽模糊要走 `saveLayer`，是唯一一处"每次重画都重算"的 GPU 活。
   - 为何被否：它是用户点名要的效果（"毛玻璃可以啊"），而输入栏在 `Column` 里、内容不从
     它后面滚过去，重画只发生在打字时 —— 修掉整页重建后，它的触发频率已经降到人手级。
     若 profile 包上仍卡，再单独量它。
4. **`_uiScaled` 也改监听粒度**
   - 最强理由：它现在听整个 `AppModel`（`main.dart:626-639`）。
   - 为何被否：它只重建一层 `MediaQuery`（子节点走 `child` 参数不重建），是微秒级；
     改它收益远小于上面那条，属于"优化噪音"。

## Consequences

- 收益：打字不再重建整个会话树；输入栏以外的部件（抽屉 sections / 侧栏 / 列表）在打字时
  一次都不重建。语义不变 —— 发送键点亮、候选面板、占位文案仍随文字变。
- 代价：输入栏里任何"依赖文字"的新逻辑，必须自己监听 `_input`（或放在同一个
  `ListenableBuilder` 里），不能指望父层重建。已在 `_onInputChanged` 的注释里写明。
- 代价：整页重建（流式通知）这条**仍然存在**，是最可能的主因，留给下一轮带测量再动。

## 静态审查：雷区逐条

判据来源：`State.build` 文档（build 要快、无副作用）、`MediaQuery.sizeOf` 文档
（只依赖该字段：键盘弹起不重建）、`Opacity` / `ShaderMask` / `BackdropFilter` 文档
（都提到昂贵/触发 `saveLayer`）、社区共识（`FutureBuilder` 不在 build 里建 future、
长列表用 builder、动画不可见即停）。

**本轮修掉**

| 雷区 | 位置 | 处置 |
|---|---|---|
| build 里做 O(条目数) 派生 | `chat_page.dart` 的 `buildTurnGroups` / `applyTurnCollapse` / `assistantHeadItemIds`，每次通知跑三遍 | 按"items 同一性 + sid + 展开版本 + collapseTiming"缓存（`_derivationFor`）。可靠性来自 `session_store.dart:66-87`：内容没变时 `upsertAll` 提前返回、`_sorted` 不换表 |
| `MediaQuery.of(context).size` | 6 处（`chat_turns.dart:71` 的用户气泡最重：一屏气泡都依赖整份 MediaQueryData） | 全改 `.sizeOf(context)` |

**确认存在、本轮不动（都指向同一个根因：通知粒度）**

| 雷区 | 位置 | 为什么不单独改 |
|---|---|---|
| 整页 `ListenableBuilder(app)` | `chat_page.dart:709` | 见 Alternatives 1：缺可信测量，且波及用例 |
| 抽屉每次通知现算 sections，且关着也在建 | `main.dart:1255` + SDK `material/drawer.dart:711-745` | 与上一条同源，单改一处没用 |
| build 里调 `_takeover.setCurrentSid()` | `chat_page.dart:705` | 幂等且有必要（切会话换桶），但"build 里改状态"本身是脆的写法，已在注释写明 |
| `BackdropFilter` | `dsh_composer.dart`（输入栏毛玻璃） | 用户点名要的效果；修掉整页重建后触发频率已降到人手级 |
| `ShaderMask` 扫光 | `dsh_shimmer.dart:204-209` | 每行把 child 画两遍 + 一层 `saveLayer`；只在"真的在跑"的行上挂，空闲即摘 |
| `Opacity` ×6 | 4 处在动画/拖动中，2 处在弹层淡入 | 动画/拖动本就是短暂交互，改色值会让代码绕一大圈 |

**确认没踩（列出来是为了下次别再查一遍）**

- `FutureBuilder` / `StreamBuilder`：**0 处**（社区最经典的"build 里新建 future，每帧重发一次"）。
- 长列表：聊天用 `ListView.builder`（懒建）；`shrinkWrap` 只出现在设置页的端点小表。
- 图片解码：壁纸按屏宽 `ResizeImage.resizeIfNeeded`；附件 chip 不渲染位图（只显示文件名/计数）。
- 常驻动画：扫光只有一个 ticker，一行都没有时 `stop()`；`AnimationController` 全在 `dispose` 里释放。
- 弹层：没有在 build 里 `showDialog`/`showModalBottomSheet` 的写法。

## Testing

- `cd app; flutter test` —— 1599 项全绿（含 `composer_layout_test` / `composer_pickers_test` /
  `draft_wiring_test` / `slash_suggestions_test`：它们依赖"文字变了输入栏就跟着变"）。
- 真机：`flutter build apk --profile` 安装，用于对比手感（debug 包不作为体感依据）。
