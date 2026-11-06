# 发消息改走 `AppModel`：`ui → wire` 清零

- 日期：2026-11-06
- 状态：implemented
- 前情：P1 后半四批把 `data → wire` 清到只剩 `data/projection.dart` 一条
  （`implemented/2026-11-06-p1b-batch4-read-write-ports.md`）。这一篇收掉最后一条
  **`ui → wire`**。

## Problem

`ui/chat_page.dart` 直接 import 了两个 wire 文件，自己调发送：

```dart
import '../wire/rpc/session.dart' show sendPrompt;
import '../wire/rpc/subagent.dart' show sendSubagentPrompt;
```

它旁边那句注释写着"界面层不再知道线上方法的形状"——**那句话是假的**：界面不仅知道
两个方法名，还知道"子会话要走另一个方法"。`app/lib` 里除 `data/projection.dart` 之外，
这是最后一处认线上形状的地方。

## Decision

1. `HostWrites` 加两个方法：`sendPrompt` / `sendSubagentPrompt`（参数形状与
   `session.prompt` / `subagent.prompt` 逐字相同，都带幂等键）。
2. `AppModel` 加两个转发方法（`sendPrompt` / `sendSubagentPrompt`），
   **失败照原样抛**——输入栏原有的 `catch` 仍然说"发送失败：…"，行为不变。
3. `ui/chat_page.dart` 改调 `widget.app.sendPrompt(...)` / `sendSubagentPrompt(...)`，
   删掉那两条 import。

## 为什么是"两个方法"而不是"一个带 bool 的"

两个方法名是**协议事实**：宿主对子会话的 `session.prompt` 直接拒成
`internal: session "…" is owned by subagent routing`（2026-10-21 真机实测）。
合并成一个就得在端口里塞一个 `toSubagent` 开关，而那等于把"有两个方法名"这件事
藏进一个 bool 里；留两个方法，端口如实照抄线上的形状。
（`SendRoute` 那个三档判断仍在 `model/command.dart`：它同时决定要不要走
`command.execute`，不是纯粹的"哪个 RPC"。）

## 为什么由 `AppModel` 转发，而不是让界面自己拿端口

`AppModel` 的文件头写着它是 **UI 的唯一数据入口**。让界面写
`hostRpcOf(app.client).writes.sendPrompt(...)` 会开出第二个入口 —— 今天只多两条 import
的收益，明天就是"界面也能直接拿端口做别的事"。两个转发方法各 6 行，是这个边界的价格。

## 代价

- `AppModel` 多两个纯转发方法（每个 6 行，没有状态、没有判据）。
- `HostWrites` 从 22 个方法变成 24 个。

## 验证

- `cd app; dart analyze --fatal-infos lib test` → No issues found；
  `dart analyze --fatal-infos integration_test` → No issues found。
- `cd app; flutter test` → **1759** 全过（同数）。
- `node app/tools/verify-platform-boundary.mjs` → 797 项全过（185 个 Dart 文件，未变）。
- `node app/tools/verify-rpc-single-caller.mjs` → PASS。
- `dart format --output=none --set-exit-if-changed lib test integration_test` → 0。
- `git grep -l "import '\.\./wire/" -- app/lib` → **只剩 `app/lib/data/projection.dart`**
  （`ui/` 与 `core/` 都是 0；`data/` 那一条按施工图单独一批）。
- **变异校验**：`WireHostWrites.sendPrompt` 改成空实现（消息"静默没发出去"）⇒
  `command_send_test` + `composer_gate_wiring_test` **3 条红**
  （例：`普通文本仍走 session.prompt`）；还原后 13 条全绿。
  顺带确认：`send_mode_test` / `queue_dock_test` **抓不到**这个变异（它们测的是偏好与
  队列渲染，不走发送路径）——所以靶心是前两个文件。

## 没做的

- `data/projection.dart` 的那 1 条（事件载荷的字段读者，与 `projectEvent` 的 55 处调用点
  绑在一起，按施工图单独一批）。
