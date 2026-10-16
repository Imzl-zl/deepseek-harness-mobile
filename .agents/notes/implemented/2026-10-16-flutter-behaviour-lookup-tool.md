# Agent Note: Flutter 行为查证工具（`app/tools/flutter-api.mjs`）+ 路径门禁扩到 `app/tools/`

Status: implemented

## Problem

2026-10-16 做手机端抽屉 / 手势 / 顶栏那一轮，用户三次纠正，其中两次的根因是同一个：
**Flutter 的行为我没有先查就动手**。被点名的原话："你完全在瞎猜"、"你最好自己查查资料，肯定能实现"。

当时的实际代价（都是可避免的）：

| 我当时的判断 | 事实（本机 SDK 3.41.9 源码） |
|---|---|
| "`endDrawer` 可能不支持边缘拖动，得自己写" | `scaffold.dart:2952`：endDrawer 也吃 `edgeDragWidth`；`:1717`/`:2953`：`endDrawerEnableOpenDragGesture` 默认 `true` |
| "`drawerEdgeDragWidth` 只能作用于整条边（所以没法只留上半屏）" | 对 —— 但结论应该是"上半屏换别的法子"，而不是"自己写一套不跟手的手势带" |
| "系统返回手势只能靠把手内缩躲开" | 有官方 API：`View.setSystemGestureExclusionRects`（Android 10+，每条边上限 200dp） |

而本仓对 DSH 早有一条硬规则：**引用 `packages/...:行号`，查不到写「未找到」，禁止猜**。
Flutter 侧一直没有对应的东西，于是"猜"在这里变成了默认动作。

## Decision

**给 Flutter 也立一条可机械执行的查证入口**，并与 DSH 同一条纪律：

1. **新增 `app/tools/flutter-api.mjs`**：直接查**本机 SDK 源码**（版本确定、逐行可引），
   用法 `node app/tools/flutter-api.mjs <符号|正则> [--ctx N] [--limit N] [--all]`。
   引用写成 `packages/flutter/lib/src/...:行号`。SDK 根从 `FLUTTER_ROOT` 或 `where flutter` 推，
   **不硬编码盘符**。
2. **顺序表写进 `tools.md`**（「Flutter 行为查证」一节）：① 本机 SDK 源码 →
   ② `api.flutter.dev` 类文档（`firecrawl_scrape` 可抓，页面里 "View source code" 直链到同一份源码）→
   ③ `docs.flutter.dev` 专题 → ④ flutter/flutter 的 issue/PR → ⑤ **真机实测**
   （ROM 手势 / 输入法 / 权限这类**框架外**的行为，文档不保证，量了才算数；实测数据写进笔记）。
3. **根 `AGENTS.md` §6 加一条**：「Flutter 行为不许猜」——动 UI / 手势 / 布局前先跑那个脚本。
4. **顺手把 `verify-tool-paths.mjs` 扩到 `app/tools/`**，并补上真正的那条规则
   「禁任何盘符字面量」——原两条只拦 `file:///X:` 与 `C:\sudy`，拦不住我在新工具里写
   `'D:\soft\flutter'` 这种字面量（变异校验：去掉豁免标记立刻红，恰好那一行）。

## Alternatives considered

1. **找个 Flutter 的文档 MCP 顶上**（用户问的就是这个）。
   - 最强的理由：如果有现成的 MCP，就不用自造工具。
   - 为何被否：实测 `deepwiki` MCP 对 `flutter/flutter` **不可用**（被 Vercel 人机校验挡住，返回验证页）；
     `serena` 能指向 SDK 但会切掉用户另一个项目的激活态；pub.dev 上的 `android_gesture_exclusion`
     只解决手势那一件事。**本机 SDK 源码才是最全、版本最准、还能逐行引用的那个"文档"**。
2. **只写进文档，不做工具**。
   - 最强的理由：零成本。
   - 为何被否：这轮已经证明"我记得要查"不可靠；一条命令比一段叮嘱可执行得多。
3. **让路径门禁对新工具睁只眼**（只扫 `mock/proto/tools/`）。
   - 为何被否：新工具恰恰是最需要这条门禁的地方（它要去找 SDK 根）。
4. **盘符例外一律修掉**（把 DSH 默认路径改成必须传 `DSH_SOURCE`）。
   - 为何被否：那两处是**合理存在**（一个是可覆盖的默认值、一个是截图夹具里的假路径文本），
     改成硬性要求只会增加日常摩擦。所以采用"**例外必须显式**"：紧挨着的注释块里标
     `allow-hardcoded-path: <原因>`，diff 里看得见、留得下档。

## Consequences

- 收益：「Flutter 行为先查再写」从"靠记性"变成"一条命令 + 一条根规则"；
  `verify-tool-paths` 现在覆盖 `app/tools/`（19 个脚本）并真的拦盘符字面量；
  查询结果自带 `file:line`，可以直接抄进代码注释与笔记（本轮注释里那批
  `material/drawer.dart:667-709`、`scaffold.dart:2946-2953` 就是这么来的）。
- 代价：多一个脚本要维护；SDK 换版本后行号会漂 —— 所以引用要按"符号 + 行号"写，
  并在改动时顺手核对（与 `docs/` 的引用纪律一致）。
- 边界：这个工具只能回答"框架怎么实现的"；**框架外的行为（OEM 手势、MIUI、输入法、权限）照样得真机量**。
  这轮那条最贵的教训正是量出来的：同一坐标 x=1070（≈2dp），不报排除 → App 被系统退回桌面；
  报了 → 抽屉正常开；而下半屏（y≈610dp）仍归系统。