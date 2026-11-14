/// **Agent Teams 的开关**（`team.setEnabled`）的唯一入口。
///
/// 形状出处 `connector/src/handlers.ts` 的 `handlers['team.setEnabled']`：
/// 请求 `{sid, enabled, requestId}`（`enabled` 必须是布尔），应答是空对象 `{}`。
///
/// ## 为什么应答没有解码
///
/// 这个方法的"结果"**不在应答里** —— 宿主只 append 一条 `team/mode` 并 flush
/// （`packages/team/agent-team/src/index.ts:111-118`），真值是**投影**
/// `agentTeam.enabled`。所以写完之后必须重读投影，界面照投影画（**不做乐观更新**，
/// 与 DSH 的 `RootTeamModeToggle` 同一条：它 `checked={mode.enabled}`，
/// 只认 `useProjection('agentTeam')`）。
///
/// 应答里没有任何失败分支可解：失败走 `ProtocolError`，由调用方如实报错
/// （空对象被当成形状检查一次，见 [readTeamSetEnabled]）。
///
/// Note: 为什么经 gateway 转、为什么错误码归 `internal` —— 见
/// `.agents/notes/implemented/2026-11-14-agent-team-readonly.md`。
library;

import '../../core/sync_client.dart';
import '../fields.dart';
import '../reading.dart';

/// 消费方一次拿齐"三态内核 + 字段内核"。
export '../fields.dart';
export '../reading.dart';

const String _kSetEnabled = 'team.setEnabled';

/// 开关 Team 模式。
///
/// @param sid - 手机会话别名（必须是**根会话**，否则电脑侧回 `internal` 并带
///   `TEAM_LEAD_REQUIRED` 原文 —— 手机上不该走到这一步，子会话不显示开关）
/// @returns `true` = 电脑侧接纳了这次写入；`false` = 应答形状认不出（计一次数）
/// @throws ProtocolException 电脑侧拒绝时原样抛（原因在 `lastError`）
Future<bool> setTeamEnabled(
  SyncClient client, {
  required String sid,
  required bool enabled,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kSetEnabled, {
    'sid': sid,
    'enabled': enabled,
  }, requestId: requestId);
  return valueOrReport(readTeamSetEnabled(result), _kSetEnabled) ?? false;
}

/// `team.setEnabled` 的应答：**必须是对象**（连接器回 `{}`）。
///
/// 回 `true` 只表示"形状对"；真值靠重读投影 —— 见文件头。
WireReading<bool> readTeamSetEnabled(Object? result) =>
    readObject(_kSetEnabled, result, (_) => true);
