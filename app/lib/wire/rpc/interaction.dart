/// **交互答复面**（`interaction.respond`）的唯一入口。
///
/// 参数形状出处 `connector/src/handlers.ts:1440-1456`（契约 §5.7 / §6.3.1）：
///
/// ```text
/// { sid, itemId, answers: [{ id, selected: string[], custom? }] }
/// ```
///
/// ## 三条纪律都在这一处
///
/// 1. **键是卡自己的 `itemId`**（审批 `i:<approvalId>`、提问 `t:<callId>`）——
///    连接器的在途 claim 也以它为键。**它带冒号，只进信封、不进帧头**（§3 的
///    ASCII 安全字符集过不了，会把连接按 `protocol/bad-frame` 关掉）。
/// 2. **幂等键用同一个 `itemId`**：重复点两次不会变成两次授权（§5.6）。
/// 3. **答案批次原样转发，一个字段都不翻译**：翻译层就是漂移层（§6.3.1）。
///
/// ## 应答不读
///
/// 手机只关心"这次答复有没有送到"（失败要抛，见调用方），回执体对界面没有意义 ——
/// 造一个没人读的 decoder 等于给"我们校验过了"的假象。
///
/// Note: 布局与批次见 `.agents/notes/implemented/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/sync_client.dart';

/// 方法名只在这里出现一次（`connector/src/handlers.ts:1440`）。
const String _kRespond = 'interaction.respond';

/// 把一次答复发给电脑。
///
/// [answers] 是**已经拼好的批次**（`{id, selected, custom?}`），这一层不改一个字段。
/// 失败**照原样抛** —— 调用方（接管卡）要据此把那一项标成"已过期"，
/// 吞掉它会让用户以为答成功了，而答案从未进入会话。
Future<void> respondInteraction(
  SyncClient client, {
  required String sid,
  required String itemId,
  required List<Map<String, Object?>> answers,
}) => client.call<void>(_kRespond, {
  'sid': sid,
  'itemId': itemId,
  'answers': answers,
}, requestId: itemId);
