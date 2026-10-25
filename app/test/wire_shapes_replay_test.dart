/// 连接器**金样**的跨工程回放闸门：`connector/tests/fixtures/wire-shapes.json`。
///
/// ## 这一组守什么（第 0 批：只守"文件在、没缩水"）
///
/// 1. **文件必须存在**。缺失时**直接 `fail`，不许 `skip`** —— 跳过会让门禁静默退化成空跑，
///    而空跑这一档在三次事故里一次都没被拦住过。
/// 2. **两个已收的方法键缺一不可**（`session.list` / `session.projections`）。少一个就红。
/// 3. 每条样本 `jsonDecode` 出来必须是 `Map`、且每个方法至少一条样本
///    —— 空集上"逐条都解得出"是空话。
///
/// ## 样本从哪来（为什么不是"真机抓一份"）
///
/// 由**连接器的测试**调真实 handler 产出、深比较守住（`connector/tests/wire-shapes.test.ts`）。
/// 真样本是一次性快照，连接器改了应答它不会变，用例永远绿 —— 这正是
/// `memory.md` 教训第九条的形态，只是把"手捏的形状"换成了"过期的真形状"。
///
/// ## 失败的判读方向
///
/// 这个文件红了，通常意味着**连接器的应答变了**（连接器那边那条用例会一起红）。
/// 正确的处置是：确认改动是有意的 ⇒ 连接器侧 `UPDATE_WIRE_SHAPES=1` 重生成
/// ⇒ 同步本仓的解码（`app/lib/wire/rpc/`）。**不要**只改这里让它变绿。
///
/// Note: 取舍与代价（跨工程测试耦合、文件缺失必须 fail）见
/// `.agents/notes/implemented/2026-10-25-wire-golden-and-session-list.md`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 金样相对 `app/`（`flutter test` 的工作目录）的路径。
const String kGoldenWireShapes = '../connector/tests/fixtures/wire-shapes.json';

/// 本轮已收进金样的方法。**只许增不许减**：少一个键就说明生成侧缩水了。
const List<String> kSampledMethods = ['session.list', 'session.projections'];

Map<String, Object?> _golden() {
  final file = File(kGoldenWireShapes);
  if (!file.existsSync()) {
    fail(
      '金样不存在：$kGoldenWireShapes\n'
      '这一条**不许 skip**：跳过等于让整套形状门禁静默退化成空跑。'
      '重新生成：cd connector; UPDATE_WIRE_SHAPES=1 pnpm exec tsx --test tests/wire-shapes.test.ts',
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

void main() {
  late Map<String, Object?> golden;

  setUp(() {
    golden = _golden();
  });

  test('金样在：两个已收的方法键缺一不可（不许缩水）', () {
    for (final method in kSampledMethods) {
      expect(
        golden.containsKey(method),
        isTrue,
        reason: '金样少了 $method —— 生成侧的 SAMPLES 被删了，或本文件被手改过',
      );
    }
  });

  test('每条样本都是对象，且每个方法至少一条样本', () {
    for (final method in kSampledMethods) {
      final samples = golden[method];
      expect(
        samples,
        isA<List<Object?>>(),
        reason: '$method 的样本必须是数组（多形态方法放多条）',
      );
      final list = samples! as List<Object?>;
      expect(list, isNotEmpty, reason: '$method 一条样本都没有：断言会在空集上全绿');
      for (var index = 0; index < list.length; index += 1) {
        expect(
          list[index],
          isA<Map<String, Object?>>(),
          reason: '$method 的第 ${index + 1} 条样本不是对象',
        );
      }
    }
  });
}
