/// **能力面**（`repo.info`）的唯一入口。
///
/// 形状出处 `connector/src/handlers.ts:1544-1560`：
/// `{protocol, caps, aliasVersion, methods, dshVersion?, commands?}`。
///
/// ## 手机只用其中四样
///
/// | 键 | 手机拿它做什么 | 缺了怎么办 |
/// |---|---|---|
/// | `caps.references` / `caps.files` / `caps.changes` / `caps.plugins` | 决定 `@` 面板 / 文件页 / 改动卡 / 插件页**显不显示** | 按 `false`（老连接器） |
/// | `commands` | `/` 候选菜单的**唯一**内容来源 | 空表 ⇒ 不出菜单 |
/// | `dshVersion` | 与 App 版本并排显示（排错用） | `null` ⇒ 显示"未读到" |
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

import '../../core/sync_client.dart';
import '../../model/command.dart' show SlashCommand, parseSlashCommands;
import '../fields.dart';
import '../reading.dart';

/// 消费方一次拿齐"三态内核 + 字段内核 + 能力面解码"。
export '../fields.dart';
export '../reading.dart';

const String _kRepoInfo = 'repo.info';

/// `repo.info` 里**手机消费的那四样**。
final class RepoInfoWire {
  const RepoInfoWire({
    required this.slashCommands,
    required this.mentionsAvailable,
    required this.filesAvailable,
    required this.changesAvailable,
    required this.pluginsAvailable,
    required this.dshVersion,
    required this.methodCount,
  });

  /// `/` 候选菜单的内容（**电脑侧原样过线**，手机不抄第二份）。
  final List<SlashCommand> slashCommands;

  /// `caps.references`：`@` 面板显不显示。
  final bool mentionsAvailable;

  /// `caps.files`：文件页显不显示。
  final bool filesAvailable;

  /// `caps.changes`：收口改动卡画不画。
  ///
  /// 缺了（老连接器 / 没装 `workspace-changes` 的部署）就**不画卡片** ——
  /// 一张永远读不到的卡比没有更糟。
  final bool changesAvailable;

  /// `caps.plugins`：插件页显不显示。
  final bool pluginsAvailable;

  /// 电脑侧 DSH 运行时版本（拿不到就是 `null`，不编一个）。
  final String? dshVersion;

  /// `methods` 的**条数**（形状检查用；方法名手机不读）。
  final int methodCount;
}

/// 读一次 `repo.info`（排错要它：手机版本与电脑版本并排看）。
Future<RepoInfoWire?> loadRepoInfo(SyncClient client) async {
  final result = await client.call<Object?>(_kRepoInfo, const {});
  return valueOrReport(readRepoInfo(result), _kRepoInfo);
}

/// `repo.info` 的应答。
///
/// **`caps` 是必填**（连接器无条件写出它）；三个能力位各自"缺了 ⇒ false"
/// （老连接器 / 没装那个面），**不计数** —— 那是如实的降级，不是漂移。
/// `methods` / `commands` / `dshVersion` 都是可选。
WireReading<RepoInfoWire> readRepoInfo(Object? result) =>
    readObject(_kRepoInfo, result, (fields) {
      final caps = fields.requireMap('caps');
      return RepoInfoWire(
        slashCommands: parseSlashCommands(
          result is Map ? result['commands'] : null,
        ),
        mentionsAvailable: caps['references'] == true,
        filesAvailable: caps['files'] == true,
        changesAvailable: caps['changes'] == true,
        pluginsAvailable: caps['plugins'] == true,
        dshVersion: fields.optionalNonEmptyString('dshVersion'),
        methodCount: _methodCountOf(fields),
      );
    });

/// `methods` 的条数。缺席 ⇒ 0（老连接器不报）；在但不是数组 ⇒ 计一次数（形状变了）。
int _methodCountOf(WireFields fields) {
  final raw = fields.optionalList('methods');
  return raw?.length ?? 0;
}
