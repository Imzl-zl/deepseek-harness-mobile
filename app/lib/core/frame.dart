/// 帧层（契约 §3）：帧类型、AAD 规范化、行级编解码。
///
/// 移植源是电脑侧 `connector/src/protocol/frame.ts`（**行为基准**）——
/// 两侧必须逐字节一致，因为 AAD 是把字段拼成串再参与 AEAD：
/// 差一个字符就是"解不开"，而**不是报错**。
///
/// ## 三条硬规则
///
/// 1. **出帧一律以 `\n` 结尾**，而且**只在 [encodeFrame] 这一个口补**。
///    漏了它的表现是"两侧都正常、对端什么都没收到"（本项目真的踩过一次：
///    编解码层没输出 `\n`，而分帧器按 `\n` 切分并把最后一段当半行留着，
///    于是每一帧都被永久缓冲）。所以补换行是编解码层的职责，不是调用方的。
/// 2. **AAD 是 `v|t|id|sid|seq|fc`**，缺字段用**空串**占位（不是 `null`、不是省略分隔符）。
/// 3. **单帧上限 8 MiB**：发送侧不得发出，收到即拒。
///
/// 本文件是**纯 Dart**：不许 import `dart:io` 或 `package:flutter/*`
/// （`node app/tools/verify-platform-boundary.mjs` 会拦）。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 帧版本。对端版本不支持即 `protocol/unsupported-version`（契约 §3.1）。
const int wireVersion = 1;

/// 单帧上限 8 MiB（契约 §3）。
const int maxFrameBytes = 8 * 1024 * 1024;

/// 帧分隔符。契约 §3 说的是**行级** UTF-8 JSON。
const String frameDelimiter = '\n';

/// 线上帧类型 —— 与电脑侧 `FRAME_TYPES` **同一份清单**（契约 §3）。
const List<String> frameTypes = <String>[
  'hello',
  'hello-ack',
  'confirm',
  'pair',
  'pair-ack',
  'ping',
  'pong',
  'credit',
  'req',
  'res',
  'ev',
  'live',
  'job',
  'persisted',
  'presence',
];

/// 握手三帧（明文例外之一，契约 §4.1）。定义在协议层：这是**帧的语义**。
const List<String> handshakeFrameTypes = <String>['hello', 'hello-ack', 'confirm'];

/// 配对两帧。**同握手帧一样是明文**，理由也一样：配对发生在密钥建立**之前**。
const List<String> pairingFrameTypes = <String>['pair', 'pair-ack'];

/// `id` / `sid` 限定的 ASCII 安全字符集（契约 §3）。
///
/// 存在理由：AAD 是拼串再哈希，而两端 JSON 转义习惯不同 —— 限制字符集后
/// 拼串结果与转义无关，AAD 才可能做到"两端字节一致"。
final RegExp idPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// 帧 `id` 的长度（契约 §3：16 字节 base64url）。
const int frameIdBytes = 16;

/// 协议错误码（契约 §3.1 的封闭表里本层用到的几个）。
///
/// 与电脑侧的 `ProtocolError` 对应：调用方按 `code` 分类，
/// 而不是按异常类型 —— 两端的异常类型体系不同，错误码才是协议的一部分。
class ProtocolException implements Exception {
  ProtocolException(this.code, this.message);

  /// 契约 §3.1 的错误码（如 `protocol/bad-frame`）。
  final String code;
  final String message;

  @override
  String toString() => 'ProtocolException($code): $message';
}

/// 是不是握手帧。
bool isHandshakeFrameType(String type) => handshakeFrameTypes.contains(type);

/// 是不是配对帧。
bool isPairingFrameType(String type) => pairingFrameTypes.contains(type);

/// 密钥建立**之前**就能出现的明文帧（握手三帧 + 配对两帧）：不盖 `fc`、不封箱。
bool isPreKeysPlaintextFrame(String type) =>
    isHandshakeFrameType(type) || isPairingFrameType(type);

/// 这一帧是不是**必须封箱**的（契约 §3）。
///
/// 只有两类例外：握手三帧（密钥还没建立）与 `presence`（由中继合成，必须能原样转发）。
/// 其余每种帧都带 `box` —— **包括 `ping` / `pong` / `credit` / `persisted` 这些
/// "没有内容"的控制帧**：它们的载荷是空串，封箱买到的不是保密而是**认证**。
///
/// 判据只写在这里：发之前封什么、收之后解什么、没密钥时哪些帧根本不许发，三处共用它。
bool needsBox(String type) {
  if (type == 'presence') return false;
  if (isPairingFrameType(type)) return false;
  return !isHandshakeFrameType(type);
}

/// AAD 需要参与规范化的字段（契约 §3）。缺字段的位置用**空串**占位。
///
/// 「缺」有两种等价写法：省掉这个键，或显式写 `''` —— 规范化把它们都变成空串。
/// 两种都收，是因为跨端向量（`protocol/vectors/*.json`）里缺字段写作 `''`，
/// 而产品代码习惯省掉。
class AadFields {
  const AadFields({
    this.v = wireVersion,
    required this.t,
    this.id,
    this.sid,
    this.seq,
    this.fc,
  });

  final int v;
  final String t;
  final String? id;
  final String? sid;

  /// 数字或空串。契约的规范化里"缺"与"空串"等价。
  final Object? seq;
  final Object? fc;

  /// 从 JSON 反序列化（向量的 `aad` 字段就是它的形状）。
  factory AadFields.fromJson(Map<String, Object?> json) => AadFields(
        v: (json['v'] as num?)?.toInt() ?? wireVersion,
        t: json['t'] as String,
        id: json['id']?.toString(),
        sid: json['sid']?.toString(),
        seq: json['seq'],
        fc: json['fc'],
      );
}

/// 数字 → 契约要求的十进制字符串：**无前导零、无小数点**。
///
/// Dart 的 `int.toString()` 本身满足这两条，但类型是 `Object?`（可能是空串），
/// 所以这里收口一次，免得每个调用点各自判断。
String _decimal(Object? value) {
  if (value == null) return '';
  if (value is String) return value; // 向量里显式写的 `''`
  if (value is int) return value.toString();
  if (value is double && value == value.truncateToDouble()) {
    return value.truncate().toString();
  }
  throw ProtocolException('protocol/bad-frame', 'AAD 的数字字段必须是整数：$value');
}

/// AAD 规范化：`v "|" t "|" id "|" sid "|" seq "|" fc`（契约 §3）。
///
/// **不要**在这里做补零或十六进制格式化 —— 两端各写一套就再也对不上了。
Uint8List aadOf(AadFields fields) {
  final joined = <String>[
    fields.v.toString(),
    fields.t,
    fields.id ?? '',
    fields.sid ?? '',
    _decimal(fields.seq),
    _decimal(fields.fc),
  ].join('|');
  return Uint8List.fromList(utf8.encode(joined));
}

/// 编码一帧，**带行分隔符**。
///
/// 分隔符必须在编码侧加上：对端的分帧器按行切分，少一个换行就会被当成"半行"
/// 一直缓冲下去 —— 而症状是**对端永远收不到帧**，不是报错。
/// （这个 bug 真的发生过一次，是端到端测试逼出来的；见 `tools.md` 的 Pitfalls。）
///
/// 超限直接抛，不给调用方"先发了再说"的机会。
String encodeFrame(Map<String, Object?> frame) {
  final line = jsonEncode(frame);
  final bytes = utf8.encode(line).length;
  if (bytes > maxFrameBytes) {
    throw ProtocolException(
      'protocol/bad-frame',
      '帧 $bytes 字节超过上限 $maxFrameBytes（类型 ${frame['t']}）',
    );
  }
  return '$line$frameDelimiter';
}

/// 解码一帧的结果。
///
/// 三态而不是"帧或抛"：未知帧类型且带 `id` 时**必须回 `res ok:false`**
/// （沉默会让对端的请求永远挂着），所以调用方要能区分"忽略"与"要回错"。
sealed class DecodeResult {
  const DecodeResult();
}

/// 已知帧。
class DecodedFrame extends DecodeResult {
  const DecodedFrame(this.frame);
  final Map<String, Object?> frame;
}

/// 未知帧类型且**没有** `id` —— 按 §3 忽略，不报错（向前兼容）。
class IgnoredFrame extends DecodeResult {
  const IgnoredFrame(this.type);
  final String type;
}

/// 未知帧类型但**带** `id` —— 必须回 `res ok:false` / `protocol/unsupported-version`。
class UnsupportedFrame extends DecodeResult {
  const UnsupportedFrame(this.id, this.type);
  final String id;
  final String type;
}

/// 解码一帧。
///
/// 抛 [ProtocolException]：超限、不是 JSON、不是对象、或版本不符。
DecodeResult decodeFrame(String line) {
  final bytes = utf8.encode(line).length;
  if (bytes > maxFrameBytes) {
    throw ProtocolException('protocol/bad-frame', '收到 $bytes 字节的帧，超过上限');
  }

  final Object? parsed;
  try {
    parsed = jsonDecode(line);
  } catch (error) {
    throw ProtocolException('protocol/bad-frame', '不是合法 JSON：$error');
  }
  if (parsed is! Map<String, Object?>) {
    throw ProtocolException('protocol/bad-frame', '帧必须是 JSON 对象');
  }

  if (parsed['v'] != wireVersion) {
    // 版本不认识就别猜语义 —— 直接告诉对端升级。
    throw ProtocolException(
      'protocol/unsupported-version',
      '帧版本 ${parsed['v']} 不受支持',
    );
  }

  final type = parsed['t'];
  if (type is! String) {
    throw ProtocolException('protocol/bad-frame', '帧缺少 t');
  }

  if (!frameTypes.contains(type)) {
    final id = parsed['id'];
    if (id is String && id.isNotEmpty) return UnsupportedFrame(id, type);
    return IgnoredFrame(type);
  }

  // `id` / `sid` 的字符集限制要在解码处拦：它们是 AAD 的组成部分，
  // 放进去一个需要转义的字符，两端算出的 AAD 就可能不同 —— 而那表现为"解不开"。
  for (final key in const ['id', 'sid']) {
    final value = parsed[key];
    if (value == null) continue;
    if (value is! String || !idPattern.hasMatch(value)) {
      throw ProtocolException('protocol/bad-frame', '$key 不是 ASCII 安全字符集：$value');
    }
  }

  return DecodedFrame(parsed);
}

/// 握手门禁：未完成握手的连接只接受握手帧与配对帧（契约 §2.2）。
///
/// 做成显式函数而不是散在收帧分支里 ——「业务帧在握手前到达」是**攻击面**
/// （对端可能在密钥还没协商好时就想塞业务数据），值得一个能被测试直接点名的判据。
void assertHandshakePhase(Map<String, Object?> frame, {required bool handshakeDone}) {
  if (handshakeDone) return;
  final type = frame['t'];
  if (type is String && (isHandshakeFrameType(type) || isPairingFrameType(type))) return;
  throw ProtocolException(
    'protocol/bad-frame',
    '握手未完成时收到 $type 帧：本阶段只接受 ${[...handshakeFrameTypes, ...pairingFrameTypes].join(' / ')}',
  );
}

/// 行级分帧：把 TCP/WS 分片拼回完整的行。
///
/// WebSocket 的消息边界本身是一帧，但按行切更稳：将来换 TCP 或加压缩都不会退化。
/// **前提是发送方带上了分隔符**（[encodeFrame] 会带）；漏了的话这一侧会一直等"半行"，
/// 直到超过 8 MiB 才以 `protocol/bad-frame` 报出来 —— 是有声音的失败，不是静默挂死。
///
/// 超限的未闭合行会在**拼完之前**就被拦掉，避免一个不走空格的攻击者把内存吃光。
class LineSplitter {
  String _buffer = '';

  /// 喂一片数据，返回其中**完整**的行（不含分隔符）。
  List<String> call(String chunk) {
    _buffer += chunk;
    if (utf8.encode(_buffer).length > maxFrameBytes) {
      _buffer = '';
      throw ProtocolException('protocol/bad-frame', '未闭合的行超过单帧上限');
    }
    final lines = _buffer.split(frameDelimiter);
    // 最后一段可能是半行，留到下一片。
    _buffer = lines.removeLast();
    return lines.where((line) => line.trim().isNotEmpty).toList();
  }
}

/// 生成一个帧 `id`（16 字节 base64url）。
///
/// 与 [idPattern] 放在同一个文件：**字符集约束与生成点是同一件事的两端**。
/// 分开写就会出现手拼 id 的代码（base64 而非 base64url 会带 `+` `/` `=`），
/// 而它的症状是 AAD 拼串两端不一致 —— 表现为"解不开"，不是"字段非法"。
String newFrameId(Uint8List randomBytes) => base64Url.encode(randomBytes).replaceAll('=', '');
