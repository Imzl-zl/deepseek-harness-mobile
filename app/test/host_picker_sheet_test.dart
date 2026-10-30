/// 「切换电脑」列表（多机第 4 步的界面入口）。
///
/// 这一组钉三件事：
///
/// 1. **行 = 名称 + 其下标签组**（`AGENTS.md` 的选择类列表规则）：短码与"当前"
///    放在第二行，不与名称抢同一行的宽度；
/// 2. **当前那台标出来**（勾位 + 标签），用户一眼知道"我现在连的是哪个"；
/// 3. **点一行返回它的 hostId**（切换只认身份，不认名字 —— 名字可改可重名）。
library;

import 'package:dsh_mobile/platform/pairing_store.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/host_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _hostA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _hostB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// 点一下按钮就弹列表，把返回值记在 [picked] 里。
Widget _host({
  required List<PairedHost> hosts,
  required String? current,
  required List<String?> picked,
}) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          final hostId = await pickPairedHost(
            context,
            hosts: hosts,
            currentHostId: current,
          );
          picked.add(hostId);
        },
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  testWidgets('两台的名称、短码与「当前」都在；点另一台返回它的 hostId', (tester) async {
    final picked = <String?>[];
    await tester.pumpWidget(
      _host(
        hosts: const [
          PairedHost(hostId: _hostA, name: '客厅那台'),
          PairedHost(hostId: _hostB),
        ],
        current: _hostA,
        picked: picked,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 名称来自电脑自报（有）；没名字的那台退回短码。
    expect(find.text('客厅那台'), findsOneWidget);
    expect(find.text('bbbbbb…bbbb'), findsWidgets);
    // "当前"只在当前那台出现一次。
    expect(find.text('当前'), findsOneWidget);
    expect(find.text('已配对'), findsOneWidget);

    // 切换只认身份：点的是"bbbbbb…bbbb"那一台 → 返回 hostB。
    await tester.tap(find.text('bbbbbb…bbbb').last);
    await tester.pumpAndSettle();

    expect(picked, [_hostB], reason: '返回的是 hostId，不是名字');
  });

  testWidgets('取消（点外面）返回 null，不换电脑', (tester) async {
    final picked = <String?>[];
    await tester.pumpWidget(
      _host(
        hosts: const [PairedHost(hostId: _hostA, name: '客厅那台')],
        current: _hostA,
        picked: picked,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 点遮罩（sheet 之外的区域）取消。
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(picked, [null]);
  });
}
