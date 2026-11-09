# Agent Note: #8 的文档漂移逐条判过 —— 十组落地、三条不成立

Status: implemented

## Problem

`refs/remotes/pr/8` 里有一批 `docs/`、`AGENTS.md`、`README.md` 的改动，一直没被评估过：
它们是"评审五条 + 文档漂移"的一部分，但那个分支落后 20+ 提交，其中一些改动的世界已经变了
（`app/packages/` 从来没建起来、图标资源没进 main、截图没重拍）。整段 cherry-pick 会
把文档写成假的；整段丢掉又会漏掉真正还在漂的事实（`app/` 被写成"只有主题层"、
"本仓库没有 CI" 之类）。

## Decision

逐条判"今天还成立吗"，成立的按**今天的数字与结构**重写后落盘，不成立的写清理由。
判据是：**文档里的每个断言今天能被仓库里的事实或一条命令证实**。

落地的（成立的）：

1. `AGENTS.md` §0：`app/` 不是"仅主题层"，七层（core / data / model / wire / theme / ui / platform）都在。
2. `AGENTS.md` §5：边界门禁只扫 `app/lib`（`app/packages` 不存在），并**删掉内联的条数**，改成指向 `tools.md` —— 条数只住一处。
3. `docs/AGENTS.md` 两行：`app-channel-client.md` 的"三端能力包"→"三端平台能力(`lib/platform/`)"；`app-platform-boundaries.md` 的"三个能力包"→"平台实现只住 `lib/platform/`"。
4. `docs/architecture.md` 四处：原型是**基线**（落地端同源）；`app/` 是七层产品实现；边界链接不再说"按能力切包"；新增平台落在 `lib/platform/<能力>_<端>.dart`。
5. `docs/cookbook/channel-bootstrap.md` 三处：开工顺序里的"能力包"→`platform/`；平台能力清单改到 `lib/platform/`；门禁注释去掉 `app/packages`。
6. `docs/design-and-tech-plan.md`：目录树补 `wire/`、`platform/` 的三段命名（端口 / 实现 / 兜底）、壳工程（含 `windows/` 桌面调试壳）、`mock/proto/`，删掉 `packages/`。
7. `docs/subsystems/app-channel-client.md` §5：改成"现状 + 目标形态"两段 —— 现状只有通知真的按端分叉，其余是一份纯 Dart 或跨端插件。
8. `docs/subsystems/app-platform-boundaries.md` §1/§3/§5：目录树同 (6)；C1 的落点改 `lib/platform/<能力>_<端>.dart`；平台分支白名单去掉 `packages/*`；"减弱动效"改 `lib/platform/`。
9. `docs/subsystems/remote-channel.md` 两处：推送能力落点写 `lib/platform/push_*`。
10. `README.md` 截图那一行：版本号跟仓库（`v0.2.13`），并把"截图与仓库同版本"改成"截图取自 v0.2.11（那之后这两屏没有可见改动）"。
    pr/8 的做法（直接把版本号改成它那一版）在这里**不能照抄**：这一版没重拍截图，改号会让那句话变假。判据：`git log v0.2.11..HEAD -- app/lib/ui/chat_page.dart app/lib/ui/settings_page.dart` 只有 `cae4546` 与本次批次，而 `cae4546` 在 `chat_page.dart` 加的是 4 行"把回调传给连接 sheet"的接线，没有可见改动；`settings_page.dart` 一次没动。

不成立的（不改）：

1. 启动图标 73% / 52%（pr/8 称 2026-11-04 真机量过）：**实测今天仓库里的资源不是这两个数** ——
   `mipmap-*/ic_launcher.png` 的非白内容宽 **85.4–86.5%**、`ic_launcher_foreground.png` 的 alpha 包围盒宽 **65.4–66.0%**
   （`PIL` 逐张量，见提交说明）。pr/8 描述的是另一次没有进 main 的资源重做，照抄会把文档写成假的。
2. `docs/subsystems/relay-accounts.md` 的 AhaSend 改写：现文案（`from` 是 `0t0.me`，不是 `dsh.0t0.me`）今天仍是事实，pr/8 的改写不增加事实。
3. `tools.md`：条数属于"计数归口"那批；其中"**本仓库没有 CI**"一句是事实错误（`.github/workflows/` 里 `ci.yml` / `release.yml` 都在跑），随那批一并修正。

另：`README.md` 门禁表去掉各家条数、改成指向 `tools.md` —— 成立，但它与"计数归口"是同一件事，合在那批做，避免两处各改一半。

## Alternatives considered

1. 整段 cherry-pick pr/8 的文档改动
   - 最强的理由：省掉逐条判断，而且那份改动是被评审过的。
   - 为何被否：它的世界已经变了 —— 图标百分比对不上今天的资源、截图版本号会写成假话、`app/packages` 早已不存在。文档的错误比文档的缺失更难发现，因为它们读起来同样自信。
2. 整段丢掉，只留一个"#8 的文档改动不适用"的结论
   - 最强的理由：零风险，不用逐条判断。
   - 为何被否：它里面有多条**今天仍在漂**的事实（`app/` 只有主题层、"没有 CI"、能力包路径），丢掉等于让这些错误继续躺在主文档里。
3. 只在 `memory.md` 记一句"#8 的文档改动不适用"
   - 最强的理由：最省事。
   - 为何被否：`memory.md` 是快照、会被覆盖；这类"判过但没采纳"的结论属于因果，必须进笔记。

## Consequences

- 收益：主文档里"`app/` 只有主题层 / `app/packages` / 三端能力包 / 按能力切包"这一族过时描述清掉了；`AGENTS.md` 不再内联门禁条数，少一处必然漂移的数。
- 代价：这一批只覆盖 `docs/`、`AGENTS.md`、`README.md`；`docs/` 里其余与 #8 无关的漂移仍在（例如 `files-page.md` §6 把"按后缀选渲染器"写在文件页，而那段其实是右抽屉预览的行为）。
- 代价：图标那条的判定依赖一次像素量测（Pillow 跑在仓库资源上），不是文档互相印证 —— 资源再换一次就要重量。
