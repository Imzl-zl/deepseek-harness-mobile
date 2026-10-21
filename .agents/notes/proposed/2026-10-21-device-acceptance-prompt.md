# 新会话提示词：隔离实例 + 真机验收（2026-10-21 批次）

> 用法：新开一个会话，把下面整段贴进去。
> 这一批的产品改动已经提交推送（`4c63d1e` / `a8cafb8` / `e9e9ff0`），本轮只验收。

## 提示词（整段复制）

```
项目：dsh-mobile（D:\sudy\myproject\dsh-mobile，Windows / pwsh）。

这批刚落地并推送：子智能体页对齐 Web（目录树 / 三态 / 指标 / 顶栏切换 / 只读框）
+ 侧栏置顶与组内重排。门禁已在 HEAD 全绿（flutter test 989、analyze/format 0、
verify-platform-boundary 313、connector 556、CDP 六项 + verify-drawer 25）。
**本轮只做真机验收，不改产品行为** —— 除非验收抓到真缺陷。

## 0 先读（别跳）

memory.md（现状 / 待办 / 已知缺口 / 真机纪律）、
.agents/notes/implemented/2026-10-21-subagent-catalog-tree-and-state.md、
.agents/notes/implemented/2026-10-21-sidebar-session-pin-and-reorder.md、
docs/subsystems/subagent-page.md，
以及 tools.md 的「真机联调」「隔离实例」「装 App」三节。

## 1 已知事实（省你半小时）

- 隔离根还在：D:\tmp\dsh-e2e（profile mobile-e2e、pair-payload.mjs、relay.config.json 都在）。
- **profile 补丁里的 relayUrl 写的是 192.168.2.47，这台机器现在没有这个地址**
  （当前 WLAN 192.168.110.79 / 以太网 192.168.2.41）。先改成环回
  `ws://127.0.0.1:8787/ws/connector` —— 这就是 memory 里「relayUrl 必须写环回」
  那条纪律的现场例子。改完**回读**（工作区外文件用编辑工具会假成功，见 tools.md）。
- connector 在 profile 里是指向本仓的 junction，DSH 读的是 `lib/index.js`：
  动过 connector 源码就先 `pnpm build`（本轮验收通常不需要改它）。
- 手机 `d61cf622` 在线；App 已装（com.example.dsh_mobile，lastUpdate 2026-10-20），
  **旧包不含这批改动**，必须重装；一律 `install -r` 保留数据。
- profile 的模型走 lightvela-free（免费），但仍花**真实轮次**：开跑前报"这次约几轮"
  并拿到准，不要闷头烧。

## 2 起环境（按顺序，逐条验证）

1) `cd connector; pnpm exec tsc --noEmit; pnpm build`
2) 改 `D:\tmp\dsh-e2e\profiles\mobile-e2e\cordis.patch.yml` 的 `relayUrl` → 环回；回读确认
3) 后台起中转：`node relay/src/main.ts --config D:\tmp\dsh-e2e\relay.config.json`
4) 后台起 DSH（**同一 shell 先设 DSH_HOME**）：
   `$env:DSH_HOME='D:\tmp\dsh-e2e'; dsh --profile mobile-e2e --port 63900 --no-open`
   记下启动打印的 web token
5) 硬证据（不看界面）：
   - `Get-NetTCPConnection -State Listen -LocalPort 8790` 必须是 `0.0.0.0`
   - `Get-NetTCPConnection -State Listen -LocalPort 8787` 有监听
   - 用 pair-payload 同款 cookie 读 `/api/dsh-mobile/status`，`relayUrl` 应是**当前 lanHint**，
     不是配置里的字面量
6) 出码：`node D:\tmp\dsh-e2e\pair-payload.mjs <web token> > D:\tmp\dsh-e2e\payload-1021.json`
   手机配对页粘贴（IME 会弹"剪贴板与常用语"，点"不同意"后输入框仍有焦点）。
   **先试直连**：App 若还能连上老配对就直接用，连不上再重配。
7) 装 App：
   `$env:ANDROID_HOME='D:\soft\android-sdk'; $env:JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-21.0.9.10-hotspot'`
   `cd app; flutter build apk --debug`
   `adb -s d61cf622 install -r build\app\outputs\flutter-apk\app-debug.apk`
   `adb -s d61cf622 shell svc power stayon true`
   **不要** `flutter install` / `flutter test integration_test/`（两者都会先卸载，配对凭据全没）。
8) 手机 WiFi 与电脑同网段（当前 192.168.110.x）。

## 3 造数据（子智能体）

让模型自己派：在会话里说「并行派两个子智能体做 X 和 Y，其中一个再派一个孙级」。

先查这个 profile 装了哪个 subagent 后端 —— `tool-subagent` 的 mode 由 backend 决定
（in-process 是可继续，ACP / codex / claude-code 是一次性或外部）。**只验造得出来的那一档**；
造不出就如实写「未造出」，**不许手改投影或 UI 伪造**。

## 4 验收清单（每条都要判据；涉及"会不会自己变"的截两帧对比）

A 子智能体面板（右抽屉「子代理」）
- A1 目录 = 当前会话的**直接子级**，不是一次拉全树
- A2 行 = 活动点 + 标题 + 「title · 可继续 · 正在运行 · 12秒」+ 右侧 `N tok` + 行尾展开（44dp）
- A3 展开子级 → 出现孙级（点了才加载）；已知空叶没有展开按钮
- A4 跑完：点变绿、文案「已完成」或「当前未运行」、**时长停住**（隔 30 秒再截一帧，数字不变）
- A5 顶栏「N 个子智能体」的 running 计数跟着子会话状态变（不是永远显示在跑）
- A6 一次性子会话（若造得出）：进入后输入栏变 54px 横向只读框、**键盘不弹**、点框不能输入

B 子会话导航
- B1 点行进入：顶栏左侧 ☰→←，标题是 `父会话 › 子级`；用长标题试一次，放不下时只留子级名
- B2 点标题开「切换子智能体」sheet；选兄弟切过去，← 仍在（不丢父会话）
- B3 系统返回键：在子会话里回父会话；不在子会话时正常退出
- B4 子会话里左缘仍能拖出抽屉（☰ 让位给 ← 是有意偏离，不是丢了入口）

C 侧栏置顶 / 重排
- C1 行长按 → 菜单四项（置顶 / 上移 / 下移 / 归档），**没有「删除」**
- C2 置顶 → 图钉出现、排到**本工作区分组**最前；别的分组不受影响
- C3 上移 / 下移只在同一置顶分区内；跨分区时菜单项灰且点不动
- C4 「未分组」桶（若有没归属工作区的会话）里上移 / 下移**不可点**
- C5 归档 → 从列表消失（进「归档」页可取消归档）
- C6 **重连后仍成立**：杀 App 进程重开（或停电脑侧 30 秒内再起），置顶与顺序不变。
  别停太久 —— 电脑侧名册清空会让手机回配对页（memory 待办 4）

D 可选（仍是未验项，时间够再做）
- 附件：＋ → 照片 → 芯片 → 发送 → 附件计数
- 历史翻页：滚到顶多出几轮（快照一页 100 条，要造够真历史）
- 异常结局 / 重试 / 压缩标记

## 5 证据纪律

- 截图：`adb -s d61cf622 exec-out screencap -p > D:\tmp\dsh-e2e\shots-1021\<名>.png`；
  **不进仓库**。
- 每次要坐标之前先 `adb shell uiautomator dump` 拿**当前**树；坐标不能跨状态复用（踩过三次）。
- 每条记：操作 → 看到什么 → 判「过 / 不过 / 未造出」。不写"应该没问题"。

## 6 收尾

- 抓到真缺陷：先按 systematic-debugging 找根因（不许兜底、不许吞异常），补回归测试再修；
  修完把门禁跑一遍（命令见 memory 的「门禁」表），代码与决策笔记同批提交。
- 全是绿的：更新 memory.md 的待办 5 / 6 / 7；把验收状态写进
  docs/subsystems/subagent-page.md 的「验证」一节（或新开一篇 implemented 笔记）。
- 最后给一张表：A1..D 逐条「已验 / 不过 / 未造出」+ 截图文件名。

## 7 硬规则

- 不猜：Flutter 行为 `node app/tools/flutter-api.mjs <符号>`；DSH 行为 `packages/...:行号`。
- 改源码只用编辑工具；**工作区外文件（D:\tmp、~/.dsh）相反**：shell 写 + 回读 + 看 mtime。
- 不在默认根另起实例；不动 `~/.dsh`；不用 `flutter install`。
- 提交前 `git status --short` 只剩有意改的文件。
```
