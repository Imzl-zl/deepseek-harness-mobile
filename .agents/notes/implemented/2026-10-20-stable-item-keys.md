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

- `flutter test 888` 全绿。
- **判据补上了**（`widget_test.dart` 的「会话流按 itemId 复用 key」组）：
  起示例会话 → 点开 `write` 卡（断言 `detail` 出现）→ 调 `loadPreview()`
  造出"同一批 `itemId`、新的列表实例"（**这正是任何一条新事件到达时的形状**）
  → 断言 `detail` **仍在**。
- **一处变异验证**：把 `_keyOf` 改回 `=> GlobalKey()`（等于旧行为：每次新建
  key）→ 该条**红**。所以这条用例真的能抓住这个 bug，不是摆设。
- 两个构造上的坑（写进注释，免得下次重踩）：
  1. 这张卡在示例会话里偏下，而 `ListView` 懒构建、屏外条目不在树上 ——
     用**把测试视口拉高**（`tester.view.physicalSize`）解决；
     用 `scrollUntilVisible` 反而更脆（本页不止一个 `Scrollable`，
     解析时 "Too many elements"）。
  2. `ToolCard` 的 `onTap` 是 `hasDetail ? … : null`，而示例数据原先一条
     `detail` 都没有 ⇒ **示例模式下所有工具卡都点不开**，这个 bug 也就
     "看得到现象、构造不出场景"。所以先给示例的 `write` 卡补了 `detail`。
- **真机确认（2026-10-20）**：`（示例）图标为什么不用字体` → 点 `write` 卡
  → 卡片描述里出现了 `写入了 100 个图标常量：每行一对 name → path，
  外加 12 个语义别名的映射表。`（`uiautomator dump` 读的 content-desc）。
  点之前那张卡是 `clickable=false`（没有 `detail` 就不可点），点之后
  描述里多出这段 —— 展开确实生效。

