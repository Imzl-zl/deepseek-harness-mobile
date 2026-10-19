/// 对话流的"滚到顶就翻页"判据。
///
/// ## 为什么单独一个文件
///
/// 触发点在 `_ConversationFlow`（私有 StatefulWidget）里，widget 测试构不出它。
/// 而"到没到顶"是个**纯判据**（给定滚动位置，回答要不要翻）——
/// 抽出来就能单测，触发点只剩"把判据接上"的一行。
///
/// ## 与 DSH 的对应
///
/// DSH Web 的 `loadOlder`（`client/sessions/session.ts:406`）由
/// `use-chat-navigation.ts:94` 的 `loadEarlier` 调，触发条件在
/// `use-chat-viewport.ts` 的 virtualizer 里（滚到最早一端）。
///
/// **手机有意偏离**：DSH 那套是 virtualizer + viewport + reading 状态机
/// （要同时管"跟随尾部 / 保持阅读位置 / 翻页锚点"）。手机没有虚拟列表，
/// `ScrollController` 一行就能判 —— 照抄那套会把一个
/// `pixels >= maxScrollExtent` 的判断变成三百行状态机。
library;

/// 滚到最早一端之前多少像素就开始翻。
///
/// **不到顶就翻**（而不是死死顶住）：用户的手指到不了"绝对顶"，
/// 留 80px 让"看起来到底了"就触发。真机 1080p 上 80px ≈ 一个条目高度。
const double kLoadOlderTriggerInset = 80;

/// 这个滚动位置该不该触发"翻更早的历史"。
///
/// [reverse] 为真时列表倒序（`offset 0` = 最新一端），所以"历史那一端"是
/// `maxScrollExtent`；为假时相反。
///
/// [hasMore] 为假时**永远不翻**：那是"不知道有没有更多"或"确定没有"，
/// 两种情况都不该发一次必然空手的请求。
bool shouldLoadOlder({
  required double pixels,
  required double maxScrollExtent,
  required bool hasMore,
  bool reverse = true,
}) {
  if (!hasMore) return false;
  // 没有可滚内容时 `maxScrollExtent` 是 0，而 `pixels` 也是 0 ——
  // 那时"到顶"是恒真的，会在每次布局时都触发。所以要求真的有内容可滚。
  if (maxScrollExtent <= 0) return false;
  final atOldest = reverse
      ? pixels >= maxScrollExtent - kLoadOlderTriggerInset
      : pixels <= kLoadOlderTriggerInset;
  return atOldest;
}
