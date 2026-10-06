/// 跨端密码学向量的回归（契约 §4）—— **本段最硬的一批判据**。
///
/// 跑的是 `protocol/vectors/*.json`：机生成的**已知答案**，`node protocol/verify-vectors.mjs`
/// 是参考侧（49 项断言）。Dart 侧必须算出**同样的值** —— 这才是"两端互操作"的证据。
///
/// 为什么它比 fixtures 更硬：`connector/tests/support/phone.ts` 那个手机替身是照契约
/// 重写的**第二份 TS 实现**，它证明"协议两侧自洽"，但**不能替代** Dart 侧跑同一批向量。
/// 曲线、HKDF、AEAD、AAD 规范化这四件事只要有一件两端理解不同，这组测试就该红 ——
/// 而它们在各自的语言里看起来都完全正常。
///
/// 本文件在 `app/test/` 下，**不在** `app/lib/`，所以可以 import `dart:io` 读向量文件
/// （门禁 `verify-platform-boundary.mjs` 只扫 `lib/` 与 `packages/`）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/frame.dart';
import 'package:dsh_mobile/core/handshake.dart';
import 'package:flutter_test/flutter_test.dart';

/// 从本文件位置往上找到仓库根（含 `protocol/` 的那一层）。
///
/// **不硬编码盘符**：仓库从 `C:\sudy` 搬到 `D:\sudy` 时，11 个写死路径的脚本
/// 静默全红过（见 `tools.md` 的 Pitfalls）。
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i += 1) {
    if (Directory('${dir.path}/protocol/vectors').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    '找不到仓库根（含 protocol/vectors 的那一层），当前目录 ${Directory.current.path}',
  );
}

Map<String, Object?> _readVector(String name) {
  final file = File('${_repoRoot().path}/protocol/vectors/$name');
  if (!file.existsSync()) throw StateError('向量文件不存在：${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

void main() {
  final handshake = _readVector('handshake.json');
  final aead = _readVector('aead.json');

  group('握手派生（§4.1）', () {
    test('三份共享密钥 + master + kA2B/kB2A 与向量逐字节一致', () async {
      final input = handshake['input']! as Map<String, Object?>;
      final expected = handshake['expected']! as Map<String, Object?>;

      // 向量的 `input` 给的是**种子**，不是密钥对象 —— 两侧各自从种子建密钥对。
      final staticA = await x25519FromSeed(input['seedA']! as String);
      final staticB = await x25519FromSeed(input['seedB']! as String);
      final ephA = await x25519FromSeed(input['ephSeedA']! as String);
      final ephB = await x25519FromSeed(input['ephSeedB']! as String);

      // 先确认公钥派生本身对得上（这一步错了，后面的共享密钥一定错）。
      expect(staticA.publicKeyHex, expected['pubA'], reason: 'pubA');
      expect(staticB.publicKeyHex, expected['pubB'], reason: 'pubB');
      expect(ephA.publicKeyHex, expected['ephPubA'], reason: 'ephPubA');
      expect(ephB.publicKeyHex, expected['ephPubB'], reason: 'ephPubB');

      // **双侧派生**：这是本组最重要的一条。
      // 手机是发起方（initiator），电脑是应答方（responder）；两侧材料不同
      // （各自的私钥 + 对方的公钥），但算出来必须是同一把。
      // 只验单侧输入输出的测试在这里是**无效证据** —— 顺序反了两侧各算一把，
      // 握手看起来走完、AEAD 永远解不开（本项目真的踩过，见 tools.md 的 Pitfalls）。
      final asInitiator = await deriveSessionKeys(
        role: HandshakeRole.initiator,
        ownStaticPrivate: staticA.keyPair,
        ownEphemeralPrivate: ephA.keyPair,
        peerStaticPublicHex: staticB.publicKeyHex,
        peerEphemeralPublicHex: ephB.publicKeyHex,
        nonceA: input['nonceA']! as String,
        nonceB: input['nonceB']! as String,
        info: input['info']! as String,
        pairingId: input['pairingId']! as String,
      );
      final asResponder = await deriveSessionKeys(
        role: HandshakeRole.responder,
        ownStaticPrivate: staticB.keyPair,
        ownEphemeralPrivate: ephB.keyPair,
        peerStaticPublicHex: staticA.publicKeyHex,
        peerEphemeralPublicHex: ephA.publicKeyHex,
        nonceA: input['nonceA']! as String,
        nonceB: input['nonceB']! as String,
        info: input['info']! as String,
        pairingId: input['pairingId']! as String,
      );

      expect(asInitiator.master, asResponder.master, reason: '两侧必须派生出同一把主密钥');
      expect(asInitiator.kA2B, asResponder.kA2B, reason: 'kA2B 是方向约定，与角色无关');
      expect(asInitiator.kB2A, asResponder.kB2A, reason: 'kB2A 同上');

      for (final key in const ['ss1', 'ss2', 'ss3', 'master', 'kA2B', 'kB2A']) {
        expect(asInitiator.toMap()[key], expected[key], reason: '$key（发起方视角）');
        // **两侧都必须等于向量值**：`ss1`/`ss2` 是**角色调整后**的绝对协议值
        // （`ss1` = 发起方临时 × 应答方静态），不是"自己的临时 × 对端的静态"。
        // 把位置当编号的实现在这里红 —— 而它派生的主密钥仍然是对的，
        // 所以只有这条"双侧比对"能抓住它（见 tools.md 的 Pitfalls）。
        expect(
          asResponder.toMap()[key],
          expected[key],
          reason: '$key（应答方视角，必须与发起方算出同一个绝对协议值）',
        );
      }
    });

    test('三个共享密钥互不相同（ss3 是前向保密的来源）', () async {
      final input = handshake['input']! as Map<String, Object?>;
      final keys = await deriveSessionKeys(
        role: HandshakeRole.initiator,
        ownStaticPrivate: (await x25519FromSeed(
          input['seedA']! as String,
        )).keyPair,
        ownEphemeralPrivate: (await x25519FromSeed(
          input['ephSeedA']! as String,
        )).keyPair,
        peerStaticPublicHex: (await x25519FromSeed(
          input['seedB']! as String,
        )).publicKeyHex,
        peerEphemeralPublicHex: (await x25519FromSeed(
          input['ephSeedB']! as String,
        )).publicKeyHex,
        nonceA: input['nonceA']! as String,
        nonceB: input['nonceB']! as String,
        info: input['info']! as String,
        pairingId: input['pairingId']! as String,
      );
      expect(keys.ss1 == keys.ss2, isFalse, reason: 'ss1 与 ss2 相同说明角色顺序写错了');
      expect(keys.ss2 == keys.ss3, isFalse);
      expect(
        keys.master.substring(0, 64),
        keys.kA2B,
        reason: 'master 前 32 字节必须是 kA2B',
      );
      expect(
        keys.master.substring(64),
        keys.kB2A,
        reason: 'master 后 32 字节必须是 kB2A',
      );
    });
  });

  group('设备身份（§4.1）', () {
    test('主种子 → 两把长期密钥，且两把来自不同的 info', () async {
      final identity = handshake['identity']! as Map<String, Object?>;
      final expected = identity['expected']! as Map<String, Object?>;

      final derived = await deriveIdentity(identity['masterSeed']! as String);
      expect(derived.edSeedForTest, expected['edSeed'], reason: 'edSeed');
      expect(derived.dhSeedHex, expected['dhSeed'], reason: 'dhSeed');
      expect(derived.sign.publicKeyHex, expected['edPub'], reason: 'edPub');
      expect(derived.dh.publicKeyHex, expected['dhPub'], reason: 'dhPub');
      expect(
        derived.signSeedHex == derived.dhSeedHex,
        isFalse,
        reason: '两把长期密钥必须来自不同的 info（否则签名密钥与 DH 密钥是同一把）',
      );
    });
  });

  group('transcript 拼串与签名（§4.1）', () {
    test('从字段重拼的串与向量一致，重签的签名也一致', () async {
      final signature = handshake['signature']! as Map<String, Object?>;
      final fields = signature['fields']! as Map<String, Object?>;

      final rebuilt = transcriptFromFields(fields);
      expect(
        utf8.decode(rebuilt),
        signature['transcript'],
        reason: '顺序是协议的一部分：换顺序不会报错，只会让两侧算出不同的 transcript',
      );

      final sig = await signTranscript(
        signature['signerEdSeed']! as String,
        rebuilt,
      );
      expect(sig, signature['sig'], reason: 'Ed25519 是确定性签名，重签必须得到同一个值');
    });
  });

  group('AEAD 与箱容器（§3、§4.2）', () {
    test('每条向量的密文 / 标签 / 容器 / 往返都对得上', () async {
      final vectors = aead['vectors']! as List<Object?>;
      expect(vectors, isNotEmpty, reason: '向量文件里一条都没有，说明读错了文件');

      for (final entry in vectors) {
        final v = entry! as Map<String, Object?>;
        final name = v['name']! as String;
        final fc = (v['fc']! as num).toInt();
        final aadFields = AadFields.fromJson(v['aad']! as Map<String, Object?>);

        final sealed = await seal(
          keyHex: v['key']! as String,
          fc: fc,
          aadFields: aadFields,
          plaintext: v['plaintext']! as String,
        );
        expect(sealed.ciphertextHex, v['ciphertext'], reason: '$name: 密文');
        expect(sealed.tagHex, v['tag'], reason: '$name: 认证标签');
        // 容器也是线上格式的一部分：两端各拼一遍再比对，
        // 避免"各写各的、真机才断"（一个用十六进制、一个带分隔符，单侧测试都是绿的）。
        expect(packBox(sealed), v['box'], reason: '$name: 箱容器');

        final unpacked = unpackBox(v['box']! as String);
        expect(
          unpacked.ciphertextHex,
          v['ciphertext'],
          reason: '$name: 容器往返（密文）',
        );
        expect(unpacked.tagHex, v['tag'], reason: '$name: 容器往返（标签）');

        final back = await open(
          keyHex: v['key']! as String,
          fc: fc,
          aadFields: aadFields,
          ciphertextHex: v['ciphertext']! as String,
          tagHex: v['tag']! as String,
        );
        expect(back, v['plaintext'], reason: '$name: 解密往返');
      }
    });

    test('篡改用例必须解密失败（改 AAD 任一字段 / 改 fc）', () async {
      final vectors = aead['vectors']! as List<Object?>;
      final tamper = aead['tamper']! as List<Object?>;
      expect(tamper, isNotEmpty);

      for (final entry in tamper) {
        final t = entry! as Map<String, Object?>;
        final name = t['name']! as String;
        final v =
            vectors[(t['vectorIndex']! as num).toInt()]!
                as Map<String, Object?>;
        final baseAad = Map<String, Object?>.from(
          v['aad']! as Map<String, Object?>,
        );
        final patch = t['patch'] as Map<String, Object?>?;
        if (patch != null) baseAad.addAll(patch);
        final fc = t['fc'] == null
            ? (v['fc']! as num).toInt()
            : (t['fc']! as num).toInt();

        await expectLater(
          open(
            keyHex: v['key']! as String,
            fc: fc,
            aadFields: AadFields.fromJson(baseAad),
            ciphertextHex: v['ciphertext']! as String,
            tagHex: v['tag']! as String,
          ),
          throwsA(
            isA<ProtocolException>().having(
              (e) => e.code,
              'code',
              'protocol/bad-frame',
            ),
          ),
          reason: '$name 必须解密失败（认证失败要转成协议错误码，不能让包的裸异常漏出去）',
        );
      }
    });

    test('nonce = fc 的 96 位大端，不是随机数', () {
      expect(toHex(nonceOf(0)), '000000000000000000000000');
      expect(toHex(nonceOf(1)), '000000000000000000000001');
      expect(toHex(nonceOf(256)), '000000000000000000000100');
      // 已用 Node 的 `writeBigUInt64BE(0xffffffffn, 4)` 核对过真值。
      expect(toHex(nonceOf(0xffffffff)), '0000000000000000ffffffff');
      // 同一个 fc 必须得到同一个 nonce（否则重放守卫与 AEAD 都会失效）。
      expect(toHex(nonceOf(42)), toHex(nonceOf(42)));
    });

    test('重放守卫：先验后进，同一个 fc 不许两次', () {
      final guard = ReplayGuard();
      guard.accept(0);
      guard.accept(1);
      expect(guard.maxFc, 1);
      // 同一帧重放。
      expect(
        () => guard.accept(1),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            'protocol/replay',
          ),
        ),
      );
      // 更旧的帧。
      expect(
        () => guard.accept(0),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            'protocol/replay',
          ),
        ),
      );
      // 跳跃是允许的（乱序由上层判，这一层只管单调）。
      guard.accept(10);
      expect(guard.maxFc, 10);
    });
  });

  group('AAD 规范化（§3）', () {
    test('缺字段用空串占位，两种写法等价', () {
      final omitted = aadOf(
        const AadFields(t: 'ev', sid: 'sid_1', seq: 1, fc: 0),
      );
      final explicit = aadOf(
        const AadFields(t: 'ev', id: '', sid: 'sid_1', seq: 1, fc: 0),
      );
      expect(toHex(omitted), toHex(explicit), reason: '「缺」与「空串」必须规范化成同一个串');
      expect(utf8.decode(omitted), '1|ev||sid_1|1|0');
    });

    test('数字是十进制无前导零、无小数点', () {
      expect(
        utf8.decode(aadOf(const AadFields(t: 'ev', seq: 0, fc: 0))),
        '1|ev|||0|0',
      );
      expect(
        utf8.decode(aadOf(const AadFields(t: 'ev', seq: 12345, fc: 7))),
        '1|ev|||12345|7',
      );
    });
  });

  group('行级分帧（§3）', () {
    test('encodeFrame 必须带换行 —— 漏了的表现是"对端什么都没收到"', () {
      final encoded = encodeFrame(<String, Object?>{
        'v': 1,
        't': 'ping',
        'fc': 0,
        'box': '',
      });
      expect(encoded.endsWith('\n'), isTrue, reason: '分隔符由编解码层负责，不是调用方');
      expect(encoded, '{"v":1,"t":"ping","fc":0,"box":""}\n');
    });

    test('分帧器：半行留着，收到换行才交出一帧', () {
      final splitter = LineSplitter();
      expect(splitter('{"v":1'), isEmpty, reason: '半行不能交出去');
      final frames = splitter(',"t":"ping","fc":0,"box":""}\n');
      expect(frames.length, 1);
      expect(jsonDecode(frames.first), isA<Map<String, Object?>>());
    });

    test('分帧器：一次喂多帧，按行切开', () {
      final splitter = LineSplitter();
      final frames = splitter('{"a":1}\n{"b":2}\n{"c":3}\n');
      expect(frames.length, 3);
      expect(frames.map((f) => jsonDecode(f)).toList(), [
        {'a': 1},
        {'b': 2},
        {'c': 3},
      ]);
    });

    test('解码：未知类型无 id 忽略；有 id 要回错（沉默会让对端永远挂着）', () {
      expect(decodeFrame('{"v":1,"t":"future-thing"}'), isA<IgnoredFrame>());
      final unsupported = decodeFrame('{"v":1,"t":"future-thing","id":"r1"}');
      expect(unsupported, isA<UnsupportedFrame>());
      expect((unsupported as UnsupportedFrame).id, 'r1');
    });

    test('解码：版本不符 / 非法 JSON / id 字符集不合法都要抛', () {
      expect(
        () => decodeFrame('{"v":2,"t":"ping"}'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            'protocol/unsupported-version',
          ),
        ),
      );
      expect(
        () => decodeFrame('not json'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            'protocol/bad-frame',
          ),
        ),
      );
      // `id` 是 AAD 的组成部分：放进去一个需要转义的字符，两端 AAD 就可能不同。
      expect(
        () => decodeFrame('{"v":1,"t":"req","id":"a+b/c=","fc":0,"box":""}'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            'protocol/bad-frame',
          ),
        ),
      );
    });

    test('base64url 无填充：与电脑侧的 Buffer.toString("base64url") 一致', () {
      // 真值来自 `node -e "Buffer.from([251,255]).toString('base64url')"` ——
      // 注意 `[251,255]` 在 base64url 里是 `-_8`（标准 base64 会是 `+/8`）：
      // 这正是"两端各写各的字母表"会静默出错的地方。
      expect(base64UrlNoPad([251, 255]), '-_8');
      expect(base64UrlNoPad([1]), 'AQ');
      expect(base64UrlNoPad([1, 2]), 'AQI');
      expect(base64UrlToBytes('-_8'), [251, 255]);
      expect(base64UrlToBytes('AQ'), [1]);
      // 带填充的也要能解（宽容在这里没有安全代价）。
      expect(base64UrlToBytes('AQ=='), [1]);
    });
  });
}

/// 测试用的便捷视图：把 [SessionKeys] 转成与向量同名的 map。
extension on SessionKeys {
  Map<String, String> toMap() => {
    'ss1': ss1,
    'ss2': ss2,
    'ss3': ss3,
    'master': master,
    'kA2B': kA2B,
    'kB2A': kB2A,
  };
}

/// [IdentityKeys] 的 Ed25519 种子（产品代码里叫 `signSeedHex`，向量里叫 `edSeed`）。
extension on IdentityKeys {
  String get edSeedForTest => signSeedHex;
}
