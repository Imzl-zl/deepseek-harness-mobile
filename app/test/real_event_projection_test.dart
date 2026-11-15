/// 真实事件形状的投影回归。
///
/// ## 为什么要有这一组
///
/// 2026-10-19 真机复现的渲染缺陷（用户原话"会话渲染只有思考，工具调用，
/// 没有输出，运行命令啥的"）根因是**我们以为的事件形状与真形状不同**：
///
/// - `tool/result` 的真实载荷**不带 `name`**（只有 `role` / `source` /
///   `toolCallId` / `content` / `isError` / `id`），而投影从结果里读名字 ——
///   于是结果一到达，卡片上的 `read` 被覆盖成"工具"、参数行被覆盖成
///   `role, source, toolCallId, conten…`（JSON 键名清单）。
/// - `assistant/message` 的 content 里 `reasoning` / `text` / `tool-call`
///   三种块并存，且**可能一个 `text` 块都没有**（纯工具回合）——
///   那时"没有正文"是事实，不是缺陷。
///
/// 手写形状的用例对这些一无所知（它们只会复述实现的假设）。
/// 所以这里的断言值全部来自**真机落盘的会话日志**
/// （`app/test/fixtures/real-session-events.json`，DSH 0.2.1 真形状），
/// 而投影逻辑的正确性判据是 DSH Web 的同一处源码：
/// `packages/client/ui-chat/src/client/conversation-nodes/tool.ts:100-118`
/// 的 `rootResult(match, previous)` —— **结果继承调用的名字与参数**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/data/projection.dart' hide projectEvent;
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_fixture.dart';

/// 读真事件 fixture（字段一个都没改，只有两处长文本被截断并标注）。
Map<String, Object?> _fixture() {
  final raw = File('test/fixtures/real-session-events.json').readAsStringSync();
  return jsonDecode(raw) as Map<String, Object?>;
}

/// 把 fixture 里的一条事件喂给投影（[previous] 由调用方给）。
ChatItem _project(Map<String, Object?> event, {ChatItem? previous}) =>
    projectEvent(
      type: event['type'] as String,
      seq: event['seq'] as int,
      data: event['data'],
      time: event['time'] as int,
      previous: previous,
    ).item!;

void main() {
  group('真形状：tool/call → tool/result 的继承', () {
    test('结果到达后卡片仍叫 read、参数仍是调用那一句', () {
      final fixture = _fixture();
      final call =
          _project(fixture['toolCall'] as Map<String, Object?>) as ToolCallItem;
      // 调用自己带着名字与参数（这一半一直是对的）。
      expect(call.name, 'read');
      expect(call.status, ToolCallStatus.running);
      expect(call.summary, contains('memory.md'));

      // **真结果载荷里没有 name**：这是缺陷的根，先钉住这个事实。
      final resultData =
          (fixture['toolResult'] as Map<String, Object?>)['data']
              as Map<String, Object?>;
      final resultMessage = resultData['message'] as Map<String, Object?>;
      expect(
        resultMessage.containsKey('name'),
        isFalse,
        reason: '真结果不带 name —— 名字只能从 tool/call 继承（DSH rootResult）',
      );

      final result =
          _project(
                fixture['toolResult'] as Map<String, Object?>,
                previous: call,
              )
              as ToolCallItem;
      // 继承调用：名字与参数都不许被结果覆盖掉。
      expect(result.name, 'read', reason: '结果继承调用的名字');
      expect(result.summary, call.summary, reason: '参数行仍用调用那一句');
      expect(result.status, ToolCallStatus.completed);
      // 结果正文进明细（展开才看得见）。
      expect(result.detail, contains('dsh-mobile 项目状态'));
      expect(result.detail, isNot(contains('role, source')));
    });

    test('没有 previous（历史只落到结果）时不编名字，也不摊平键名', () {
      final fixture = _fixture();
      final result =
          _project(fixture['toolResult'] as Map<String, Object?>)
              as ToolCallItem;
      // DSH 同处是 `name: previous?.name ?? ''`：没有调用就没有名字。
      expect(result.name, '工具');
      // **不许把结果消息摊平成一串键名**（真机上的 `role, source, toolCallId, conten…`）。
      expect(result.summary, isEmpty);
      expect(result.detail, isNotEmpty, reason: '输出本身仍然要能看');
    });

    test('同一个 delta 里先 call 后 result：合并仍然成立', () {
      // AppModel 的 `inBatch` 路径：store.upsertAll 在整批之后才发生，
      // 所以结果要找的"前一个条目"来自本批已投影的映射。
      final fixture = _fixture();
      final call =
          _project(fixture['toolCall'] as Map<String, Object?>) as ToolCallItem;
      final result =
          _project(
                fixture['toolResult'] as Map<String, Object?>,
                previous: call,
              )
              as ToolCallItem;
      expect(result.itemId, call.itemId, reason: '结果与调用同一条目');
      expect(result.name, 'read');
    });
  });

  group('真形状：assistant/message 的三种块', () {
    test('text 块是正文、reasoning 块是思考过程、tool-call 块不是正文', () {
      final fixture = _fixture();
      final item =
          _project(fixture['assistant'] as Map<String, Object?>) as MessageItem;
      expect(item.role, MessageRole.assistant);
      // 正文只来自 `type == 'text'` 的块。
      expect(item.text, contains('Round 1 只做了调研'));
      // 思考过程单独一栏，不混进正文。
      expect(item.reasoning, isNotEmpty);
      expect(item.text, isNot(contains('The user has given me')));
      // **没有附件**：这条消息的块里没有 image/file。
      expect(item.attachmentCount, 0);
    });
  });

  group('真形状：user/message 带图片', () {
    test('图片只计数，正文照常', () {
      final fixture = _fixture();
      final item =
          _project(fixture['user'] as Map<String, Object?>) as MessageItem;
      expect(item.role, MessageRole.user);
      expect(item.attachmentCount, 1);
      expect(item.text, 'Reference attachments for the goal objective.');
      expect(item.systemLabel, isNull, reason: '用户消息没有系统行标签');
    });
  });

  // 2026-10-20 隔离实例真日志（`$DSH_HOME/sessions/.../session.v4.jsonl.zstd`）：
  // 运行时上下文 / 技能目录 / 时间快照**都是 `user/message`**，靠 `source.kind`
  // 区分。DSH Web 的判据是 `source.kind !== 'user'` ⇒ 上下文节点
  // （`ui-chat/src/client/conversation-nodes/message.ts:79`）。
  group('真形状：上下文注入也是 user/message（按 source.kind 认角色）', () {
    Map<String, Object?> injected(String kind) => {
      'type': 'user/message',
      'seq': 9,
      'time': 1792500680000,
      'data': {
        'content': [
          {'type': 'text', 'text': 'Current runtime context. …'},
        ],
        'source': {'kind': kind, 'form': 'snapshot'},
        'role': 'user',
        'id': 'msg-ctx',
      },
    };

    test('runtime-context → 上下文注入行，不是用户气泡', () {
      final item = _project(injected('runtime-context')) as MessageItem;
      expect(item.role, MessageRole.system);
      expect(item.systemLabel, kContextInjectionLabel);
      expect(item.systemHint, 'runtime-context');
    });

    test('skill-catalog / time-context 同样归到上下文行', () {
      for (final kind in ['skill-catalog', 'time-context']) {
        final item = _project(injected(kind)) as MessageItem;
        expect(item.role, MessageRole.system, reason: kind);
        expect(item.systemHint, kind, reason: kind);
      }
    });

    test('source.kind == user 才是人打的字', () {
      final item = _project(injected('user')) as MessageItem;
      expect(item.role, MessageRole.user);
      expect(item.systemLabel, isNull);
      expect(item.systemHint, isNull);
    });

    test('没有 source（v3 形状）按用户消息处理 —— 不许把真人说的话藏起来', () {
      final item =
          _project({
                'type': 'user/message',
                'seq': 3,
                'time': 1792500680000,
                'data': {
                  'content': [
                    {'type': 'text', 'text': '老日志里的一句人话'},
                  ],
                  'id': 'msg-legacy',
                },
              })
              as MessageItem;
      expect(item.role, MessageRole.user);
      expect(item.systemLabel, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // 卡片右上角的 `+N −M`
  //
  // 2026-11-15 用户反馈的原话：「桌面执行编辑啥的修改了那个变化，app 上显示 0，
  // 我以为出错了，我看桌面不是 0，确实改了」。
  //
  // 根因是一条**真形状**：`write` 创建文件时宿主的 `presentationMeta.diffs` 是
  // **空数组**（`packages/fs/tool-fs/src/write.ts:103-110`：`value.before === null`
  // 就是 create，那时没有旧文本可比）。而桌面对"空 diffs"有回退规则 ——
  // `packages/client/ui-tool/src/client/tool/models/diff-card-model.ts:113-116`：
  //
  //     if (applied === null || applied === 'empty') {
  //       return intended.tool === 'write' ? { card: { diffs: [intended.diff] } } : null
  //     }
  //
  // 也就是：**空 diffs + write ⇒ 用调用参数里的 content 当整份新增；空 diffs + edit
  // ⇒ 整块不画**。我们只照抄了"读 meta.diffs"，于是 create 算出 `+0 −0`。
  // ---------------------------------------------------------------------------
  group('改动行数：空 diffs 的回退（DSH diffCardModel）', () {
    /// 一次 `write` 调用（真参数形状：`file_path` + `content`）。
    Map<String, Object?> writeCall(String content) => {
      'type': 'tool/call',
      'seq': 700,
      'time': 1792500800000,
      'data': {
        'turn': 4,
        'step': 1,
        'callId': 'call-write-1',
        'name': 'write',
        'arguments': jsonEncode({
          'file_path': 'D:/tmp/a.txt',
          'content': content,
        }),
      },
    };

    /// 同一个调用的结果。**`meta.diffs` 是空数组** —— 真日志里 create 就是这样
    /// （本机 2026-11-15 的 `session.v4.jsonl.zstd` 实测，`write` 建两篇笔记都是 `[]`）。
    Map<String, Object?> writeResult({
      List<Object?> diffs = const [],
      bool isError = false,
      String name = 'write',
      Map<String, Object?>? meta,
    }) => {
      'type': 'tool/result',
      'seq': 701,
      'time': 1792500801000,
      'data': {
        'turn': 4,
        'step': 1,
        'message': {
          'role': 'tool',
          'source': {'kind': 'tool', 'callId': 'call-write-1'},
          'toolCallId': 'call-write-1',
          'content': [
            {'type': 'text', 'text': 'Created file'},
          ],
          'isError': isError,
          'id': 'msg-write-1',
        },
        'meta':
            meta ??
            <String, Object?>{
              'operation': 'create',
              'path': 'D:/tmp/a.txt',
              'diffs': diffs,
            },
      },
    };

    test('运行中的 write 先按参数显示整份新增（DSH：running 用 intended）', () {
      final call = _project(writeCall('x\ny\n')) as ToolCallItem;
      expect(call.status, ToolCallStatus.running);
      expect(call.diffStat, (
        added: 2,
        removed: 0,
      ), reason: '桌面在跑的时候就按参数画整份内容（diff-card-model.ts:110）');
    });

    test('write 创建文件（meta.diffs 为空）不显示 +0 −0，而是整份新增', () {
      final call = _project(writeCall('x\ny\n')) as ToolCallItem;
      final result = _project(writeResult(), previous: call) as ToolCallItem;
      expect(
        result.diffStat,
        (added: 2, removed: 0),
        reason: '空 diffs 的 write 要回退到调用参数（diff-card-model.ts:113-116）',
      );
    });

    test('冷启动：调用那一半从合并载荷读回来，回退照样成立', () {
      // 历史只落到结果时 hand 里没有 `previous`；参数在**合并载荷**上
      // （`StoreItemPersister` 把 `name` / `arguments` 留在同一行，见
      // `wire/events.dart` 的 `mergedToolCallOf`）。
      final data = writeResult()['data'] as Map<String, Object?>;
      final merged = <String, Object?>{
        ...data,
        'name': 'write',
        'arguments': jsonEncode({
          'file_path': 'D:/tmp/a.txt',
          'content': 'x\ny\n',
        }),
      };
      final result =
          _project({
                'type': 'tool/result',
                'seq': 701,
                'time': 1792500801000,
                'data': merged,
              })
              as ToolCallItem;
      expect(result.diffStat, (added: 2, removed: 0));
    });

    test('连合并载荷都没有（合并写之前的老行）：**不编数字**，留空', () {
      // 那时算不出行数，而 `+0 −0` 是"看起来像 0"的谎话
      // （与 `files_pane.dart` 的同一条纪律）。
      final result = _project(writeResult()) as ToolCallItem;
      expect(result.diffStat, isNull);
    });

    test('edit 的空 diffs 整块不画（不是 +0 −0）', () {
      final call =
          _project({
                'type': 'tool/call',
                'seq': 700,
                'time': 1792500800000,
                'data': {
                  'turn': 4,
                  'step': 1,
                  'callId': 'call-write-1',
                  'name': 'edit',
                  'arguments': jsonEncode({
                    'file_path': 'D:/tmp/a.txt',
                    'old_string': 'a',
                    'new_string': 'b',
                  }),
                },
              })
              as ToolCallItem;
      final result =
          _project(
                writeResult(
                  meta: <String, Object?>{
                    'path': 'D:/tmp/a.txt',
                    'diffs': <Object?>[],
                  },
                ),
                previous: call,
              )
              as ToolCallItem;
      expect(result.name, 'edit');
      expect(result.diffStat, isNull, reason: 'DSH 对空 diffs 的 edit 返回 null');
    });

    test('失败的结果不算改动（DSH：isError ⇒ 不画 diff）', () {
      final call = _project(writeCall('x\ny\n')) as ToolCallItem;
      final result =
          _project(
                writeResult(
                  isError: true,
                  meta: <String, Object?>{
                    'path': 'D:/tmp/a.txt',
                    'diffs': [
                      {
                        'path': 'D:/tmp/a.txt',
                        'oldText': 'a\nb',
                        'newText': 'a\nc',
                      },
                    ],
                  },
                ),
                previous: call,
              )
              as ToolCallItem;
      expect(result.status, ToolCallStatus.failed);
      expect(result.diffStat, isNull);
    });

    test('没有专用卡的工具（apply_patch）按线级折，不是按两段文本的行数', () {
      final call =
          _project({
                'type': 'tool/call',
                'seq': 700,
                'time': 1792500800000,
                'data': {
                  'turn': 4,
                  'step': 1,
                  'callId': 'call-write-1',
                  'name': 'apply_patch',
                  'arguments': '{"input":"*** Begin Patch"}',
                },
              })
              as ToolCallItem;
      final result =
          _project(
                writeResult(
                  meta: <String, Object?>{
                    'diffs': [
                      {
                        'path': 'D:/tmp/a.txt',
                        'oldText': 'a\nb',
                        'newText': 'a\nc',
                      },
                    ],
                  },
                ),
                previous: call,
              )
              as ToolCallItem;
      expect(result.name, 'apply_patch');
      // 旧实现把 oldText 的 2 行全算删除、newText 的 2 行全算新增（`+2 −2`）；
      // 真实只有 1 增 1 删 —— 与 `diffStatOfTexts` 同一个口径。
      expect(result.diffStat, (added: 1, removed: 1));
    });
  });
}
