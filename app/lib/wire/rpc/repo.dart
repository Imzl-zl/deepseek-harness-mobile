/// **能力面**（`repo.info`）的唯一入口。
///
/// 形状出处 `connector/src/handlers.ts:1544-1560`：
/// `{protocol, caps, aliasVersion, methods, dshVersion?, commands?}`。
///
/// ## 手机只用其中五样
///
/// | 键 | 手机拿它做什么 | 缺了怎么办 |
/// |---|---|---|
/// | `caps.references` / `caps.files` / `caps.changes` / `caps.plugins` | 决定 `@` 面板 / 文件页 / 改动卡 / 插件页**显不显示** | 按 `false`（老连接器） |
/// | `caps.jobs` | 决定**要不要发 `job.list`**（缺服务时那个方法不存在） | 按 `true`（老连接器照样能拉） |
/// | `commands` | `/` 候选菜单的**唯一**内容来源 | 空表 ⇒ 不出菜单 |
/// | `dshVersion` | 与 App 版本并排显示（排错用） | `null` ⇒ 显示"未读到" |
/// | `hostName` | 电脑自报的名字（展示值，`os.hostname()`） | `null` ⇒ 不显示名字 |
/// | `methods` | **不读**（只用它数条数做形状检查） | 见下 |
///
/// `protocol` / `aliasVersion` 手机**不读**（前者在上线帧的 `v` 里校验，后者是连接器内部账），
/// 所以**不声明** —— 少声明一个键就少一处要维护的漂移面。
///
/// ## `methods` 为什么只数条数
///
/// 它是 `Object.keys(handlers).sort()`（`handlers.ts:1552`）：**加任何一个方法它都会变**。
/// 金样拿它做逐字比较就会为"与形状无关的原因"常年红，所以：
/// - 解码层只输出 `methodCount`（形状变化仍看得见：不是数组就计一次数）；
/// - 金样采样时**把这个键归一掉**（`connector/tests/wire-shapes.test.ts` 的 `normalize`），
///   另有一条连接器用例单独钉"它是排好序的字符串数组、并且含 `repo.info` 自己"。
///
/// `commands` 的**两种形状都收**（旧 `string[]` 与新 `{name, description?}[]`）：
/// 那是连接器**有意的兼容决定**，不是两个真值 —— 解析器只有一个
/// （`model/command.dart` 的 `parseSlashCommands`），这里只负责把值递过去。
///
/// Note: 布局与批次见 `.agents/notes/implemented/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/repo_info.dart';
import '../../core/snapshot_digest.dart';
import '../../core/sync_client.dart';
import '../../model/command.dart' show parseSlashCommands;
import '../fields.dart';
import '../reading.dart';
import 'snapshot.dart';

/// 消费方一次拿齐"三态内核 + 字段内核 + 能力面解码"。
export '../fields.dart';
export '../reading.dart';

const String _kRepoInfo = 'repo.info';

// `repo.info` 的**值类型**在 `core/repo_info.dart`（端口 `HostRpc` 要能返回它）；
// 下面只剩"怎么从线上那一份解出来"。

/// 读一次 `repo.info`（排错要它：手机版本与电脑版本并排看）。
///
/// 带内容摘要：它是**进程级事实**（版本 / 能力位），一次会话里几乎不会变。
Future<SnapshotReply<RepoInfo?>> loadRepoInfo(SyncClient client) =>
    loadSnapshot(client, _kRepoInfo, const {}, readRepoInfo);

/// `repo.info` 的应答。
///
/// **`caps` 是必填**（连接器无条件写出它）；三个能力位各自"缺了 ⇒ false"
/// （老连接器 / 没装那个面），**不计数** —— 那是如实的降级，不是漂移。
/// `methods` / `commands` / `dshVersion` / `hostName` 都是可选。
WireReading<RepoInfo> readRepoInfo(Object? result) =>
    readObject(_kRepoInfo, result, (fields) {
      final caps = fields.requireMap('caps');
      return RepoInfo(
        slashCommands: parseSlashCommands(
          result is Map ? result['commands'] : null,
        ),
        mentionsAvailable: caps['references'] == true,
        filesAvailable: caps['files'] == true,
        changesAvailable: caps['changes'] == true,
        pluginsAvailable: caps['plugins'] == true,
        // **`!= false` 而不是 `== true`**：这个能力位决定"要不要发一次调用"，
        // 不是"要不要画一屏"。老连接器不报这个键时照样该能拉任务 ——
        // 猜错的代价是一次多余的成功调用，而不是整块能力消失。
        jobsAvailable: caps['jobs'] != false,
        dshVersion: fields.optionalNonEmptyString('dshVersion'),
        hostName: fields.optionalNonEmptyString('hostName'),
        methodCount: _methodCountOf(fields),
      );
    });

/// `methods` 的条数。缺席 ⇒ 0（老连接器不报）；在但不是数组 ⇒ 计一次数（形状变了）。
int _methodCountOf(WireFields fields) {
  final raw = fields.optionalList('methods');
  return raw?.length ?? 0;
}
