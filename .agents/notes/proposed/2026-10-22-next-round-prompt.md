# 新会话提示词：轨迹页重做 + D2 refetch + 分组落点（2026-10-22 批次）

> 用法：新开一个会话，把下面整段贴进去。
> 上一轮（2026-10-21 深夜）的产物已提交：`6c3a17f`（删轨迹页假入口）、
> `3ab5001`（D1 通过 + 静态审查）、`3af61e3`（H2 归档闭环）、`51f6fe6`（抽屉拖动 + 锚定浮层）。

## 提示词（整段复制）

```
项目：dsh-mobile（D:\sudy\myproject\dsh-mobile，Windows / pwsh）。

## 0 先读（别跳）
- memory.md（现状 / 待办 0 与 10 / 已知缺口 7 / 门禁表）
- tools.md 的「真机联调」「隔离实例」「装 App」「容器镜像」四节 + Pitfalls
- .agents/notes/proposed/2026-10-22-trajectory-page-parity-and-mobile-fit.md（本轮的主清单）
- docs/subsystems/subagent-page.md §7.2 / §7.3（上一轮验收与静态审查的结论）
- docs/cookbook/relay-on-a-server.md §8（容器中转的本机验证与防火墙坑）

## 1 现状（省你半天）
- 仓库 HEAD 6c3a17f。门禁基线：flutter **1010**、connector **563**、relay **86**、
  protocol **486·26·49**、platform-boundary **318**、CDP 六项（proto 31 / authz 18 /
  settings 28 / tasks 53 / picker / drawer 25）、analyze/format 0。
- 手机上那个包是 2026-10-21 23:37 的 debug 包：**轨迹页那行死 chip 已经在仓库里删了，
  但没上机**；D1/H2 是在那个包上验的。
- 隔离实例：`$env:DSH_HOME='D:\tmp\dsh-e2e'`，`dsh --profile mobile-e2e --port 63900 --no-open`。
  容器中转 `relay-docker`（8787，配置 D:\tmp\dsh-e2e\relay-docker.config.json）**还在跑**；
  手机经 `adb reverse tcp:8787` + 环回 relay 配对着。profile 里已有
  `subagent.maxDepth: 2` 与 `llm-pi-ai` 的 `input: [text, image]`（备份 .bak-2323 / .bak-0031）。
- 手机 d61cf622（Android 16）。装包一律 `flutter build apk --debug` + `adb install -r`，
  先 `adb shell svc power stayon true`；截图到 `D:\tmp\dsh-e2e\shots-1022\`（不进仓库）。

## 2 任务（按顺序，每条都要判据）

### A 轨迹页重做（清单 P0→P2，**先定方案再动手**）
1. **修「轨迹条目」sheet 的溢出**（用户给了截图：黄黑条纹 + `RIGHT OVERFLOWED BY 474 PIXELS`，
   「结果」两字被挤成竖排）。根因已定位：`_showTraceSheet`（chat_page.dart:1412-1431）
   用 `DshKeyValue` 摆长英文，而它的 value 是**无约束 Text**（dsh_sheet.dart:164-171）。
   判据：390dp 宽下打开该 sheet，`flutter analyze` 无新告警 + 截图里**没有** overflow 条纹，
   「结果」标签横排、正文按词换行；给 `DshKeyValue` 加可选 `multiline`（默认不变）。
2. **三个视图只留有数据源的**：`轮次`（turnOutline 已有）保留；`时长`/`调用` 先不做 ——
   **不许摆假 chip**（上一轮刚删掉一行）。若要做「时长」，先决定数据从哪来：
   Host 侧加"每步起止"投影，或用每轮 `turnSummary` 的时长做"每轮一条迷你条"。
   **决定写进 docs 再写代码**。
3. **移动端适配**（用户原话"web 的我看了电脑屏大，你这个还需要看看怎么适配移动端，
   考虑屏幕空间，和用户体验还有美观"）：390dp 竖屏不要横滑 640px 的甘特；
   层级建议"轮次为主，其余点进去"。改完在 411dp 与 360dp 两个宽度各截一张。

### B D2：`refetch` 标记被跳过 ⇒ >1 MiB 条目静默缺失（**真缺陷**）
- 现状：`sync_client_impl.dart:956` 把 `{kind:'refetch', seq, bytes}` 直接跳过，
  从不调 `session.refetch`。连接器侧完整（session-page.ts + refetchThresholdBytes 1 MiB）。
- 做法：`SyncClient` 加 `refetch(...)`，收到标记时补取并合并进会话。
  **坑**：全仓 24 个 `implements SyncClient` 的替身不继承默认方法（tools.md 记着），
  要么先给接口一个退化默认实现 + 只改真实现，要么逐个补 —— 选哪个都写进笔记。
- 判据：单测覆盖"标记 → 调 refetch → 条目出现"与"refetch 失败 → 如实报错不吞"；
  真机上造一条 >1 MiB 的条目（或把 `refetchThresholdBytes` 调到 1 做实验）看它出现。

### C 分组落点：手机建的新会话永远进「未分组」
- 现状：`session.create` 不传 `workspaceId`，宿主不把会话记进工作区账本；
  而 blank 会话默认不列 ⇒ 手机建的会话在抽屉里永远是「未分组」。
- 先查 DSH 语义（`workspace-controller` 与 `session-controller` 的 create 参数），
  再决定：手机新建时带当前工作区？还是给一个"未分组"解释？**别猜**。

### D 打一次包 + 真机验收
- 只打一次、只装一次；在这个包上验：A 的溢出与布局、B 的 refetch、C 的分组、
  以及上一轮欠的 **E3 拖动排序**（需要"同一工作区下两条可见会话" —— 用 RPC
  `session/create` 带 workspaceId 造两条、各发一句让它非 blank）。
- 真机纪律：每次要坐标先 `uiautomator dump`；长文本走剪贴板（`adb shell input text`
  会吃引号）；左缘拖抽屉要从 `x≈40, y≈300` 起手（落在 gesture-exclusion 的上半屏带）。

## 3 硬规则
- 改源码只用编辑工具；工作区外文件（D:\tmp、~/.dsh、服务器 compose）用 shell 写 + 回读 + 看 mtime。
- 不猜：DSH 行为给 `packages/...:行号`；Flutter 行为先 `node app/tools/flutter-api.mjs <符号>`。
- 造数据要花真实模型轮次：开跑前报"这次约几轮"并拿到准。
- 门禁全绿才算完：flutter / connector / relay / protocol 三条 / boundary / CDP 六项 / analyze+format。
- 提交信息避免反引号，长消息写临时文件用 `git commit -F`。

## 4 产物
- 一份最终 debug APK（装在 d61cf622 上），A/B/C/E3 都在它上面验过。
- 一张总表（已验 / 不过 / 未造出 / 未验（原因））+ 截图目录。
- 一次提交（代码 + 笔记同批）+ 门禁输出（每条一行）。
```
