/// 配对派生规则的**跨端向量**（规格 `docs/subsystems/pairing-v2.md` §4–§5）。
///
/// ## 这份向量的期望值从哪来
///
/// 由 `app/tools/gen-pairing-vectors.mjs` **调用真实的 `connector/src/pairing.ts`**
/// 生成（不是我在 Dart 里重写一遍再对拍 —— 那只能证明"我两次写的一样"）。
/// 它管的是配对；握手与 AEAD 由 `protocol/verify-vectors.mjs` 管。
///
/// ## 为什么这几条断言值得单独一个文件
///
/// 它们全是"算错了也不报错"的那一类：
/// - `pairingId` 错 → 两端 `master` 不同 → 箱解不开 → 症状是"配上了但永远连不上"，
///   而排查会从网络开始找；
/// - 配对握手上下文拼错 → 进的是被签的字节，症状是**验签失败**（报告会说"公钥被替换"）；
/// - 设备标识错 → 电脑侧把这台手机当成没见过的设备（同样是"配对成功但连不上"）。
///
/// 所以只有跨端对拍能守住它们。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/pairing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Map<String, Object?> fixture;

  setUpAll(() {
    final file = File('test/fixtures/pairing-vectors.json');
    if (!file.existsSync()) {
      fail(
        '缺少配对向量：先跑 `node app/tools/gen-pairing-vectors.mjs`'
        '（它调用真实的 connector 实现，不是手写的期望值）',
      );
    }
    fixture = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  });

  test('向量文件来自真实实现，不是手写', () {
    // 守住"期望值必须由电脑侧产出"这件事本身：手抄的期望值会漂移，
    // 而它一旦漂移，两边就都在对着一个错的答案自洽。
    expect(
      fixture['generatedBy'],
      contains('connector/src/pairing.ts'),
      reason: '期望值必须由电脑侧真实实现产出',
    );
    expect((fixture['vectors']! as List).length, greaterThanOrEqualTo(4));
  });

  test('codeHash / pairingId / SAS / 设备标识 / 握手上下文与电脑侧逐字一致（全部向量）', () async {
    for (final raw in fixture['vectors']! as List) {
      final v = raw as Map<String, Object?>;
      final name = v['name'] as String;
      final code = v['code'] as String;

      // 1) 码的哈希。电脑侧用它校验秘密，**它不上中转**（§3）。
      expect(
        await sha256Hex(code),
        v['codeHash'],
        reason: '[$name] codeHash 不一致',
      );

      // 2) pairingId：ikm 是**哈希的 UTF-8 字节**（十六进制字符串），不是码。
      //    这一处最容易写错，而写错时两端各自自洽、只在互连时暴露。
      final offer = PairingOffer(
        relayUrl: 'wss://relay.invalid/ws',
        pcId: v['pcId']! as String,
        pcSignPubHex: v['pcPubEd']! as String,
        pcDhPubHex: v['pcPubDh']! as String,
        offerId: v['offerId']! as String,
        code: code,
      );
      expect(
        await offer.pairingId(),
        v['pairingId'],
        reason: '[$name] pairingId 不一致 —— 两端 master 会不同，表现为"配上了但连不上"',
      );

      // 3) SAS：两端各算一遍的辅助指纹（含补零）。
      expect(
        await sasOf(
          pcSignPubHex: v['pcPubEd']! as String,
          devSignPubHex: v['devPubEd']! as String,
        ),
        v['sas'],
        reason: '[$name] SAS 不一致 —— 两端会显示不同的数字',
      );

      // 4) 设备标识：**手机侧本地推导**同一个值（握手的 `hello` 要带它，
      //    而那时还没收到任何回执）。不一致的后果是"配对成功了但连不上" ——
      //    电脑侧会把这台手机当成一台没见过的设备。
      expect(
        await pairingDeviceId(v['devPubDh']! as String),
        v['deviceId'],
        reason: '[$name] 设备标识不一致 —— 电脑侧会认不出这台设备',
      );

      // 5) 配对握手上下文：它进被签的字节（§4）。两端拼得不一样的表现是**验签失败**，
      //    而错误信息会说"公钥被替换"—— 也就是真因在一处拼串上，报出来的却像中间人攻击。
      final candidate = PairingCandidate(
        offerId: v['offerId']! as String,
        devPubEdHex: v['devPubEd']! as String,
        devPubDhHex: v['devPubDh']! as String,
        name: v['deviceName']! as String,
      );
      expect(
        await candidate.handshakeContext(offer),
        v['handshakeContext'],
        reason: '[$name] 配对握手上下文不一致 —— 握手会报"公钥被替换"',
      );
    }
  });

  test('换票请求带的是候选身份（公开邀请 + 公钥 + 设备名），**不带码**', () async {
    final v = (fixture['vectors']! as List).first as Map<String, Object?>;
    final candidate = PairingCandidate(
      offerId: v['offerId']! as String,
      devPubEdHex: v['devPubEd']! as String,
      devPubDhHex: v['devPubDh']! as String,
      name: v['deviceName']! as String,
    );
    final wire = candidate.toWire();

    expect(wire['v'], 2);
    expect(wire['offerId'], v['offerId']);
    expect(wire['devPubEd'], v['devPubEd']);
    expect(wire['devPubDh'], v['devPubDh']);
    expect(wire['name'], v['deviceName']);
    // 码**绝不进请求**：首配那一跳经中转，而秘密是唯一的授权凭据（§1）。
    // v2 里它更进一步 —— 连码的哈希都不再登记到中转。
    expect(wire.containsKey('code'), isFalse);
    expect(jsonEncode(wire).contains(v['code']! as String), isFalse);
  });

  group('二维码解析（外部输入，拒绝要带原因）', () {
    final good = jsonEncode({
      'v': 2,
      'relay': 'wss://relay.example/ws/connector',
      'pcId': 'conn-1',
      'pcPubEd': 'aa' * 32,
      'pcPubDh': 'bb' * 32,
      'offerId': 'abL3sSH5gLJpTBBsqPUzJg',
      'code': 'zyXWvUTSrqPONMLKjihgfe',
    });

    test('正常解析', () {
      final offer = PairingOffer.fromQrPayload(good);
      expect(offer.relayUrl, 'wss://relay.example/ws/connector');
      expect(offer.pcId, 'conn-1');
      expect(offer.pcSignPubHex, 'aa' * 32);
      expect(offer.offerId, 'abL3sSH5gLJpTBBsqPUzJg');
      expect(offer.code, 'zyXWvUTSrqPONMLKjihgfe');
    });

    test('旧版（v1）二维码 → unsupported-version（动作是升级，不是重扫）', () {
      // v1 的码里没有 `offerId`：v2 的电脑侧会直接拒（换票 426）。
      // 报成"二维码坏"会让人反复重扫同一张 —— 而该做的事是去电脑上升级。
      final legacy = jsonEncode({
        'v': 1,
        'relay': 'wss://relay.example/ws/connector',
        'pcPubEd': 'aa' * 32,
        'pcPubDh': 'bb' * 32,
        'code': 'zyXWvUTSrqPONMLKjihgfe',
      });
      expect(
        () => PairingOffer.fromQrPayload(legacy),
        throwsA(
          isA<ProtocolException>()
              .having((e) => e.code, 'code', ErrorCode.unsupportedVersion)
              .having((e) => e.message, 'message', contains('重新生成 v2 配对码')),
        ),
      );
    });

    test('缺字段 / 非 JSON / 公钥非十六进制 / 邀请与秘密相同 → 都能带原因拒掉', () {
      // 二维码是"信任的起点"，坏字段必须在**这里**就暴露 ——
      // 否则症状出现在很远的地方（握手失败 / 箱解不开），没人会想到是二维码。
      expect(
        () => PairingOffer.fromQrPayload('not json'),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => PairingOffer.fromQrPayload(jsonEncode({'v': 2})),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => PairingOffer.fromQrPayload(
          jsonEncode({
            'v': 2,
            'relay': 'wss://r/ws',
            'pcId': 'c',
            'pcPubEd': 'ZZZZ', // 非十六进制
            'pcPubDh': 'bb',
            'offerId': 'abL3sSH5gLJpTBBsqPUzJg',
            'code': 'zyXWvUTSrqPONMLKjihgfe',
          }),
        ),
        throwsA(isA<ProtocolException>()),
      );
      // 邀请与秘密必须是**两个独立随机数**：相同就等于把公开标识当成了凭据。
      final same = jsonEncode({
        'v': 2,
        'relay': 'wss://r/ws',
        'pcId': 'c',
        'pcPubEd': 'aa' * 32,
        'pcPubDh': 'bb' * 32,
        'offerId': 'abL3sSH5gLJpTBBsqPUzJg',
        'code': 'abL3sSH5gLJpTBBsqPUzJg',
      });
      expect(
        () => PairingOffer.fromQrPayload(same),
        throwsA(isA<ProtocolException>()),
      );
    });
  });
}
