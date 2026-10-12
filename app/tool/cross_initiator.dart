/// 跨实现一致性探针（**只用产品的 Dart 实现**）。
///
/// ## 它为什么存在
///
/// 手机是 Dart、电脑侧是 TS，两边各自实现了同一套握手 / 封箱。此前**没有一条测试
/// 让两边真的对上**：手机的用例对着一个 Dart 写的电脑替身跑，电脑侧的用例对着一个
/// TS 写的手机替身跑 —— 两边各自自洽，门禁全绿，可一旦 transcript 拼串顺序、AAD
/// 规范化或箱容器有偏差，症状是"验签失败 / 箱解不开"，而错误信息会说"公钥被替换"。
/// 真因在一处拼串上，报出来的却像中间人攻击，且**单测抓不到**（各自自洽）。
///
/// 本文件是这条证据的 Dart 那一半：走真实握手三帧、派生真实密钥、封一个真实业务帧、
/// 解开电脑侧封回来的那一帧，最后把**双方派生的密钥**与**解开的明文**打印出来。
/// 电脑侧那一半在 `connector/tests/cross-language-handshake.test.ts`，用的同样是
/// 产品的 TS 实现（`createHandshakeDriver` + `createBoxCodec`）。
///
/// ## 交互协议（stdio，一行一帧）
///
/// ```text
/// Dart → stdout: hello 帧
/// Node → stdin : hello-ack 帧        Dart → stdout: confirm 帧
/// Dart → stdout: req 帧(本机封的)
/// Node → stdin : res 帧(电脑侧封的)  Dart → stdout: 一行 JSON 摘要
/// ```
///
/// 跑法（由 Node 测试负责启动，一般不手工跑）：`dart run tool/cross_initiator.dart`
library;

/// `directives_ordering` 按**字母序**排 `dart:` 段(不看前缀),所以 `convert` 在 `io` 前。
/// `core/frame.dart` 也导出一个 `LineSplitter`(按字节片切行的那个),而这里要的是
/// `dart:convert` 的**流式** LineSplitter —— 两个都有用,不加前缀会冲突。
import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io';

import 'package:dsh_mobile/core/box.dart';
import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/frame.dart';
import 'package:dsh_mobile/core/handshake_driver.dart';

/// 固定种子：两边必须用同一套，否则比对没有意义。
///
/// Dart 没有字符串重复运算符（`'a1' * 32` 不是表达式），所以用 [._rep] 拼；
/// Node 那边写 `'a1'.repeat(32)`。**两边必须逐字相同**——改一侧另一边会立刻红。
String _rep(String unit, int times) => List<String>.filled(times, unit).join();

const String _masterSeed =
    '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20';
const String _pairingId = 'cHJhY3RpY2UtaWQtcHJhY3RpY2UtaWQtcHJhY3RpY2U';
const String _devId = 'tsJs6UgOJFdyfpazdZSQpQ';

/// 电脑侧种子（Node 侧写 `'a1'.repeat(32)`）。
final String _pcSeed = _rep('a1', 32);

/// 手机临时 DH 种子与 `nonceA`（每连接换一个；这里固定住以便两边复算）。
final String _ephemeralSeed = _rep('e5', 32);
final String _nonceA = _rep('a7', 32);

Future<void> main() async {
  final identity = await deriveIdentity(_masterSeed);
  final pc = await deriveIdentity(_pcSeed);

  final established = Completer<SessionKeys>();
  final failure = Completer<String>();
  final opened = Completer<String>();

  final session =
      createHandshakeDriver(
        identity: HandshakeIdentity(
          staticKeys: identity.dh,
          signSeedHex: identity.signSeedHex,
          devId: _devId,
        ),
        peer: PeerIdentity(
          pcSignPubHex: pc.sign.publicKeyHex,
          pcDhPubHex: pc.dh.publicKeyHex,
          pcId: 'conn-1',
          pairingId: _pairingId,
        ),
        newEphemeralSeedHex: () => _ephemeralSeed,
        newNonceHex: () => _nonceA,
        newFrameIdHex: () => 'id-1',
      )(
        HandshakeContext(
          send: (frame) => stdout.writeln(encodeFrame(frame)),
          established: (result) {
            if (!established.isCompleted) established.complete(result.keys);
          },
          failed: (code, error) {
            if (!failure.isCompleted) failure.complete('$code: $error');
          },
          schedule: (fn, ms) {
            final timer = Timer(Duration(milliseconds: ms), fn);
            return timer.cancel;
          },
        ),
      );

  // 一行一帧地喂给它：hello-ack 走驱动器；握手一完成就封一个业务帧发出去
  // （**必须在等 res 之前发**，否则两边互等 → 死锁）；res 用派生出的箱解开。
  await for (final line
      in stdin
          .transform(convert.utf8.decoder)
          .transform(const convert.LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final decoded = decodeFrame(line);
    if (decoded is! DecodedFrame) continue;
    final frame = decoded.frame;
    if (frame['t'] == 'hello-ack') {
      session.onFrame(frame);
      // 等驱动器把密钥派生完（验签与派生都是异步的）。
      final keys = await established.future;
      final outbound = BoxCodec(keys: keys, role: HandshakeRole.initiator);
      final header = <String, Object?>{
        'v': wireVersion,
        't': 'req',
        'id': 'id-1',
        // `fc` 从 0 起:证明"分配 fc 与封箱挨得够近"这件事在 Dart 侧也成立。
        'fc': 0,
      };
      final box = await outbound.sealFrame(
        header,
        convert.jsonEncode({'method': 'repo.info'}),
      );
      stdout.writeln(encodeFrame(<String, Object?>{...header, 'box': box}));
      continue;
    }
    if (frame['t'] == 'res') {
      final keys = await established.future;
      opened.complete(
        await BoxCodec(
          keys: keys,
          role: HandshakeRole.initiator,
        ).openFrame(frame, '${frame['box']}'),
      );
      break;
    }
  }

  // 摘要只打印**派生结果**与**解开的明文**：这几样相等就证明 transcript 拼串、
  // HKDF 输入、AAD 规范化与箱容器四件事在两边逐字节一致。
  final keys = await established.future;
  stdout.writeln(
    convert.jsonEncode({
      'master': keys.master,
      'kA2B': keys.kA2B,
      'kB2A': keys.kB2A,
      'opened': await opened.future,
    }),
  );
  if (failure.isCompleted) {
    // **失败也要留下证据**:对端(测试)只能看到 stdout,而"我这侧为什么拒"是定位
    // 分歧的唯一线索 —— 尤其是两边各自实现同一套协议时。
    stderr.writeln('Dart 侧握手失败：${await failure.future}');
    exitCode = 1;
  }
}
