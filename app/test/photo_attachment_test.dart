/// 图片附件这条链的回归（选图通道 → part 形状 → 发送载荷）。
///
/// ## 这一组守什么
///
/// 用户 2026-10-19：「比人家的上传点击弹框有拍照，图片，上传文件啥的」。
///
/// 2026-10-20 之前这条链是**假的**：`＋` 的「附件」加一枚只有名字的芯片
/// （`PendingAttachment('新增文件.txt')`），而 `_send()` 的 `content` 只有
/// 文本块 —— **附件被静默丢弃**。现在图片这条是真的：
/// 系统照片选择器 → 字节 → `{type:'image', mediaType, data}` → 随 prompt 发出。
///
/// ## 形状的唯一出处
///
/// `packages/api/session-controller/src/types.ts:90-98`：
/// ```ts
/// | { readonly type: 'image'; readonly mediaType: ImageMediaType
///     readonly data: string; readonly name?: string }
/// ```
/// `ImageMediaType` = png / jpeg / webp / gif
/// （`packages/attachment/attachment/src/types.ts:8`）。
library;

import 'package:dsh_mobile/platform/photo_picker.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一份"原生回的那一包"（与 `MainActivity.kt` 里 `payload` 的键逐字一致）。
Map<String, Object?> _nativeReply({
  String mediaType = 'image/png',
  String data = 'iVBORw0KGgo=',
  String name = '设计稿.png',
  int byteCount = 8,
}) => {
  'mediaType': mediaType,
  'data': data,
  'name': name,
  'byteCount': byteCount,
};

void main() {
  group('parsePhotoPickReply：四种结果分开（别混成"没反应"）', () {
    test('正常一张：字段逐个搬过来', () {
      final result = parsePhotoPickReply(_nativeReply());
      expect(result, isA<PhotoPicked>());
      final picked = result as PhotoPicked;
      expect(picked.mediaType, 'image/png');
      expect(picked.data, 'iVBORw0KGgo=');
      expect(picked.name, '设计稿.png');
      expect(picked.byteCount, 8);
    });

    test('null = 用户取消（不是错误）', () {
      expect(parsePhotoPickReply(null), isA<PhotoPickCancelled>());
    });

    test('DSH 不认的类型：明确报出来，不静默发过去', () {
      // heic 很常见，但 `ImageMediaType` 里没有它
      // （`attachment/src/types.ts:8`：只有 png/jpeg/webp/gif）。
      final result = parsePhotoPickReply(_nativeReply(mediaType: 'image/heic'));
      expect(result, isA<PhotoPickUnsupportedType>());
      expect((result as PhotoPickUnsupportedType).mediaType, 'image/heic');
    });

    test('四个受支持类型都收（大小写不敏感）', () {
      for (final type in [
        'image/png',
        'image/jpeg',
        'image/webp',
        'image/gif',
      ]) {
        expect(
          parsePhotoPickReply(_nativeReply(mediaType: type)),
          isA<PhotoPicked>(),
          reason: '$type 应该收',
        );
      }
      expect(
        parsePhotoPickReply(_nativeReply(mediaType: 'IMAGE/PNG')),
        isA<PhotoPicked>(),
        reason: '原生给了大写也要收（统一小写）',
      );
    });

    test('形状不对：报失败，不当作取消', () {
      // **取消与"实现不符约定"必须分开**：混在一起会让"点了没反应"查不出来。
      for (final bad in <Object?>[
        'nope',
        42,
        <String, Object?>{'data': 'x'}, // 缺 mediaType
        <String, Object?>{'mediaType': 'image/png'}, // 缺 data
        <String, Object?>{'mediaType': 'image/png', 'data': ''}, // 空字节
      ]) {
        expect(
          parsePhotoPickReply(bad),
          isA<PhotoPickFailed>(),
          reason: '$bad 应报失败',
        );
      }
    });

    test('原生没给 byteCount：按 base64 长度估一个', () {
      final result =
          parsePhotoPickReply({
                'mediaType': 'image/png',
                'data': 'AAAAAAAA', // 8 字符 → 8*3/4 = 6
              })
              as PhotoPicked;
      expect(result.byteCount, 6);
      expect(result.name, '', reason: '没给名字就空串，不编一个');
    });

    test('**超大就拒收**（发出去会撞 8 MiB 单帧上限、把连接关掉）', () {
      // 契约 §40 / `codec.ts:53,77`：单帧上限 8 MiB，超了接收侧
      // `protocol/bad-frame` **并关闭连接**。图片在线上过两次 1.33 倍膨胀
      // （JSON base64 + box 的 base64url）⇒ 一帧 ≈ 1.78 × 原始字节。
      //
      // 所以"压失败了却照样发"的后果不是一条错误，是整条连接断掉 ——
      // 那种失败比"这张图发不出去"严重得多。
      final tooBig = parsePhotoPickReply(
        _nativeReply(byteCount: kMaxImageBytesForTransport + 1),
      );
      expect(tooBig, isA<PhotoPickTooLarge>());
      expect(
        (tooBig as PhotoPickTooLarge).byteCount,
        kMaxImageBytesForTransport + 1,
      );
    });

    test('正好等于上限：收（不是"超过才拒"）', () {
      expect(
        parsePhotoPickReply(
          _nativeReply(byteCount: kMaxImageBytesForTransport),
        ),
        isA<PhotoPicked>(),
      );
    });
  });

  group('pickPhoto：平台没有 / 原生报错 / 权限被拒，各有各的结果', () {
    test('没接通道（桌面 / 单测）→ unavailable', () async {
      final result = await pickPhoto(
        invoke: (_, _) async => throw MissingPluginException('no impl'),
      );
      expect(result, isA<PhotoPickUnavailable>());
    });

    test('原生报错 → failed，且带原生的原话', () async {
      final result = await pickPhoto(
        invoke: (_, _) async =>
            throw PlatformException(code: 'read-failed', message: '打不开选中的图片'),
      );
      expect(result, isA<PhotoPickFailed>());
      expect((result as PhotoPickFailed).reason, '打不开选中的图片');
    });

    test('**相机权限被拒单独一种**（恢复动作是进系统设置，不是重试）', () async {
      final result = await pickPhoto(
        source: PhotoSource.camera,
        invoke: (_, _) async => throw PlatformException(
          code: 'camera-permission',
          message: '没有相机权限，拍不了照',
        ),
      );
      expect(result, isA<PhotoPickPermissionDenied>());
      expect((result as PhotoPickPermissionDenied).reason, '没有相机权限，拍不了照');
    });

    test('成功路径：注入的调用结果被解析', () async {
      final result = await pickPhoto(invoke: (_, _) async => _nativeReply());
      expect(result, isA<PhotoPicked>());
    });

    test('来源真的传下去了（gallery / camera 各自的名字）', () async {
      // 这条钉的是"接口通了但参数没传"这类错：原生侧按 `source` 分叉，
      // 漏传就会永远走相册 —— 而"点拍照打开了相册"很难被察觉。
      final seen = <Map<String, Object?>>[];
      await pickPhoto(
        invoke: (method, args) async {
          expect(method, 'pickImage');
          seen.add(args);
          return _nativeReply();
        },
      );
      await pickPhoto(
        source: PhotoSource.camera,
        invoke: (_, args) async {
          seen.add(args);
          return _nativeReply();
        },
      );
      expect(seen, [
        {'source': 'gallery'},
        {'source': 'camera'},
      ]);
    });
  });

  group('发送载荷的形状（promptContentOf）', () {
    PendingAttachment image({
      String mediaType = 'image/png',
      String data = 'iVBORw0KGgo=',
      String name = '设计稿.png',
    }) => PendingAttachment(
      name: name.isEmpty ? 'png' : name,
      image: PickedImagePart(mediaType: mediaType, data: data, name: name),
    );

    test('只有文本：content 就是一段 text', () {
      expect(promptContentOf(text: '你好', attachments: const []), [
        {'type': 'text', 'text': '你好'},
      ]);
    });

    test('带一张图：图片在文本之前，且形状与 DSH 一致', () {
      final content = promptContentOf(text: '这张图里是什么', attachments: [image()]);
      expect(content.length, 2);
      expect(content.first, {
        'type': 'image',
        'mediaType': 'image/png',
        'data': 'iVBORw0KGgo=',
        'name': '设计稿.png',
      });
      expect(content.last, {'type': 'text', 'text': '这张图里是什么'});
    });

    test('没有名字就不带 name 键（DSH 的 name?: 是可选的）', () {
      final wire = const PickedImagePart(
        mediaType: 'image/png',
        data: 'AA',
      ).toWire();
      expect(wire.containsKey('name'), isFalse);
      expect(wire, {'type': 'image', 'mediaType': 'image/png', 'data': 'AA'});
    });

    test('**只发一张图**：content 里没有空的 text part', () {
      // 2026-10-20 修的那条：`_send()` 原来只要 `text.isEmpty` 就 return，
      // 于是"选了照片没打字"点发送什么都不发生。而 DSH 的 content 本来就是
      // part 数组，可以没有文本 part —— 发一个空 text 只是噪音。
      final content = promptContentOf(text: '', attachments: [image()]);
      expect(content, [
        {
          'type': 'image',
          'mediaType': 'image/png',
          'data': 'iVBORw0KGgo=',
          'name': '设计稿.png',
        },
      ]);
      expect(content.any((part) => part['type'] == 'text'), isFalse);
    });

    test('**不可发送的附件不进 content**（不假装发出去）', () {
      // 只有名字、没有字节的芯片是"仅展示"的（`isInert`）。
      // 它绝不能出现在载荷里 —— 那正是 2026-10-20 拔掉的假附件的行为。
      final content = promptContentOf(
        text: '带了个附件',
        attachments: const [PendingAttachment(name: '新增文件.txt')],
      );
      expect(content, [
        {'type': 'text', 'text': '带了个附件'},
      ]);
      expect(content.any((part) => part['type'] == 'image'), isFalse);
    });

    test('多张图按输入栏顺序排，文本仍在最后', () {
      final content = promptContentOf(
        text: '对比一下',
        attachments: [
          image(name: 'a.png', data: 'AA'),
          image(name: 'b.jpg', mediaType: 'image/jpeg', data: 'BB'),
        ],
      );
      expect(content.map((part) => part['type']).toList(), [
        'image',
        'image',
        'text',
      ]);
      expect(content[0]['name'], 'a.png');
      expect(content[1]['name'], 'b.jpg');
      expect(content[1]['mediaType'], 'image/jpeg');
    });
  });
}
