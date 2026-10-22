# 新会话提示词：抽屉回归 + 工具行扫光截图 + 轮组方案（2026-10-22 晚）

> 用法：新开一个会话，把下面整段贴进去。
> 上一轮产物已提交：`4f52a65`(G) / `6f30f11`(F) / `00f69a1`(A) / `38f0661`(C) / `376a575`(B) /
> `d11e935`(D) / `f5592af`(E) / `fab945d`(H) / `83c3b50`(归档) / `cff3116`(字号两层倍率) /
> `d9d2b42`(更正"最早/最新"那条)。

## 提示词（整段复制）

```
项目：dsh-mobile（D:\sudy\myproject\dsh-mobile，Windows / pwsh）。中文回复。

## 0 先读（别跳）
- memory.md（现状、"下一步"、已知缺口 8–11、门禁表）
- tools.md 的「真机联调」「隔离实例」「装 App」几节 + Pitfalls（尤其"改源码只用编辑工具"）
- docs/subsystems/type-scale.md（字号两层倍率：系统 × App 四档，刚定的）
- .agents/notes/implemented/2026-10-22-global-ui-scale.md（为什么是"等比放大全部"，
  而不是"只放大内容"—— 后者被真机退回）
- docs/subsystems/running-cues.md 里"在跑吗"的口径（② 要补的图按它判）

## 1 现状（省你半天）
- 八件事（G 输入法 / F 抽屉拖拽 / A 运行中动效 / C 字号 / B 每步视图 /
  D 设置三行 / E 电脑侧版本 / H workspace.createdAt）全部落地，每件一个提交 + 一篇笔记。
- 门禁基线：flutter **1080**、connector **586**、relay **86**、protocol **486·26·49**、
  platform-boundary **349**（96 个 Dart 文件）、icons、tool-paths、analyze+format **0**。
- 手机上装的是含"界面字号四档 + 图标跟随"的 debug 包；系统 font_scale 1.0，App 内是「标准」。
- 隔离实例：$env:DSH_HOME='D:\tmp\dsh-e2e'；dsh --profile mobile-e2e --port 63900 --no-open；
  容器中转 relay-e2e（8787）；adb reverse tcp:8787 tcp:8787。
  **注意**：`docker restart` 或重开 adb 之后 8787 的 host 侧监听与 reverse 都可能丢，
  先查这两样再怪 App。
- 手机 d61cf622；截图到 D:\tmp\dsh-e2e\shots-2026-10-22\（不进仓库）。
- 字号那题的结论别重开：两层倍率（系统 × App 四档 0.9/1.0/1.15/1.3），
  由 MediaQuery.textScaler 等比放大全部文字；"只放大内容"已否决（对比会从 1.27 拉到 2.0）。

## 2 本轮三件（按顺序；每件一个提交 + 一篇决策笔记）

### ① 修回归：从设置页返回后抽屉仍开着（真回归，优先）
真机复现三次：☰ → 设置 → 返回，回到聊天页时抽屉仍是开的。
`main.dart` 的 `_openSettings` 里在 push 前有一句 `maybePop()`（本意"先收抽屉再 push"）没生效。
先查 `ModalRoute.popDisposition` / `didPop`（packages/flutter/lib/src/widgets/routes.dart:942-966）
在"pop 后立刻 push"的时序里有没有把 local history entry 拿掉；也看 `isDrawerOpen` 的时序。
判据：返回后 `Scaffold.isDrawerOpen == false`；补一条 widget 级测试（不要只靠真机）。
另一条相邻行为是 G 的收输入法（`dismissInputFocus()`），别一起改坏。

### ② 补证据：工具行自己的扫光截图（功能已在，缺图）
`ToolCard.running` + `DshShimmer` 已有，单测 3 条钉住；缺的是真机截图 ——
免费渠道的思考阶段 1–2 分钟，工具执行的那 20–120 秒总落在采样间隙。
建议：让它跑一条 `Start-Sleep -Seconds 90`（或循环 sleep），执行期间连拍 3–4 张；
判据：工具行文字上有扫光带、且只有它在动。拍不到就明确记"仍缺"，
**不许拿运行条那张冒充**。

### ③ 轮组（大件：先写方案，别顺手实现）
memory.md 待办 #1：Web 是"已完成，用时 X ⌃"可展开的轮组，手机是平铺 —— 少了一层结构。
先出一篇 .agents/notes/proposed/ 的方案（结构、折叠默认态、与 trajectory 投影的关系、
工作量与风险、对"工作步骤收起时机"那行设置的影响），用户点头再动手。

## 3 硬规则（违反会被退回）
- 改源码只用编辑工具，不用 shell 字符串替换（已两次事故）。
- 引用 DSH 行为给 packages/...:行号；查不到写「未找到」，禁止猜。
- 改 app/lib 后跑 boundary + icons；改 connector/src 后 tsc + build + test；全绿才提交。
- 一件一提交 + 一篇笔记；docs/ 的现状事实同步更新（docs 只写当下事实，历史进 notes/）。
- 真机证据放 D:\tmp（不进仓库），但笔记与回复里要给出文件名与判据。
- 已定的题别重开：字号（见上面那篇笔记）、"在跑吗"走事件流而不是 session.list、
  D 的设置面只有三条 (ns,path) 可写。

## 4 遗留清单（memory.md 已知缺口 8–11）
8. 工具行扫光没有真机截图（就是本轮 ②）。
9. 设置页返回后抽屉仍开（就是本轮 ①）。
10. workspace.createdAt 的"空工作区当最近"只有单测 —— 真机总有当前会话，够不到那条分支。
11. ~~字号局部刻度观感差~~ 已修（两层倍率）。
```

## 说明（给用户，不用贴）

- ① 是真回归且代价小，放最前面；② 只补证据、不动代码；③ 是结构性改动（"少了一层结构"），
  必须先方案后动手。
- 如果 ① 查下来是 Flutter 的 `Navigator` 时序而不是我们的 bug，也要写成笔记：
  那说明"先收抽屉再 push"这个做法本身不成立，得换一种（例如 push 之后自己 `closeDrawer()`）。
