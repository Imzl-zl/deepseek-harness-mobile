# Agent Note: `/` 候选菜单 —— 白名单随 `repo.info.commands` 过线，手机不抄第二份

Status: implemented

## Problem

斜杠命令的执行面 2026-10-23 就有了（`command.execute`，白名单 `/goal` `/plan`），但**输入框没有任何提示**：
用户得先知道这两个名字存在，还得记得前缀。占位符里那句"`/ 调用指令`"是唯一的线索。

为什么当时没做候选：白名单**只在连接器里**（`connector/src/handlers.ts` 的 `MOBILE_COMMANDS`），
手机侧要画菜单就得持有一份同样的名单 —— 那是**同一个事实两处表达**，电脑侧加第三条命令时
手机菜单里永远不会有它。当时的选择是"干脆不画"。

## Decision

**白名单随 `repo.info` 过线**（`commands: [...MOBILE_COMMANDS]`），手机只画电脑侧给的名字。

- 连接器：`repo.info` 多一个 `commands` 字段，**只在 `command.execute` 真的挂上时才报** ——
  报一个调不通的名字，就是契约 §5.7 表后那句"多一个必然失败的按钮"。
- 契约：§5.7 的 `repo.info` 行补一句（它现在同时是"版本 / 能力位 / 别名版本"与"命令白名单"的自报口）。
- 手机：`AppModel.refreshRepoInfo` 把 `commands` 落成 `slashCommands`（**空表 = 不知道**）；
  `DshComposer` 多一个 `slashCommands` 参数，候选只来自它。
- 判据（`slashQueryOf`）：整段文本**以 `/` 开头**且**还没有空白**。有空白 = 命令名打完了、后面在写参数；
  正文中间的 `/` 不算（DSH 的命令只在行首成立）。
- 形态：输入框上方一行胶囊（两枚时最优），**点一下就把 `/名字 ` 填进输入框**，菜单随即消失
  （文本里有了空格）。它读 `controller`（`ValueNotifier`），所以父层不必为每个按键重建整页。

## Alternatives considered

1. **手机里手抄 `['goal','plan']`** —— 最强理由：零契约改动、零连接器改动，当天就能画出来。
   被否：这正是本仓最 repeatedly 踩的那类坑（`memory.md` 教训 1/2/4/7：同一事实两个来源，漂了也不报错）。
   症状会很安静：电脑侧加了 `/compact`，手机菜单里没有，用户以为不支持。
2. **新开一个 `commands.list` 方法** —— 最强理由：命令将来会带描述/来源/参数提示，一个专门的方法更好长。
   被否：`repo.info` 已经是"能力自报"的既有口子（`methods` 就在里面），为一个字符串数组占掉封闭集里的
   一个方法名不划算；等真有描述要传时再加字段，形状不变。
3. **底部 sheet 弹候选** —— 最强理由：输入法弹着时 sheet 不会被键盘遮住，而候选行会被顶上去。
   被否：候选必须与输入框**同屏**（用户在打字的同一处看），sheet 会把输入框盖住；`tools.md` 那条
   "输入栏这一侧的触发点用 sheet"说的是**动作面板**（模型/权限/发送模式），不是候选列表。
4. **做键盘上下选择 / 参数提示** —— 被否：触屏没有方向键；参数提示是命令自己的 UI，DSH 的输入栏也没有。

## Consequences

- **收益**：两个命令从"记得住才用得上的功能"变成"打一个 `/` 就看见"；名单仍然只有一处。
- **代价**：老连接器（不报 `commands`）**没有任何菜单** —— 这是诚实的空态，不是"没有命令可用"。
  若将来要区分这两件事，得让老连接器报一个空数组（那要它升级）。
- **代价**：候选不区分"这台电脑上能不能用" —— 它来自 `MOBILE_COMMANDS`（本插件的能力），
  而 `/goal` 在没装 goal 服务的部署上会被 DSH 回 `matched:false`（手机按普通消息退化，已有路径）。

## 判据

- connector **616 → 617**：`repo.info 报斜杠命令白名单`（`deepEqual(['goal','plan'])`）+ 原来那条
  "方法不挂"补一句 `assert.equal('commands' in info, false)`。
- flutter **1151 → 1160**（新文件 `app/test/slash_suggestions_test.dart` 9 条）：
  `slashQueryOf` 三条判据；"打 `/` 出两枚（名单来自电脑侧）"；**"名单空 ⇒ 一枚都不出"**（不回落写死名单）；
  "打 `/p` 过滤到一枚"；"点一枚 ⇒ 文本变 `/goal ` 且菜单消失"；`repo.info` 有/无 `commands` 两种落表。
- **变异校验**：把候选的过滤条件改成恒真 ⇒ **恰好**"打 `/p` 过滤到一枚"红，其余 8 条仍绿（做完即还原）。
- boundary **363** 持平（没有新增 `lib/` 文件）、`dart analyze --fatal-infos` 0、`dart format` 0、
  `pnpm exec tsc --noEmit` 0、`pnpm build` 过。

## 代码入口回指

`connector/src/handlers.ts` 的 `MOBILE_COMMANDS`（唯一名单）与 `repo.info`；
`app/lib/data/app_model.dart` 的 `slashCommands`；`app/lib/ui/dsh_composer.dart` 的
`slashQueryOf` / `_SlashSuggestions`；装配点是 `app/lib/ui/chat_page.dart` 的 `DshComposer(...)`。
