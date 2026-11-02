# Agent Note: 会话点"运行中"转圈 + 抽屉头部标题可省略（屏占比/大字号）

Status: implemented

## Problem

用户两句话，指的其实是两件事：

1. 「桌面的运行中的会话前面有个转圈圈…点击进入会话就消失，这个细节 APP 有没有？」
   —— 状态链本身已经是**桌面推送**的（`connector/src/index.ts:1185-1189` 把宿主的
   `api-session/status` 转成 `status` 帧广播；`connection-scope.ts:204-207` 发；
   手机 `session_rows.dart:59-63` 只更新 `_running`，完成点与"点进去消失"都是
   **本地派生**，零请求）。缺的只是**画法**：桌面 `StateDot.tsx:51-68` 对 ongoing
   画 SVG spinner（轨道 + 弧，14px），手机是 8px 静态蓝点。
2. 「还要考虑手机屏占比的问题」—— 在 304dp（`Drawer` 默认宽）下量抽屉，
   头部那行 `DshBrandMark + kAppName + 新建` **溢出 56px**：
   `Text(kAppName)` 没有 `Expanded`、没有省略，靠 `Spacer` 推着走。
   真字体下平时够宽，但**界面字号调到「大 / 特大」**（本仓设置页有这个开关）
   就会撞上同一处 —— 这跟屏幕长宽比无关，是"宽度被内容吃穿"。

## Decision

1. 新增 `app/lib/ui/session_dot_view.dart`：`SessionDot.ongoing` 画 14px
   轨道（22% 透明度）+ 四分之一弧、1.1s/圈；其余三态仍是 8px 实心点。
   行首用固定 14px 占位，避免"跑起来那一刻"文字左右跳。
   **只有 ongoing 占 ticker**（其余三态 stop），所以不干扰 `pumpAndSettle` 之外的场景。
2. 抽屉头部标题改 `Expanded + maxLines:1 + ellipsis`，去掉 `Spacer`。
   判据：`screen_fit_test.dart` 在 360×640 / 390×844 / 412×915 三档下
   `takeException()` 为空、抽屉高度 = 屏幕高度、宽度 = 304。
3. 测试断言从"颜色"改成"语义"（`SessionDotView.dot`），并加两条：
   ongoing 那一格里有 `CustomPaint`（转圈），done 那一格没有（实心点）。

## Alternatives considered

1. **用 `CircularProgressIndicator` 当转圈**
   - 最强的理由：一行代码，框架自带。
   - 为何被否：它带自己的厚度/留白与主色（与 DSH 的 accent 不是一个值），
     会在抽屉里长出第二套视觉语言；12 行 `CustomPaint` 就能照桌面画准。
2. **让手机自己算运行态（最后一条 `turn/start` 未配对 `turn/end`）**
   - 最强的理由：不依赖宿主推送。
   - 为何被否：那是**本仓删掉过的旧做法**（`session_rows.dart` 文件头记着），
     宿主已有 `agent/status` 推送，自己数会与它分叉。
3. **屏占比只靠"多档截图目测"**
   - 最强的理由：不做新测试。
   - 为何被否：溢出不看断言就看不见（wallpaper 透出来才明显）；
     `screen_fit_test` 三档 + `takeException()` 是可机械判定的。

## Consequences

- 收益：运行中"在动"看得见了，与桌面一致；大字号下抽屉头部不再溢出。
- 代价：抽屉行首占位从 8px 变成 14px（整列文字右移 6px，已被现有用例覆盖）。
- 代价：ongoing 那一行有一个常驻 ticker（一屏最多几个在跑的会话，代价可忽略）。

## 判据

- `flutter test`：**1676 项**全绿（新增 `screen_fit_test` 3 条 + 抽屉语义断言）。
- `dart analyze --fatal-infos lib test`：0。
- `node app/tools/verify-platform-boundary.mjs`：712 项通过。

## 代码入口回指

- `app/lib/ui/session_dot_view.dart`（画法）、`app/lib/ui/session_drawer.dart`
  的行首槽位与头部标题、`app/test/screen_fit_test.dart`（三档不溢出）。
