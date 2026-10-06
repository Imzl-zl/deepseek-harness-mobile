/// 握手三帧的组装、解析与 transcript 拼接（契约 §4.1）。
///
/// ```text
/// 手机 → 电脑   hello     { box: { ephPubA(32B), devId, nonceA(32B) } }
/// 电脑 → 手机   hello-ack { box: { ephPubB(32B), pcId,  nonceB(32B), sigB } }
/// 手机 → 电脑   confirm   { box: { sigA, transcriptHash[0..8) } }
/// ```
///
/// ## 为什么 transcript 从字段拼、而不是拼两帧 box
///
/// `sigB` 就在 hello-ack 的 `box` 里，而 transcript 又要被 `sigB` 签 —— 拼 box 等于
/// 「签一段包含自己签名的字节」，是循环定义，不存在自洽取值（实测：用占位签名算
/// transcript 再回填，对端拿真实帧必然验不过）。所以被签的是**除签名外的字段**序列：
///
/// ```text
/// dsh-mobile/v1|hello|ephPubA|devId|nonceA|hello-ack|ephPubB|pcId|nonceB
/// ```
///
/// ## 校验在编解码两侧对称
///
/// `encode*` 与 `parse*` 走**同一组**校验函数。只校验一侧会让坏值在本地被放行、
/// 到对端才炸 —— 而那时的错误信息指向对端，不是生产坏值的那一侧。
///
/// 移植源：`connector/src/protocol/handshake-frames.ts`（行为基准）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'frame.dart';

/// transcript 的固定前缀。改动它等于改协议版本。
const String transcriptLabel = 'dsh-mobile/v1';

const int _hex32 = 64; // 32 字节
const int _hex64 = 128; // 64 字节
const int _hex8 = 16; // 8 字节

String _hex(Object? value, String field, int length) {
  if (value is! String ||
      value.length != length ||
      !RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
    throw ProtocolException(
      ErrorCode.badFrame,
      '$field 必须是 ${length ~/ 2} 字节的十六进制',
    );
  }
  return value;
}

String _id(Object? value, String field) {
  if (value is! String || !idPattern.hasMatch(value)) {
    throw ProtocolException(ErrorCode.badFrame, '$field 必须是 ASCII 安全字符集');
  }
  return value;
}

Map<String, Object?> _unbox(String box, String field) {
  final Object? payload;
  try {
    payload = jsonDecode(box);
  } catch (error) {
    throw ProtocolException(ErrorCode.badFrame, '$field 无法解析：$error');
  }
  if (payload is! Map<String, Object?>) {
    throw ProtocolException(ErrorCode.badFrame, '$field 必须是 JSON 对象');
  }
  return payload;
}

/// `hello` 的字段（手机 → 电脑）。
class HelloFields {
  const HelloFields({
    required this.ephPubA,
    required this.devId,
    required this.nonceA,
  });

  final String ephPubA;
  final String devId;
  final String nonceA;
}

/// `hello-ack` 的字段（电脑 → 手机）。
class HelloAckFields {
  const HelloAckFields({
    required this.ephPubB,
    required this.pcId,
    required this.nonceB,
  });

  final String ephPubB;
  final String pcId;
  final String nonceB;
}

/// `confirm` 的字段（手机 → 电脑）。
class ConfirmFields {
  const ConfirmFields({required this.sigA, required this.transcriptHash});

  final String sigA;
  final String transcriptHash;
}

/// 两个端点必须算出**同一段字节**（§4.1）。顺序是协议的一部分：
/// 换顺序不会报错，只会让两侧算出不同的 transcript —— 于是签名验不过，
/// 而错误信息会说是「公钥被替换」。
///
/// 这个函数同时接受 [HelloFields] / [HelloAckFields] 对象与**向量的字段 map**
/// （`protocol/vectors/handshake.json` 的 `signature.fields` 就是这个形状）。
Uint8List transcriptFromFields(Object hello, [HelloAckFields? ack]) {
  final String ephPubA;
  final String devId;
  final String nonceA;
  final String ephPubB;
  final String pcId;
  final String nonceB;

  if (hello is HelloFields && ack != null) {
    ephPubA = hello.ephPubA;
    devId = hello.devId;
    nonceA = hello.nonceA;
    ephPubB = ack.ephPubB;
    pcId = ack.pcId;
    nonceB = ack.nonceB;
  } else if (hello is Map) {
    // 向量形状：六个字段平铺在一个 map 里。
    ephPubA = '${hello['ephPubA']}';
    devId = '${hello['devId']}';
    nonceA = '${hello['nonceA']}';
    ephPubB = '${hello['ephPubB']}';
    pcId = '${hello['pcId']}';
    nonceB = '${hello['nonceB']}';
  } else {
    throw ArgumentError(
      'transcriptFromFields 需要 (HelloFields, HelloAckFields) 或一个字段 map',
    );
  }

  return Uint8List.fromList(
    utf8.encode(
      <String>[
        transcriptLabel,
        'hello',
        ephPubA,
        devId,
        nonceA,
        'hello-ack',
        ephPubB,
        pcId,
        nonceB,
      ].join('|'),
    ),
  );
}

HelloFields _checkHello(HelloFields input) => HelloFields(
  ephPubA: _hex(input.ephPubA, 'ephPubA', _hex32),
  devId: _id(input.devId, 'devId'),
  nonceA: _hex(input.nonceA, 'nonceA', _hex32),
);

HelloAckFields _checkHelloAck(HelloAckFields input) => HelloAckFields(
  ephPubB: _hex(input.ephPubB, 'ephPubB', _hex32),
  pcId: _id(input.pcId, 'pcId'),
  nonceB: _hex(input.nonceB, 'nonceB', _hex32),
);

ConfirmFields _checkConfirm(ConfirmFields input) => ConfirmFields(
  sigA: _hex(input.sigA, 'sigA', _hex64),
  transcriptHash: _hex(input.transcriptHash, 'transcriptHash', _hex8),
);

/// 编码 `hello`（返回 `box` 里的字符串）。
String encodeHello(HelloFields fields) =>
    jsonEncode(_checkHello(fields).toJson());

/// 编码 `hello-ack`。
String encodeHelloAck(HelloAckFields fields, String sigB) => jsonEncode({
  ..._checkHelloAck(fields).toJson(),
  'sigB': _hex(sigB, 'sigB', _hex64),
});

/// 编码 `confirm`。
String encodeConfirm(ConfirmFields fields) =>
    jsonEncode(_checkConfirm(fields).toJson());

/// 解析 `hello`。
HelloFields parseHello(String box) {
  final raw = _unbox(box, 'hello');
  return _checkHello(
    HelloFields(
      ephPubA: '${raw['ephPubA']}',
      devId: '${raw['devId']}',
      nonceA: '${raw['nonceA']}',
    ),
  );
}

/// 解析 `hello-ack`（含 `sigB`）。
({HelloAckFields fields, String sigB}) parseHelloAck(String box) {
  final raw = _unbox(box, 'hello-ack');
  return (
    fields: _checkHelloAck(
      HelloAckFields(
        ephPubB: '${raw['ephPubB']}',
        pcId: '${raw['pcId']}',
        nonceB: '${raw['nonceB']}',
      ),
    ),
    sigB: _hex(raw['sigB'], 'sigB', _hex64),
  );
}

/// 解析 `confirm`。
ConfirmFields parseConfirm(String box) {
  final raw = _unbox(box, 'confirm');
  return _checkConfirm(
    ConfirmFields(
      sigA: '${raw['sigA']}',
      transcriptHash: '${raw['transcriptHash']}',
    ),
  );
}

extension on HelloFields {
  Map<String, Object?> toJson() => {
    'ephPubA': ephPubA,
    'devId': devId,
    'nonceA': nonceA,
  };
}

extension on HelloAckFields {
  Map<String, Object?> toJson() => {
    'ephPubB': ephPubB,
    'pcId': pcId,
    'nonceB': nonceB,
  };
}

extension on ConfirmFields {
  Map<String, Object?> toJson() => {
    'sigA': sigA,
    'transcriptHash': transcriptHash,
  };
}
