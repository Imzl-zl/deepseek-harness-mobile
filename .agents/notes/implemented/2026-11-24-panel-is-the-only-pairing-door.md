# Agent Note: 出码只有一个门 —— 插件面板，删掉 `/dsh-mobile-pair`

Status: implemented

## Problem

用户 2026-11-24（截图里 DSH 会话的命令补全列出了 `dsh-mobile-pair`）：

> 还有为啥桌面/命令有个生产二维码命令这不需要吧，谁在会话生成？我肯定在插件界面啊

它不只是"多一个入口"。同一天查出来的事实是：**两个入口对同一次出码给出不同结论** ——
面板走 `planPairingOffer`（两条腿都没有就拒绝），斜杠命令直接调 `offerForScanning`
（绕过判据，两条腿都没有时照样"成功"返回一张 `路径：无` 的码）。同一件事两处判据，
在用户最需要准确的时刻各自说一句不同的话。

命令那一侧本来就是妥协产物：DSH 的 `CommandResult` 只能回文本
（`packages/interaction/commands/src/types.ts:34`），二维码只能由面板画。于是命令
能给出的"码"永远是载荷 JSON 文本，扫不了。

## Decision

**出码的唯一入口是插件面板（`POST /api/dsh-mobile/pair`）。删掉 `dsh-mobile-pair`
斜杠命令、它的注册/注销路径，以及只为它存在的 `offerForScanning`。**

准入门槛（可机械判定）：

1. `connector/src/index.ts` 里不再有 `ctx.commands.register`；`unregisterPairingCommand`
   一并删除。`grep -r 'dsh-mobile-pair' connector/` 必须为空。
2. `pairing-offer.ts` 只导出 `planPairingOffer` / `issuePairingOffer`；
   `offerForScanning` 与其 `OfferResult` 类型删除（没有第二个调用方就没有抽象）。
3. 契约不变：出码仍是 `POST /api/dsh-mobile/pair`，仍只回 `svg / expiresAt /
   lanOnly / lanAvailable`，不回 payload。
4. `tools.md` 与 `docs/` 里出现 `/dsh-mobile-pair` 的地方改掉；`commands/execute` 的工具
   示例换一条真实命令（保留"怎么用 RPC 跑斜杠命令"的知识点，不再暗示出码走命令）。

## Alternatives considered

1. **两个入口都留，命令也走 `planPairingOffer`**
   - 最强的理由：命令行出码对脚本化验收有用（`docs/cookbook/next-session-interaction-to-phone.md`
     就是用浏览器自动化跑 `/dsh-mobile-pair` 取二维码的）；改一处判据就能消掉不一致。
   - 为何被否：命令**给不出二维码**（只能回 JSON 文本），留着它的唯一价值是自动化，
     而自动化可以直接 `POST /api/dsh-mobile/pair` 拿 SVG（面板走的就是这条路）。
     用户的原话也直接否掉了它存在的理由：「谁在会话生成？我肯定在插件界面啊」。
2. **命令保留但改名成 `/pair` 之类更短的名字**
   - 最强的理由：短、像宿主自带。
   - 为何被否：问题不是名字，是"第二个入口"。改名只会让不一致更难发现。
3. **命令只在没有面板的部署里注册（按能力位判断）**
   - 最强的理由：老宿主没有面板 slot 时仍能出码。
   - 为何被否：这个插件**只服务 DSH 的面板 slot**（`admin/mount.ts`），没有"没有面板"
     的部署；为不存在的部署保留一条判据就是新增边界。

## Consequences

- 收益：`planPairingOffer` 重新成为"什么时候能出码"的唯一判据；两个入口互相矛盾这件事
  在结构上不可能再发生。
- 代价：不能在会话里敲命令拿码。要出码必须打开插件面板（一步点击，二维码还能直接画出来）；
  已经写进旧 cookbook 的自动化流程要改成 HTTP 调用 —— 这批文档与代码同批更新。
- 代价：`offerForScanning` 里那几句"路径：…"的正面文案随之消失。那些话的价值
  （告诉用户出门能不能用）由面板承担：面板在二维码旁说 `lanOnly` / `已登记 / 未登记`，
  另外新增「此刻可拨：…」一行。
