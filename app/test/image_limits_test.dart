/// 图片附件的**宿主上限**（`imageLimits` 投影）—— 数从电脑侧来，手机不写死。
///
/// ## 这一组守什么
///
/// 1. 三条前置判据各自说清是哪一条撞了：**超张数 / 超单图 / 超合计**
///    （用假上限喂进去，不碰真实默认值）。
/// 2. **投影缺席（老连接器）⇒ 一次都不拦**：不知道上限就不前置拦，
///    让 DSH 自己拒并把 `IMAGES_TOO_LARGE` / `TOO_MANY_IMAGES` 写在错误里。
/// 3. 认不出投影形状 ⇒ `null`（= 不知道），不是"上限为 0"（那会拦掉一切）。
library;

import 'package:dsh_mobile/model/image_limits.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一份**假上限**（形状照 `attachment/src/types.ts:74-82`；数故意小，好断言）。
const _limits = DshImageLimits(
  maxImageBytes: 1000,
  maxImagesPerMessage: 3,
  maxMessageImageBytes: 2500,
  maxImagePixels: 64000000,
  maxImageDimension: 65535,
  mediaTypes: ['image/png', 'image/jpeg'],
);

void main() {
  group('前置判据（数来自投影，不写死）', () {
    test('超张数：已经 3 张（= 上限）就不能再加', () {
      final message = imageLimitViolationOf(
        limits: _limits,
        images: 3,
        incomingBytes: 10,
        totalBytes: 10,
        mediaType: 'image/png',
      );
      expect(message, contains('最多 3 张'));
    });

    test('超单图：这一张比单图上限大', () {
      final message = imageLimitViolationOf(
        limits: _limits,
        images: 0,
        incomingBytes: 1001,
        totalBytes: 0,
        mediaType: 'image/png',
      );
      expect(message, contains('单图上限'));
      expect(message, contains('1000'), reason: '话里要有上限本身，用户才知道差多少');
    });

    test('超合计：加上这张就超过一条消息的合计上限', () {
      final message = imageLimitViolationOf(
        limits: _limits,
        images: 1,
        incomingBytes: 900,
        totalBytes: 1700, // 1700 + 900 > 2500
        mediaType: 'image/png',
      );
      expect(message, contains('合计'));
    });

    test('放行：都在上限内就没有话', () {
      expect(
        imageLimitViolationOf(
          limits: _limits,
          images: 0,
          incomingBytes: 1000,
          totalBytes: 0,
          mediaType: 'image/png',
        ),
        isNull,
        reason: '等于上限是放行（宿主判据是"大于"）',
      );
    });

    test('类型不收：宿主报的 mediaTypes 之外的类型', () {
      final message = imageLimitViolationOf(
        limits: _limits,
        images: 0,
        incomingBytes: 10,
        totalBytes: 0,
        mediaType: 'image/gif',
      );
      expect(message, contains('image/gif'));
      expect(message, contains('image/png'));
    });
  });

  group('投影缺席 / 认不出', () {
    test('投影缺席（老连接器）⇒ 一律放行，让 DSH 自己拒', () {
      expect(
        imageLimitViolationOf(
          limits: null,
          images: 999,
          incomingBytes: 999999999,
          totalBytes: 999999999,
        ),
        isNull,
        reason: '不知道上限就不前置拦 —— 拒绝码由 DSH 给，我们原样显示',
      );
    });

    test('fromWire：认不出就 null（不是"上限 0"，那会拦掉一切）', () {
      expect(DshImageLimits.fromWire(null), isNull);
      expect(DshImageLimits.fromWire(<String, Object?>{}), isNull);
      // 三个必需项缺一不可：拿一半的限制作判断会给出"这张能发"的错误结论。
      expect(
        DshImageLimits.fromWire(<String, Object?>{
          'maxImageBytes': 1000,
          'maxImagesPerMessage': 3,
        }),
        isNull,
      );
      final parsed = DshImageLimits.fromWire(<String, Object?>{
        'maxImageBytes': 1000,
        'maxImagesPerMessage': 3,
        'maxMessageImageBytes': 2500,
        'mediaTypes': ['image/png', 42],
      });
      expect(parsed, isNotNull);
      expect(parsed!.mediaTypes, ['image/png'], reason: '非字符串项跳过，不编一个类型');
      expect(parsed.maxImagePixels, 0, reason: '没报就是 0 = 不判这一条');
    });
  });
}
