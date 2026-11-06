/// 测试里造投影 / 算条目身份的**唯一入口**：规则走生产的那一份。
///
/// ## 为什么有这一层
///
/// `projectEvent` 现在收 `SessionEvent.itemId` —— 身份在**解码边界**算一次
/// （`core/items.dart` 的 `itemIdOf` + `wire/events.dart` 的字段读法）。测试要造一条
/// 投影就得给 id，而**手写 `'t:call-1'` 是把规则抄进测试**：规则一改，测试照样绿，
/// 却不再证明任何事（本仓为这类"自己哄自己"付过代价）。
///
/// 所以这里用**生产规则**算：id 来自 `core/items.dart`，字段读法来自
/// `wire/events.dart` 的 `kWireEventIdReaders`。测试可以 import `wire/`
/// （依赖方向的门禁只管 `core/` 与 `data/`）。
///
/// ## 用法（调用点一个字符都不用改）
///
/// ```dart
/// import 'package:dsh_mobile/data/projection.dart' hide projectEvent;
/// import 'package:dsh_mobile/core/items.dart' hide itemIdOf; // 需要 EventLike 时
/// import 'projection_fixture.dart';
/// ```
///
/// 于是 `projectEvent(...)` / `itemIdOf(...)` 这两个名字在本文件里指向下面这两个
/// 转发版，行为与生产一致，只是 id 由规则算出而不是由测试编。
library;

import 'package:dsh_mobile/core/items.dart' as core show EventLike, itemIdOf;
import 'package:dsh_mobile/data/projection.dart'
    as wire_free
    show ChatProjection, TurnStats, interactionSignalOf, projectEvent;
import 'package:dsh_mobile/model/chat_item.dart' show ChatItem;
import 'package:dsh_mobile/model/interaction.dart' show InteractionSignal;
import 'package:dsh_mobile/wire/event_fields.dart' show WireEventFields;
import 'package:dsh_mobile/wire/events.dart' show kWireEventIdReaders;

/// 同 `data/projection.dart` 的 `projectEvent`，但 `itemId` 按生产规则算好、
/// 事件载荷用**生产的那份读者**（`WireEventFields`，与真机同一条解码路）。
wire_free.ChatProjection projectEvent({
  required String type,
  required int seq,
  required Object? data,
  int time = 0,
  bool steering = false,
  bool waking = false,
  ChatItem? previous,
  wire_free.TurnStats? turnStats,
  int? turn,
}) => wire_free.projectEvent(
  itemId: itemIdOf(core.EventLike(type: type, seq: seq, data: data)),
  type: type,
  seq: seq,
  data: data,
  time: time,
  steering: steering,
  waking: waking,
  previous: previous,
  turnStats: turnStats,
  turn: turn,
  fields: const WireEventFields(),
);

/// 同 `data/projection.dart` 的 `interactionSignalOf`，载荷读者用生产的那一份。
InteractionSignal? interactionSignalOf({
  required String type,
  required int seq,
  required Object? data,
}) => wire_free.interactionSignalOf(
  type: type,
  seq: seq,
  data: data,
  fields: const WireEventFields(),
);

/// 同 `core/items.dart` 的 `itemIdOf`，身份字段用生产的那份读法。
String itemIdOf(core.EventLike event) =>
    core.itemIdOf(event, kWireEventIdReaders);
