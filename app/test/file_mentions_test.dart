/// 正文里的文件提及：**唯一一处解析器**（`lib/model/file_mentions.dart`）。
///
/// ## 判据从哪来（不是我们发明的规则）
///
/// DSH 的解析器 `producedFileMentions`
/// （`packages/client/ui-deliverables/src/client/turn-deliverables.ts:269-296`）：
///
/// - 词表是**这一轮产出/交付的路径**，不是工作区文件清单
///   （README 原话 "inline-code matching remains limited to produced or delivered files"）；
/// - 命中的条件只有两条：`path === value` 或 `basename(path) === value`；
/// - **命中恰好一条**才 resolve；歧义（两条同名 basename）与未知都保持惰性；
/// - 只有**行内代码**（`inlineCode`）是候选 —— 围栏代码块里的内容是源码，不是链接
///   （渲染层只对 `inlineCode` 节点查词表，`ui-primitives/src/markdown/render.tsx:335-366`）。
///
/// 用例里的词表故意用"两个目录下同名文件"来钉住歧义那一档 —— 那一档最容易被
/// "先匹配先赢"的实现悄悄放过，而它的代价是用户点开一个错文件。
library;

import 'package:dsh_mobile/model/file_mentions.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一处命中：命中的路径 + 原文里的位置（`substring(start, end)` 就是 token 原样）。
void _expectSpan(
  FileMentionSpan span, {
  required String token,
  required String path,
}) {
  expect(span.token, token);
  expect(span.path, path);
}

void main() {
  const paths = <String>{'src/a.ts', 'src/b.ts', 'docs/note.md', 'server/a.ts'};

  test('整条路径命中：行内代码里的 `src/a.ts` 成为提及', () {
    const text = '看到了 `src/a.ts` 里的问题。';
    final spans = resolveFileMentions(text, knownPaths: paths);
    expect(spans, hasLength(1));
    _expectSpan(spans.single, token: 'src/a.ts', path: 'src/a.ts');
    expect(text.substring(spans.single.start, spans.single.end), 'src/a.ts');
  });

  test('basename 唯一命中时才成为提及（`note.md` → docs/note.md）', () {
    final spans = resolveFileMentions('改的是 `note.md`。', knownPaths: paths);
    expect(spans, hasLength(1));
    _expectSpan(spans.single, token: 'note.md', path: 'docs/note.md');
  });

  test('basename 歧义保持惰性：两条 `a.ts` 都不猜', () {
    final spans = resolveFileMentions('看 `a.ts`。', knownPaths: paths);
    expect(spans, isEmpty, reason: '歧义命中必须先赢？不 —— DSH 那里是保持惰性');
  });

  test('未知 token 保持惰性（认不出就是普通代码）', () {
    final spans = resolveFileMentions(
      '看 `nope.txt` 与 `nothing`。',
      knownPaths: paths,
    );
    expect(spans, isEmpty);
  });

  test('词表为空 ⇒ 一条都不认（离线 / 这一轮没有改动）', () {
    final spans = resolveFileMentions(
      '看 `src/a.ts`。',
      knownPaths: const <String>{},
    );
    expect(spans, isEmpty);
  });

  test('普通正文里的路径不算提及：只有行内代码是候选', () {
    final spans = resolveFileMentions('src/a.ts 这个文件我看过了。', knownPaths: paths);
    expect(spans, isEmpty);
  });

  test('围栏代码块里的路径不算提及（``` 与 ~~~ 两种围栏）', () {
    const fence =
        '示例：\n\n```ts\nimport x from "src/a.ts"\n```\n\n~~~\nsrc/b.ts\n~~~\n';
    expect(resolveFileMentions(fence, knownPaths: paths), isEmpty);
  });

  test('未闭合的围栏一直算围栏内（流式途中就是这样）', () {
    const text = '看：\n\n```ts\nsrc/a.ts\n';
    expect(resolveFileMentions(text, knownPaths: paths), isEmpty);
  });

  test('双反引号包一段带反引号的代码：内容按原样比（`` `a` ``）', () {
    // CommonMark 的 code span：开闭的反引号串长度必须相等。
    final spans = resolveFileMentions(
      '看 `` src/a.ts `` 与 `` `x` ``。',
      knownPaths: paths,
    );
    expect(spans, hasLength(1));
    _expectSpan(spans.single, token: 'src/a.ts', path: 'src/a.ts');
  });

  test('同一个 token 出现两次 ⇒ 两处（每一处都要能点）', () {
    final spans = resolveFileMentions(
      '`src/a.ts` 与 `src/a.ts`',
      knownPaths: paths,
    );
    expect(spans, hasLength(2));
    expect(spans[0].start, lessThan(spans[1].start));
    for (final span in spans) {
      _expectSpan(span, token: 'src/a.ts', path: 'src/a.ts');
    }
  });

  test('token 里的换行归一成空格，两侧各剥一层空格（CommonMark）', () {
    final spans = resolveFileMentions(
      '看 `\nsrc/a.ts\n` 这段。',
      knownPaths: paths,
    );
    expect(spans, hasLength(1));
    // mdast 的 `inlineCode.value` 就是归一后的值：换行 → 空格、剥一层首尾空格。
    _expectSpan(spans.single, token: 'src/a.ts', path: 'src/a.ts');
  });

  test('结尾一个孤立的反引号不影响前面的提及（CommonMark 的反引号串配对）', () {
    final spans = resolveFileMentions(
      '看 `src/b.ts` 与一个孤立的 ` 。',
      knownPaths: paths,
    );
    expect(spans, hasLength(1));
    _expectSpan(spans.single, token: 'src/b.ts', path: 'src/b.ts');
  });

  test('Windows 反斜杠路径的 basename 也认（`src\\a.ts`，与 DSH 的 basename 同一条）', () {
    final spans = resolveFileMentions(
      r'看 `a.ts` 与 `src\a.ts`。',
      knownPaths: const <String>{r'src\a.ts'},
    );
    expect(spans, hasLength(2));
    for (final span in spans) {
      expect(span.path, r'src\a.ts');
    }
  });

  test('targets：token → path 一张表，供渲染层查（同一 token 只一条）', () {
    final spans = resolveFileMentions(
      '`src/a.ts` 与 `src/a.ts` 还有 `note.md`',
      knownPaths: paths,
    );
    expect(fileMentionTargets(spans), {
      'src/a.ts': 'src/a.ts',
      'note.md': 'docs/note.md',
    });
  });

  test('空正文 / 空词表组合不抛（渲染层对每条消息都会问一次）', () {
    expect(resolveFileMentions('', knownPaths: paths), isEmpty);
    expect(resolveFileMentions('`a`', knownPaths: const <String>{}), isEmpty);
  });
}
