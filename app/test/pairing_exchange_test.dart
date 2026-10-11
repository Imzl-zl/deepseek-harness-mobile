/// 配对载荷的编解码单测（规格 `docs/subsystems/pairing-v2.md` §3–§5）。
///
/// 三条要害：
///
/// 1. **候选身份（换票请求）里没有秘密**：它报的是公开邀请 + 自己的公钥 + 设备名；
///    码只在 `pair-commit` 的密文里出现。写反了不会报错 —— 两侧照样"配对成功"，
///    只是唯一的授权凭据经中转明文走了一趟。
/// 2. **握手上下文是可核对的拼串**：它进被签的字节（§4），字段顺序是协议的一部分
///    （跨端逐字一致由 `pairing_vectors_test.dart` 的向量钉住，这里钉形状与拒绝）。
/// 3. **回执缺字段要拒**，不能拿一个空令牌继续（那会在换票处变成 401，
///    而那时没人会想到根因在回执）。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/pairing.dart';
import 'package:dsh_mobile/core/pairing_exchange.dart';
import 'package:flutter_test/flutter_test.dart';

const _offer = PairingOffer(
  relayUrl: 'ws://127.0.0.1:8787',
  pcId: 'conn-1',
  pcSignPubHex:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  pcDhPubHex:
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  offerId: 'abL3sSH5gLJpTBBsqPUzJg',
  code: 'zyXWvUTSrqPONMLKjihgfe',
);

/// 电脑侧签发的标识/令牌形状：**22 字符 base64url**。
///
/// 手机侧按这个格式校验回执，所以测试数据不能随手写 `tok-1` —— 那会被拒，
/// 而**拒得对**：短令牌拿下去换票必然 401。
String _token(String prefix) => prefix.padRight(22, '0');

void main() {
  group('候选身份：线上形状（换票请求用它）', () {
    const candidate = PairingCandidate(
      offerId: 'abL3sSH5gLJpTBBsqPUzJg',
      devPubEdHex:
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      devPubDhHex:
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
      name: '我的手机',
    );

    test('带 v2 / 邀请 / 两把公钥 / 设备名，**不带码、不带码的哈希**', () {
      final wire = candidate.toWire();
      expect(wire['v'], 2);
      expect(wire['offerId'], 'abL3sSH5gLJpTBBsqPUzJg');
      expect(wire['devPubEd'], 'cc' * 32);
      expect(wire['devPubDh'], 'dd' * 32);
      expect(wire['name'], '我的手机');
      // v1 的换票请求带 `codeHash`（那是**可授权的替代凭据**，中转见过它）。
      // v2 里两者都不出现：秘密只在受限通道的密文里（§1）。
      expect(wire.containsKey('codeHash'), isFalse);
      expect(wire.containsKey('code'), isFalse);
      expect(jsonEncode(wire).contains(_offer.code), isFalse);
    });

    test('握手上下文：固定字段顺序、含邀请/电脑身份/候选身份/设备名哈希', () async {
      final context = await candidate.handshakeContext(_offer);
      final parts = context.split('|');
      expect(parts, hasLength(9));
      expect(parts[0], 'dsh-mobile/pairing/v2');
      expect(parts[1], candidate.offerId);
      expect(parts[2], _offer.pcId);
      expect(parts[3], _offer.pcSignPubHex);
      expect(parts[4], _offer.pcDhPubHex);
      expect(parts[5], await candidate.deviceId());
      expect(parts[6], candidate.devPubEdHex);
      expect(parts[7], candidate.devPubDhHex);
      // 设备名进的是**哈希**（名字是人写的，原样进被签的字节会把编码差异
      // 变成"验签失败"）。
      expect(parts[8], await sha256Hex(candidate.name));
    });
  });

  group('parsePairAck：成功形状', () {
    String ackBox({
      String ok = 'true',
      String devId = '',
      String sas = '123456',
      String pcId = 'conn-1',
      String? deviceToken,
      String? refreshToken,
    }) => jsonEncode(<String, Object?>{
      'ok': ok == 'true',
      'devId': devId.isEmpty ? _token('dev') : devId,
      'sas': sas,
      'pcId': pcId,
      // null-aware 的 `?` 在 map 字面量里作用于**值**：`'key': ?value`。
      // 写成 `?key: value` 是"键可空"的那种形状 —— 而键是字面量、恒非空，
      // 于是 linter 报 `invalid_null_aware_operator`（两条规则在此正好互相纠正）。
      'deviceToken': deviceToken ?? _token('tok'),
      'refreshToken': refreshToken ?? _token('ref'),
    });

    test('取出 devId / SAS / pcId / 两个令牌', () {
      final ack = parsePairAck(ackBox());
      expect(ack.devId, _token('dev'));
      expect(ack.sas, '123456');
      expect(ack.pcId, 'conn-1');
      expect(ack.deviceToken, _token('tok'));
      expect(ack.refreshToken, _token('ref'));
    });
  });

  group('parsePairAck：失败要**说清原因**，且归到 rePair', () {
    test('ok:false 时用电脑侧给的原因（那是给用户看的原话）', () {
      final box = jsonEncode({'ok': false, 'reason': '配对码已过期，请在电脑上重新出码'});
      expect(
        () => parsePairAck(box),
        throwsA(
          isA<ProtocolException>()
              .having((e) => e.code, 'code', ErrorCode.notPaired)
              .having((e) => e.message, 'message', '配对码已过期，请在电脑上重新出码'),
        ),
      );
    });

    test('ok:false 但没有 reason：给一句兜底文案，而不是空消息', () {
      expect(
        () => parsePairAck(jsonEncode({'ok': false})),
        throwsA(
          isA<ProtocolException>().having((e) => e.message, 'message', '配对被拒绝'),
        ),
      );
    });
  });

  group('parsePairAck：**不完整就当失败**（缺字段不许蒙混过关）', () {
    // 每个必填字段各一条：少任何一样都用不了，而拿它继续会在很靠后的地方
    // 变成别的错（空令牌 → 换票 401；空 pcId → 握手 transcript 对不上）。
    for (final missing in const [
      'devId',
      'sas',
      'pcId',
      'deviceToken',
      'refreshToken',
    ]) {
      test('缺 $missing → 拒，且说清楚缺哪个', () {
        final full = <String, Object?>{
          'ok': true,
          'devId': _token('dev'),
          'sas': '123456',
          'pcId': 'conn-1',
          'deviceToken': _token('tok'),
          'refreshToken': _token('ref'),
        }..remove(missing);
        expect(
          () => parsePairAck(jsonEncode(full)),
          throwsA(
            isA<ProtocolException>().having(
              (e) => e.message,
              'message',
              contains(missing),
            ),
          ),
        );
      });
    }

    test('SAS 不是 6 位数字 → 拒，并**点名 SAS**（它是用户照着念的东西）', () {
      final box = jsonEncode({
        'ok': true,
        'devId': _token('dev'),
        'sas': '12345',
        'pcId': 'conn-1',
        'deviceToken': _token('tok'),
        'refreshToken': _token('ref'),
      });
      expect(
        () => parsePairAck(box),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            // 报的是**线上字段名**（小写 `sas`）：拿到这句错误的人要去 grep 的
            // 是回执里的字段，不是我们的驼峰写法。
            contains('sas'),
          ),
        ),
      );
    });

    test('令牌不是 22 字符 → 拒，并**点名那个字段**（不带值：它是凭据）', () {
      // 短令牌拿下去换票必然 401，而那时没人会想到根因在回执。
      final box = jsonEncode({
        'ok': true,
        'devId': _token('dev'),
        'sas': '123456',
        'pcId': 'conn-1',
        'deviceToken': 'tok-1',
        'refreshToken': _token('ref'),
      });
      expect(
        () => parsePairAck(box),
        throwsA(
          isA<ProtocolException>()
              .having((e) => e.code, 'code', ErrorCode.badFrame)
              .having((e) => e.message, 'message', contains('deviceToken'))
              .having((e) => e.message, 'message', isNot(contains('tok-1'))),
        ),
      );
    });

    test('不是合法 JSON / 不是对象 → bad-frame（"这一帧不可接受"）', () {
      expect(
        () => parsePairAck('not json'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
      );
      expect(
        () => parsePairAck('[1,2]'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
      );
    });
  });
}
