/// 只读快照的**带摘要调用**（契约 §5.7 的 `digest` / `notModified`）。
///
/// ## 为什么不把这两个方法塞进 `SyncClient`
///
/// `SyncClient` 是全仓几十个测试替身 `implements` 的端口（`tools.md` 数过）——
/// 往它上面加两个只有真实现才有意义的成员，就得逐处补空实现，而它们本来就
/// 永远走不到摘要那条路。所以做成：
///
/// - {@link SnapshotCaller}：**能力口**，只有真实现与 `FakeSyncClient` 实现；
/// - {@link SnapshotCall} 扩展：调用方（`wire/rpc/*.dart`）在 `SyncClient` 上照常写
///   `client.callSnapshot(...)`；能力口缺失时**退化成普通 `call`**
///   —— 方向是"多发一次正文"，与摘要的整个安全方向一致（见 `snapshot_digest.dart`）。
///
/// ## 接口成员为什么叫 `…WithDigest`
///
/// 它们与扩展的公开名**刻意不同名**：同名时一个 `SyncClient` 类型的变量上
/// `client.callSnapshot(...)` 会解析到扩展，而扩展里再调同名方法就可能又落回扩展
/// —— 递归到栈溢出（2026-11-01 实测一次 `refreshSessionRows` 就炸）。
/// 名字分开之后，"扩展开关"与"真实实现"在任何静态类型下都不会互相顶替。
///
/// 真正的摘要行为由 `test/sync_client_test.dart` 用**真实现 + 假传输**钉住，
/// 不依赖任何替身是否实现这个口。
///
/// 取舍与被否方案（跨重连保留快照 / 给每个 key 造 rev / 行级增量）见
/// `.agents/notes/proposed/2026-11-01-never-pull-unchanged.md`。
library;

import 'snapshot_digest.dart';
import 'sync_client.dart';

/// 带内容摘要的只读快照口（真实现与 `FakeSyncClient` 有）。
abstract interface class SnapshotCaller {
  /// 自动带上"上一次成功应用那一包的摘要"，服务端可能只回 `{notModified: true}`。
  Future<SnapshotReply<Object?>> callSnapshotWithDigest(
    String method,
    Map<String, Object?> params,
  );

  /// 应用成功之后调：把 [SnapshotReply.key] 那一包的摘要记下来。
  ///
  /// **记早了等于声称"我手里有它"**：解码失败时界面并没有这份内容，
  /// 而服务端下次会说"没变"，那一段就再也回不来了（唯一会漏发的方向）。
  void commitSnapshotDigest(String key);
}

/// `SyncClient` 上的摘要调用口（调用方只认这个扩展）。
extension SnapshotCall on SyncClient {
  /// 调一个**只读快照**方法，带内容摘要（契约 §5.7）。
  ///
  /// 返回 `SnapshotReply.notModified` 时调用方**什么都不做**（不清数据、不报错、
  /// 不通知）；拿到正文则解码、应用，然后 [commitSnapshot]。
  Future<SnapshotReply<Object?>> callSnapshot(
    String method,
    Map<String, Object?> params,
  ) async {
    final capability = _snapshotCapabilityOf(this);
    // 花括号不能省：单行 `if (...) return ...;` 一超宽，`dart format` 会把它折成
    // 两行无括号形式，`curly_braces_in_flow_control_structures` 立刻报 info
    // （`--fatal-infos` 下就是 CI 红）。见 tools.md「先 format 再 analyze」。
    if (capability != null) {
      return capability.callSnapshotWithDigest(method, params);
    }
    return SnapshotReply<Object?>.body(
      await call(method, params),
      key: snapshotKeyOf(method, params),
    );
  }

  /// 应用成功：把这一包的摘要记下来（替身没有摘要表时是 no-op）。
  void commitSnapshot(String key) =>
      _snapshotCapabilityOf(this)?.commitSnapshotDigest(key);
}

/// `client as SnapshotCaller`，但**用显式类型转换**而不是 `is` 提升。
///
/// `is` 提升在这里不够用：Dart 对扩展接收者的成员解析仍可能落回扩展自身
/// （表现为无限递归 → 栈溢出），所以取到一个**静态类型就是能力口**的引用再调。
SnapshotCaller? _snapshotCapabilityOf(SyncClient client) =>
    client is SnapshotCaller ? client as SnapshotCaller : null;
