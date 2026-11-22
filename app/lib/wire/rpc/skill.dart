/// **技能目录**（`skill.catalog`）的唯一入口：一次调用 + 纯解码。
///
/// 形状与三态判据见 `model/skill.dart` 的文件头；本文件只做"带摘要地读一次"。
/// 摘要的键含 `sid`（`loadSnapshot` 的 `(方法, 参数)` 规范化），所以不同会话的
/// 目录是两个包，互不命中。
library;

import '../../core/snapshot_digest.dart';
import '../../core/sync_client.dart';
import '../../model/skill.dart' show SkillEntry;
import '../fields.dart';
import '../reading.dart';
import 'snapshot.dart';

export '../fields.dart';
export '../reading.dart';

const String _kCatalog = 'skill.catalog';

/// 拉一次这一会话可见的技能目录。
Future<SnapshotReply<List<SkillEntry>?>> loadSkillCatalog(
  SyncClient client, {
  required String sid,
}) => loadSnapshot(client, _kCatalog, {'sid': sid}, readSkillCatalog);

/// `{skills: [...]}`。**一行认不出就跳过那一行**（`readObjectList` 的口径）；
/// `skills` 不是数组才是 [WireBad]（那是形状漂了，不是"这台电脑没有技能"）。
WireReading<List<SkillEntry>> readSkillCatalog(Object? result) =>
    readObjectList(result, method: _kCatalog, key: 'skills', build: _skillOf);

SkillEntry _skillOf(WireFields fields) => SkillEntry(
  // 名字是身份：空串/缺键的行走不了（`requireNonEmptyString` 会把它算成坏行）。
  name: fields.requireNonEmptyString('name'),
  description: fields.optionalNonEmptyString('description'),
  modelInvocable: fields.optionalBool('modelInvocable'),
);
