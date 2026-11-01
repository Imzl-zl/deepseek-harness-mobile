/// 只读快照的**内容摘要**（契约 §5.7 的 `digest` / `notModified`）。
///
/// ## 它回答什么
///
/// "这一次要不要搬"。它**不**回答"什么时候可能变了"（那归 `host` 帧），
/// 也**不**回答"一次搬多少"（那归分页）。四层分工见
/// `docs/subsystems/app-channel-client.md` §2.3。
///
/// ## 为什么可以信任一个摘要
///
/// 1. 摘要算在**手机收到的那一包字节**上（连接层解箱后就是它），所以"内容变了"
///    必然改变摘要；服务端算的是"它将要发出的那份字节"，两侧同源；
/// 2. **服务端每次都重算**：摘要丢了 / 过期了 / 换了一条连接，最坏结果是
///    "多发一次正文"，绝不会"服务端说没变、手机却是旧值"；
/// 3. 只有**成功应用**之后才记下这一包的摘要（`SyncClient.commitSnapshot`）——
///    记早了就等于声称"我手里有它"，而那时解码可能失败、界面并没有这份内容。
///
/// ## 键为什么是 `(方法, 参数)`
///
/// 分页之后同一个方法在不同参数下是**不同的包**（`session.list` 的
/// `limit` / `offset` 不同、`session.projections` 的 `sid` 不同）。
/// 共用一个摘要就是错配：第二页会被当成"与第一页相同"。
///
/// 取舍与被否方案见 `.agents/notes/proposed/2026-11-01-never-pull-unchanged.md`。
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart' show Sha256;

/// 一次只读快照调用的结局。
///
/// 三态是必需的：`notModified` 与"读不出（形状认不出）"在语义上相反 ——
/// 前者**什么都不做**，后者要留声。用 `null` 一个值兜两种意思，
/// 症状就是"形状坏了但界面安静地停在旧值上"。
class SnapshotReply<T> {
  /// 拿到了正文。[key] 用来在应用成功之后记下这一包的摘要。
  const SnapshotReply.body(this.value, {required this.key})
    : notModified = false;

  /// 服务端说"你手里那包就是最新的"：**不清数据、不报错、不通知**。
  const SnapshotReply.notModified({required this.key})
    : value = null,
      notModified = true;

  final T? value;

  /// `(方法, 参数)` 的规范键（[snapshotKeyOf]）。
  final String key;

  final bool notModified;
}

/// `(方法, 参数)` 的**规范键**：键名排序后序列化，所以"同样的参数"永远同一个键。
///
/// 参数只会有标量与字符串数组（`sid` / `limit` / `offset` / `namespaces`），
/// 排序一遍就足以稳定；**不追求通用**（通用规范化会把"参数形状"这件事
/// 变成又一个要维护的协议）。
String snapshotKeyOf(String method, Map<String, Object?> params) {
  final names = params.keys.toList()..sort();
  final ordered = <String, Object?>{
    for (final name in names) name: params[name],
  };
  return '$method|${jsonEncode(ordered)}';
}

/// 一包明文 `res` 的摘要：`base64url(sha256(utf8))`，43 个字符、无填充。
///
/// **与连接器同一个算式**（`connector/src/protocol/snapshot-digest.ts` 的
/// `snapshotDigestOf`）：算的是**收到的字节**，不是解码后再序列化一遍的结果
/// （后者在字段顺序 / 数字格式上可能与线上不同 —— 那样永远不命中，而症状只是
/// "摘要上线了，一个字节也没省"）。两侧同一向量在各自的用例里钉住。
Future<String> snapshotDigestOf(String plaintext) async {
  final digest = await Sha256().hash(utf8.encode(plaintext));
  // **去掉 `=` 填充**：连接器用的是 Node 的 `base64url`（无填充），
  // 而 Dart 的 `base64Url.encode` 会补上。留着填充就是"两边永远对不上"，
  // 而症状只是"摘要从没命中过"（多发字节，没人会去查）。
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}
