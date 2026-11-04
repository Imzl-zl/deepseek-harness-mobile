# 键盘顶起输入栏：Android 15+ 不吃 `adjustResize`

- 日期：2026-11-04
- 触发：真机（Android 15+）反馈「输入框不能跟随输入法上移」，截图里输入栏被键盘整个盖住
- 状态：implemented（**真机待验**）

## 背景

`AndroidManifest.xml` 里写的是 `android:windowSoftInputMode="adjustResize"` —— 这是
Flutter 模板与绝大多数教程里的标准写法，在 API < 35 上确实"系统缩窗口、Flutter 顺着缩"。

Android 15（API 35）起 **edge-to-edge 强制开启**，`adjustResize` 被系统忽略：窗口不再
因为 IME 而缩小，而 Flutter 侧能否拿到 `MediaQuery.viewInsets` 取决于窗口是否还给引擎
报 IME insets。真机的结果是**两边都不缩**：键盘盖住输入栏，`_BottomBudget` 也算不出
"键盘在场"的那一档高度（它是用 `viewport.maxHeight` 算的，而 viewport 没变）。

## 决定

**两层一起改，"谁缩"只留一处**：

1. 清单：`adjustResize` → **`adjustNothing`** —— 系统不碰窗口，IME 以 insets 交给 Flutter；
2. `ChatPage`：`resizeToAvoidBottomInset: false` + `Padding(bottom: viewInsets.bottom)`
   —— 整页按 IME 高度上移一次，`LayoutBuilder` 的约束因此也是"键盘在场"的高度，
   `_BottomBudget` 自动跟着对。

## 被否掉的

- **只改清单**：如果引擎报 insets，Scaffold 自己就会缩，也能好。但那样"缩"同时存在
  系统（潜在）与 Scaffold 两处，任何一边行为变化都变成双缩或少缩 —— 输入栏会跑到
  键盘上方两倍高，或又掉回键盘后面。**判据只能有一处**。
- **只改页面**：清单还是 `adjustResize`，系统在某些 ROM 上仍会缩窗口，于是页面再缩一次
  → 双缩。
- **在 `_BottomBudget` 里减 `viewInsets`**：那是第二处判据，且只在"预算"这一侧生效，
  输入栏本身的位移还是没人管。

## 代价

- 如果某个 Flutter 版本的引擎**不报** IME insets，`viewInsets.bottom` 会是 0，效果与
  改动前一样（不会更坏）——那时要换第三种做法（原生 `WindowInsets` 通道）。
- 本机 **`flutter test` 跑不了**（Flutter 3.41.9 在 Windows 上复制 `sqlite3.dll` 到
  `build/native_assets/windows/` 时撞 errno 183，`flutter clean` 无效），所以这次只有
  `flutter analyze lib test` 全绿 + 真机待验。

## 验证

- `flutter analyze lib test` → No issues found。
- 真机：点输入框 → 键盘弹起 → 输入栏应贴在键盘上沿；键盘收起后回到原位；
  接管卡（审批/提问）在场时不应溢出（既有用例 `chat_takeover_wiring_test.dart`
  用 `FakeViewPadding(bottom: 1160)` 模拟过这个高度）。
