/// 「State 在 MaterialApp 之上时怎么拿到能用的 context」的回归。
///
/// ## 这个测试守什么
///
/// 2026-10-16 真机抓到一类 bug：`main.dart` 的 State 自己 `build` 出
/// `MaterialApp`，所以 State 的 context 在 MaterialApp **之上**，它的祖先里
/// 没有 Navigator / ScaffoldMessenger（那两个都由 MaterialApp 在**内部**创建）。
/// 第一版直接 `Navigator.of(context)`，真机上必抛
/// `Navigator operation requested with a context that does not include a
/// Navigator`—— 抽屉「归档」「设置」、连接 sheet、全部 toast 一碰就抛，
/// 而 widget 测试全绿（测试宿主挂在 Navigator 之下）。
///
/// 修法是 `navigatorKey`：导航操作走 `currentState`，sheet / SnackBar 走
/// `currentState!.overlay!.context`（overlay 是 Navigator 的子节点）。
/// 本测试把三种形状各跑一遍，钉住"哪种抛、哪种能用"。它测的是 Flutter 框架
/// 行为，**不依赖真机**——真机只负责发现，这里负责钉住。
///
/// 宿主的形状必须与 `main.dart` 一致：**State 的 build 返回 MaterialApp**
/// （而不是把 State 当 `home:` —— 那样 State 在 Navigator 之下，`Navigator.of`
/// 反而能用，测试会假绿）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('对照组：按钮自己的 context（在 Navigator 之下）一切正常', (tester) async {
    final errors = <String>[];
    await tester.pumpWidget(
      _RootApp(
        onPoke: (stateContext, ownContext, navKey) {
          try {
            unawaited(
              showModalBottomSheet<void>(
                context: ownContext,
                builder: (_) =>
                    const SizedBox(height: 120, child: Text('sheet-control')),
              ),
            );
          } catch (error) {
            errors.add('$error');
          }
        },
      ),
    );
    await tester.tap(find.text('tap'));
    await tester.pumpAndSettle();
    expect(errors, isEmpty, reason: '对照组不该抛：$errors');
    expect(find.text('sheet-control'), findsOneWidget);
  });

  testWidgets('State 自带的 context：Navigator.of 抛（病态1）', (tester) async {
    final errors = <String>[];
    await tester.pumpWidget(
      _RootApp(
        onPoke: (stateContext, ownContext, navKey) {
          try {
            Navigator.of(stateContext);
            errors.add('没抛（不该）');
          } catch (error) {
            errors.add('$error');
          }
        },
      ),
    );
    await tester.tap(find.text('tap'));
    await tester.pumpAndSettle();
    expect(
      errors.single,
      contains('does not include a Navigator'),
      reason: 'State 的 context 在 MaterialApp 之上，祖先里没有 Navigator',
    );
  });

  testWidgets('navigatorKey.currentContext：Navigator.of 也能用（记录在案）', (
    tester,
  ) async {
    // 这个形状**不抛**（2026-10-16 实测）—— 写在这里是为了防止后来者
    // 把它当病态"修"掉。真机上那次 `currentContext` 抛异常的记录是**旧构建**
    // （修复前的包还在跑），不是这个形状的问题。
    final errors = <String>[];
    await tester.pumpWidget(
      _RootApp(
        onPoke: (stateContext, ownContext, navKey) {
          try {
            Navigator.of(navKey.currentContext!);
          } catch (error) {
            errors.add('$error');
          }
        },
      ),
    );
    await tester.tap(find.text('tap'));
    await tester.pumpAndSettle();
    expect(errors, isEmpty, reason: 'currentContext 找得到 Navigator，不抛');
  });

  testWidgets('overlay 的 context：sheet / SnackBar 都能用（main.dart 的修法）', (
    tester,
  ) async {
    final errors = <String>[];
    await tester.pumpWidget(
      _RootApp(
        onPoke: (stateContext, ownContext, navKey) {
          try {
            final navState = navKey.currentState!;
            unawaited(
              showModalBottomSheet<void>(
                context: navState.overlay!.context,
                builder: (_) =>
                    const SizedBox(height: 120, child: Text('sheet-overlay')),
              ),
            );
            ScaffoldMessenger.of(
              navState.overlay!.context,
            ).showSnackBar(const SnackBar(content: Text('toast-overlay')));
          } catch (error) {
            errors.add('$error');
          }
        },
      ),
    );
    await tester.tap(find.text('tap'));
    await tester.pumpAndSettle();
    expect(errors, isEmpty, reason: 'overlay context 不该抛：$errors');
    expect(find.text('sheet-overlay'), findsOneWidget);
    expect(find.text('toast-overlay'), findsOneWidget);
  });
}

/// 复刻 `main.dart` 的 `_DshMobileAppState` 形状：**State 的 build 返回
/// MaterialApp**（State 因此在 Navigator 之上），按钮在 `home:` 里（在之下），
/// 点按钮时把 State 自己的 context、按钮自己的 context、导航键都交回给测试。
class _RootApp extends StatefulWidget {
  const _RootApp({required this.onPoke});

  final void Function(
    BuildContext stateContext,
    BuildContext ownContext,
    GlobalKey<NavigatorState> navKey,
  )
  onPoke;

  @override
  State<_RootApp> createState() => _RootAppState();
}

class _RootAppState extends State<_RootApp> {
  final navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      home: Builder(
        builder: (ownContext) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => widget.onPoke(context, ownContext, navigatorKey),
              child: const Text('tap'),
            ),
          ),
        ),
      ),
    );
  }
}
