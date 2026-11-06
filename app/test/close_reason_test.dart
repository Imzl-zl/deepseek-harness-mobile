/// 关闭理由的形状（契约 §4.1：`协议码` 或 `协议码 说明`）。
///
/// 判据只有两条，都钉在 `splitCloseReason` 上：
///
/// 1. **码是第一个空格之前的全部字节** —— 切坏了会归成 `internal`，用户看到"未知错误"；
/// 2. 说明部分可以有空格与中文，**只切第一处**。
///
/// 电脑侧目前不产出带说明的理由（`device/busy` 随独占准入一起删掉了），
/// 但形状仍写在契约里、手机侧仍按它解析 —— 所以这里只测形状，不测某个具体的码。
library;

import 'package:dsh_mobile/core/errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('splitCloseReason', () {
    test('不带说明：整串就是码', () {
      final parsed = splitCloseReason('protocol/not-paired');
      expect(parsed.wire, 'protocol/not-paired');
      expect(parsed.detail, isNull);
    });

    test('带说明：码在前、说明在后', () {
      final parsed = splitCloseReason('protocol/revoked 已被移除');
      expect(parsed.wire, 'protocol/revoked');
      expect(parsed.detail, '已被移除');
    });

    test('说明里有空格也不影响切码（只切第一处）', () {
      final parsed = splitCloseReason('protocol/revoked 客厅 那台');
      expect(parsed.wire, 'protocol/revoked');
      expect(parsed.detail, '客厅 那台');
    });

    test('切出来的码能逐字命中封闭表（切坏了会归成 internal）', () {
      expect(
        ErrorCode.fromWire(splitCloseReason('protocol/revoked 已被移除').wire),
        ErrorCode.revoked,
      );
      expect(
        ErrorCode.fromWire(splitCloseReason('handshake-timeout').wire),
        ErrorCode.internal,
        reason: '本地判定名不在表里 —— 这是**如实**的，不是缺陷',
      );
    });
  });
}
