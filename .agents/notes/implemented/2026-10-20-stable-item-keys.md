# Agent Note: 会话流的 key 改成按 `itemId` 复用 —— 展开的工具卡不再被自己收起

Status: implemented

## Problem

`_ConversationFlow` 原来这么给每一行分配 key：

```dart
void _syncKeys() {
  _keys = List.generate(widget.items.length, (_) => GlobalKey());
}
// didUpdateWidget: if (!identical(widget.items, old.items)) _syncKeys();
```

**只要条目变了，就换成一批全新的 `GlobalKey`。** 而换 key 在 Flutter 里等于
**让每一行重新挂载**（元素树按 key 匹配，key 变了就是新元素）。

后果有两层：

1. **功能 bug（用户看得见）**：`ToolCard` / `CommandCard` / `CompactionRow` /
   `TurnProcessRow` 都是 `StatefulWidget`，而 `_ToolCardState._open` 这种
   展开状态就存在 `State` 里 —— 于是**展开一张工具卡，只要来一条新事件
   （流式输出、工具结果、任何 delta），它就自己收起**。
   这不是"偶尔"，流式输出时每个 delta 都会触发。
2. **性能**：每帧分配 N 个 `GlobalKey`（它们要注册进全局表），
   并且每帧重建整棵树的状态。

## Decision

改成按 `itemId` 取、跨帧复用：

```dart
final Map<String, GlobalKey> _keysById = {};
GlobalKey _keyOf(String itemId) => _keysById.putIfAbsent(itemId, GlobalKey.new);
```

`itemId` 由 `core/items.dart` 保证**唯一且稳定**（同一条目在重放/翻页后仍是
同一个 id），所以它是这件事的天然键。

配套改动：

- `_firstVisibleIndex` / `_ensureVisible` 从"按 index 取 key"改成
  "按 `items[index].itemId` 取"；
- `_step` 的 clamp 上界从 `_keys.length - 1` 改成 `widget.items.length - 1`
  （`_keysById` 的条目数不一定等于条目数）；
- 新增 `_pruneStaleKeys()`：**只在 `_keysById` 比条目多时**才扫一遍清理
  —— 流式输出时条目只会增/改，那时是 O(1) 空操作，不为"整齐"付每帧的代价。

## Alternatives considered（否掉的）

- **保留 `_keys` 列表但复用已有 key**（长度变了才补）：能保住状态，但每次
  条目变化仍要 O(n) 建表，且 index 与 key 的对应关系在"条目插入/删除"时会错位
  （新条目会拿到别人位置上的 key，比现在更糟）。否。
- **不用 key、靠 `itemId` 做 `ValueKey`**：`ValueKey` 能保状态，但
  `_ensureVisible` / `_firstVisibleIndex` 需要**能 `findRenderObject()` 的
  `GlobalKey`**（`ValueKey` 拿不到 context）。所以仍然要 `GlobalKey`，
  只是要**稳定**。否（这一条是把"为什么不是更简单的 ValueKey"记下来）。

## 验证

- `flutter test 887` 全绿（key 的用法变了，所有涉及会话流渲染的用例都跑过）。
- **一个缺口，如实记下**：这次**没有**自动化判据证明"展开的工具卡在来新事件后
  仍展开" —— 要证明它，测试里得让 `items` 真的变化，也就是给 `FakeSyncClient`
  实现 `sessionUpdates` 并推一条 delta（替身基类现在是"没声明就抛"）。
  那是下一步该补的，**我没有假装测过**。
  补之前的替代证据：这条改动的正确性依赖 Flutter 的一条已文档化的语义
  （key 相同 ⇒ 复用元素与 State），而改动本身把"每帧换 key"变成了"同一
  `itemId` 恒等 key"，方向是确定的。
  真机判据（配对后）：发一句让它输出，中途展开一张工具卡，
  **它应当一直开着**直到手动收起。
