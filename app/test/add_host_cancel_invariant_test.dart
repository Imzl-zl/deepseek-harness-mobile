/// 「添加电脑 → 取消」不能把当前电脑弄丢。
///
/// 这是装配层的状态不变量：`_addHost` 为了进配对页会把内存客户端换成"未配对"
/// 那一个（`_credentials` 置空），但落盘的槽还在。取消时如果不重新装载，
/// 用户会停在"未配对"，只能重启 App —— 线上看起来像"点了一下添加，电脑没了"。
///
/// ## 为什么是源码结构断言
///
/// `_DshMobileAppState` 是私有的，且 `_boot` 要起真 sqflite / 真 socket；
/// 这里没有可注入的 seam（`pairingStore` 是全局）。所以与
/// `assembly_invariants_test.dart` 同一条办法：从 `main.dart` 的源码里确认
/// 两段关键接线没有退回去。它守的是"有人把恢复那几行删了"，不是"运行起来
/// 一定对"——后者要真机/集成测试，见决策笔记的待验项。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $startMarker');
  final end = source.indexOf(endMarker, start + startMarker.length);
  expect(end, greaterThan(start), reason: '找不到 $startMarker 之后的 $endMarker');
  return source.substring(start, end);
}

void main() {
  late String source;

  setUpAll(() {
    source = File('lib/main.dart').readAsStringSync();
  });

  test('_addHost 记住进配对页之前那台，_closePairing 用 _switchTo 装回来', () {
    final add = _slice(source, 'void _addHost()', 'void _enterPairing(');
    expect(
      add,
      contains('_hostBeforeAdd = _credentials?.pcSignPubHex'),
      reason: '不记住原 host，取消时就没有目标可装回',
    );
    expect(add, contains('_addingHost = true'), reason: '取消分支要靠这个标记区分"添加"');

    final close = _slice(
      source,
      'void _closePairing()',
      'Future<void> _onPaired(',
    );
    expect(
      close,
      contains('_switchTo(hostId)'),
      reason: '取消要走同一条"读槽 + 装配 + start"的路，不能只把 _pairing 置 false',
    );
    expect(close, contains('_addingHost = false'), reason: '恢复后要清标记，避免下次误恢复');
  });

  test('配对成功清掉"添加"标记：下次取消不该装回旧那台', () {
    final paired = _slice(
      source,
      'Future<void> _onPaired(',
      'Future<void> _switchTo(',
    );
    expect(paired, contains('_addingHost = false'));
    expect(paired, contains('_hostBeforeAdd = null'));
  });
}
