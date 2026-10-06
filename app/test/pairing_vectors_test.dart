/// 配对派生规则的**跨端向量**（契约 §12.1）。
///
/// ## 这份向量的期望值从哪来
///
/// 由 `app/tools/gen-pairing-vectors.mjs` **调用真实的 `connector/src/pairing.ts`**
/// 生成（不是我在 Dart 里重写一遍再对拍 —— 那只能证明"我两次写的一样"）。
/// 它管的是配对；握手与 AEAD 由 `protocol/verify-vectors.mjs` 管。
///
/// ## 为什么这四条断言值得单独一个文件
///
/// `pairingId` 与 SAS 错了**不会报错**：
/// - `pairingId` 错 → 两端 `master` 不同 → 箱解不开 → 症状是"配上了但永远连不上"，
///   而排查会从网络开始找；
/// - SAS 错 → 用户在两端看到不同的 6 位数字，于是合理地怀疑"配错设备了"。
///
/// 两者都是"算错了却不报错"的那一类，所以只有跨端对拍能守住。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/core/pairing.dart';
import 'package:dsh_mobile/platform/pairing_store.dart';
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

  test('codeHash / pairingId / SAS 与电脑侧逐字一致（全部向量）', () async {
    for (final raw in fixture['vectors']! as List) {
      final v = raw as Map<String, Object?>;
      final name = v['name'] as String;
      final code = v['code'] as String;

      // 1) 码的哈希。**落盘与上报用的都是它，不是码本身**（§12.1）。
      expect(
        await sha256Hex(code),
        v['codeHash'],
        reason: '[$name] codeHash 不一致',
      );

      // 2) pairingId：ikm 是**哈希的 UTF-8 字节**（十六进制字符串），不是码。
      //    这一处最容易写错，而写错时两端各自自洽、只在互连时暴露。
      final offer = PairingOffer(
        relayUrl: 'wss://relay.invalid/ws',
        pcSignPubHex: v['pcPubEd']! as String,
        pcDhPubHex: v['pcPubEd']! as String,
        code: code,
      );
      expect(
        await offer.pairingId(),
        v['pairingId'],
        reason: '[$name] pairingId 不一致 —— 两端 master 会不同，表现为"配上了但连不上"',
      );

      // 3) SAS：用户在两端对照的 6 位数字（含补零）。
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
        await deriveDeviceId(v['devPubDh']! as String),
        v['deviceId'],
        reason: '[$name] deviceId 不一致 —— 电脑侧会认不出这台设备',
      );
    }
  });

  test('配对请求带的是 codeHash 而不是码本身（请求要经中转）', () async {
    final v = (fixture['vectors']! as List).first as Map<String, Object?>;
    final offer = PairingOffer(
      relayUrl: 'wss://relay.invalid/ws',
      pcSignPubHex: v['pcPubEd']! as String,
      pcDhPubHex: v['pcPubEd']! as String,
      code: v['code']! as String,
    );
    final request = await offer.requestPayload(
      devPubEdHex: 'ab' * 32,
      devPubDhHex: 'cd' * 32,
      deviceName: '我的手机',
    );

    expect(request['codeHash'], v['codeHash']);
    expect(
      request.containsKey('code'),
      isFalse,
      reason: '配对码本身绝不能进请求 —— 它经中转，泄漏即被抢配',
    );
    expect(request['devPubEd'], 'ab' * 32);
    expect(request['name'], '我的手机');
  });

  group('二维码解析（外部输入，拒绝要带原因）', () {
    final good = jsonEncode({
      'v': 1,
      'relay': 'wss://relay.example/ws/connector',
      'pcPubEd': 'aa' * 32,
      'pcPubDh': 'bb' * 32,
      'code': 'the-code',
    });

    test('正常解析', () {
      final offer = PairingOffer.fromQrPayload(good);
      expect(offer.relayUrl, 'wss://relay.example/ws/connector');
      expect(offer.pcSignPubHex, 'aa' * 32);
      expect(offer.code, 'the-code');
    });

    test('版本不符 → unsupported-version（动作是升级，不是重扫）', () {
      final bad = jsonEncode({
        'v': 2,
        'relay': 'wss://r/ws',
        'pcPubEd': 'aa',
        'pcPubDh': 'bb',
        'code': 'c',
      });
      expect(
        () => PairingOffer.fromQrPayload(bad),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('protocol/unsupported-version'),
          ),
        ),
      );
    });

    test('缺字段 / 非 JSON / 公钥非十六进制 → 都能带原因拒掉', () {
      // 二维码是"信任的起点"，坏字段必须在**这里**就暴露 ——
      // 否则症状出现在很远的地方（握手失败 / 箱解不开），没人会想到是二维码。
      expect(
        () => PairingOffer.fromQrPayload('not json'),
        throwsA(isA<Exception>()),
      );
      expect(
        () => PairingOffer.fromQrPayload(jsonEncode({'v': 1})),
        throwsA(isA<Exception>()),
      );
      expect(
        () => PairingOffer.fromQrPayload(
          jsonEncode({
            'v': 1,
            'relay': 'wss://r/ws',
            'pcPubEd': 'ZZZZ', // 非十六进制
            'pcPubDh': 'bb',
            'code': 'c',
          }),
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}
