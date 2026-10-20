/// "这一轮改了哪些文件"的推导 —— 判据全部来自 DSH 的 `mutationPath`。
///
/// 权威出处：`packages/client/ui-deliverables/src/client/turn-deliverables.ts:61-77`
/// 与 `validEditArgs`(`:150-158`)、`editorMutationPath`(`:90-112`)、
/// `pathValue`(`:115-117`)。
///
/// 这条数据的性质（DSH 文件头注释）：**model-free** —— 路径来自"成功的变更类
/// 工具调用"，不需要模型自述。所以手机上算出来的清单是**真事实**。
library;

import 'package:dsh_mobile/model/changed_path.dart';
import 'package:flutter_test/flutter_test.dart';

String? pathOf(String name, String args) =>
    changedPathOf(name: name, argumentsJson: args);

void main() {
  group('write', () {
    test('content 是字符串且 file_path 非空 → 路径', () {
      expect(
        pathOf(
          'write',
          '{"file_path":"app/lib/ui/x.dart","content":"void main(){}"}',
        ),
        'app/lib/ui/x.dart',
      );
    });

    test('content 不是字符串 → null（DSH: `typeof args.content === "string"`）', () {
      expect(pathOf('write', '{"file_path":"a.dart","content":42}'), isNull);
      expect(pathOf('write', '{"file_path":"a.dart"}'), isNull);
    });

    test('file_path 是空白 → null', () {
      expect(pathOf('write', '{"file_path":"   ","content":"x"}'), isNull);
      expect(pathOf('write', '{"file_path":"","content":"x"}'), isNull);
    });
  });

  group('edit', () {
    const ok = '{"file_path":"a.dart","old_string":"x","new_string":"y"}';

    test('五个条件全中 → 路径', () {
      expect(pathOf('edit', ok), 'a.dart');
    });

    test('**old_string == new_string 不算改动**（相同替换不产生 diff）', () {
      expect(
        pathOf(
          'edit',
          '{"file_path":"a.dart","old_string":"x","new_string":"x"}',
        ),
        isNull,
      );
    });

    test('old_string 为空 / 缺失 → null', () {
      expect(
        pathOf(
          'edit',
          '{"file_path":"a.dart","old_string":"","new_string":"y"}',
        ),
        isNull,
      );
      expect(pathOf('edit', '{"file_path":"a.dart","new_string":"y"}'), isNull);
    });

    test('replace_all 给了就必须是 bool', () {
      expect(
        pathOf(
          'edit',
          '{"file_path":"a.dart","old_string":"x","new_string":"y","replace_all":"yes"}',
        ),
        isNull,
      );
      expect(
        pathOf(
          'edit',
          '{"file_path":"a.dart","old_string":"x","new_string":"y","replace_all":true}',
        ),
        'a.dart',
      );
    });
  });

  group('str_replace_editor（按 command 分三种）', () {
    test('create 要有 file_text', () {
      expect(
        pathOf(
          'str_replace_editor',
          '{"command":"create","path":"b.dart","file_text":"x"}',
        ),
        'b.dart',
      );
      expect(
        pathOf('str_replace_editor', '{"command":"create","path":"b.dart"}'),
        isNull,
      );
    });

    test('str_replace 要有非空 old_str，new_str 可省', () {
      expect(
        pathOf(
          'str_replace_editor',
          '{"command":"str_replace","path":"b.dart","old_str":"a"}',
        ),
        'b.dart',
      );
      expect(
        pathOf(
          'str_replace_editor',
          '{"command":"str_replace","path":"b.dart","old_str":""}',
        ),
        isNull,
      );
    });

    test('insert 要有整数 insert_line ≥ 0 与 new_str', () {
      expect(
        pathOf(
          'str_replace_editor',
          '{"command":"insert","path":"b.dart","insert_line":3,"new_str":"x"}',
        ),
        'b.dart',
      );
      expect(
        pathOf(
          'str_replace_editor',
          '{"command":"insert","path":"b.dart","insert_line":-1,"new_str":"x"}',
        ),
        isNull,
      );
    });

    test('不认识的 command → null', () {
      expect(
        pathOf('str_replace_editor', '{"command":"view","path":"b.dart"}'),
        isNull,
      );
    });
  });

  group('不是变更类的调用一律 null（别把读操作算成改动）', () {
    test('Read / Bash / Grep / Glob', () {
      for (final name in ['Read', 'Bash', 'Grep', 'Glob', 'read', 'bash']) {
        expect(
          pathOf(name, '{"file_path":"a.dart","content":"x"}'),
          isNull,
          reason: '$name 不是变更类',
        );
      }
    });

    test('参数不是 JSON / 不是对象 → null（DSH 的 try/catch 同一处理）', () {
      expect(pathOf('write', 'not json'), isNull);
      expect(pathOf('write', '[]'), isNull);
      expect(pathOf('write', '"a string"'), isNull);
      expect(pathOf('write', ''), isNull);
    });
  });
}
