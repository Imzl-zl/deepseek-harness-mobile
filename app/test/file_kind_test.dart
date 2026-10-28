/// 文件预览按**后缀**选渲染器（与桌面 viewer 注册表同一张表）。
///
/// 判据出处：桌面 `ui-sidebar-documentpreview/src/client/markdown/index.ts:17`
/// （`extensions: ['md', 'markdown']`），纯文本兜底是 `text/index.ts:16`。
/// 后缀大小写不敏感（桌面 `suffix.ts:11` 的 `normalizeSuffix` 先转小写）。
library;

import 'package:dsh_mobile/model/file_open.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('md / markdown 按 Markdown 渲染（大小写不敏感、认路径分隔符）', () {
    expect(isMarkdownPath('README.md'), isTrue);
    expect(isMarkdownPath('docs/guide.markdown'), isTrue);
    expect(isMarkdownPath(r'C:\work\a\NOTES.MD'), isTrue);
    expect(isMarkdownPath('a/README.Md'), isTrue);
  });

  test('其它后缀按纯文本 / 代码渲染', () {
    expect(isMarkdownPath('main.dart'), isFalse);
    expect(isMarkdownPath('notes.txt'), isFalse);
    expect(isMarkdownPath('md'), isFalse, reason: '名字就是 md 而不是后缀');
    expect(isMarkdownPath('readme.md.bak'), isFalse);
    expect(isMarkdownPath(''), isFalse);
  });
}
