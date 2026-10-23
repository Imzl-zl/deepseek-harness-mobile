# Agent Note: 交互应答者必须 `prepend`，否则被桌面转发监听器挡住

Status: archived（被 `.agents/notes/implemented/2026-10-23-interaction-as-gateway-client.md` 取代：
连接器不再是 host 的 waterfall answerer，`prepend` 与"顺序挡不挡桌面"这个问题一起消失）

## 被取代的原因（一句话）

`prepend` 解决的是"排在桌面转发监听器后面就问不到"，代价是**claim 之后桌面收不到请求**
（waterfall 只能有一个赢家）。改成 gateway 的 owner client 之后，同一条 pending 交互
**同时**投给桌面与手机，谁先答谁赢、其余收 `cancel` —— 那条链上不再有"顺序"这回事。

以下为原文，结论不改动。

## Problem

真机上「审批转手机」走到最后一步断了：电脑侧会话**停在 `approval/asked`**，
`approval/decided` 从不出现；手机上卡片出现了、点「允许一次」也发出去了
（`interaction.respond` 的 `callId` / `requestId: 'i:<callId>'` / 字面值 `"allowed-once"`
都对），卡片随之收束 —— 但电脑侧什么都没发生。

排查中两次被误导，都记在这里：

1. **读会话日志用单帧解压**：DSH 的 `session.v4.jsonl.zstd` 是**逐帧追加**的 zstd，
   而 Node 的 `zlib.createZstdDecompress()` / `zstdDecompressSync()` **只解第一帧**
   （61 KB 的文件只解出 211 字符的表头）。据此得出的"模型没照话执行"是**错的** ——
   按帧魔术字 `0x28B52FFD` 切段重解后，模型确实 `tool/call` 了提示词里那条命令。
2. **临时文件日志从未生成**：一度据此推断"连接器的应答者根本没被问到"——
   方向对，但**证据无效**。DSH 是 Electron 应用，它的 `appendFileSync` 与
   `console.error` 都到不了 CLI 的 stdout（实测：`2>&1 | Tee-Object` 只收到 3 行）。
   真要拿日志，得写到 DSH 自己能写的地方（例如它自己的 storage domain）。

## Decision

**两个交互应答者都带 `{ prepend: true }` 注册。**

依据是 Cordis 的 waterfall 语义：按注册顺序从队首依次问，`next()` 就是 `shift()`
（`vendor/cordis/src/events.ts:143`、`:255`：`prepend ? 'unshift' : 'push'`）。
而 DSH 里有一个**先注册且自己不答就不放行**的桌面应答者：
`packages/api/remotes/src/index.ts:57-75` 把 `approval/request` /
`user-questions/request` 转发给浏览器 GUI（`forwardWaterfall`），
它**每条 Client 流注册一次**（`api/remotes/README.md:47`）——
浏览器一挂上来就有一条监听器排在当时的队尾。

本插件的应答者是**异步**注册的（`index.ts` 的 `register-answerers` 排在 `open-store`
之后），所以只要浏览器比插件先连上，那条转发监听器就排在**我们前面**：
审批被挂在没人点的浏览器对话框上，我们永远问不到。

`prepend: true` 是 DSH 自己承认的逃生口 —— `user-approval/src/index.ts:270-274`
专门讨论它（"'never' policy ... a listener registered with `prepend: true` after this
service mounts would sit ahead of any gate LISTENER"），并把 `never` 的判定收进
**服务自己的 request 路径**（`:275`）。我们不破坏那条承诺：`never` 仍由 DSH 在
dispatch 之前决定，我们这边只做"不接管就 `next()`"。

## Alternatives considered

- **让插件同步注册应答者**（把 `register-answerers` 提到 `open-store` 之前）
  - 最强的理由：不动注册语义，改动更小。
  - 为何被否：`registerInteractions` 要 `ctx.on`，而它依赖的 `port` 又依赖
    `presence` / `interactionPort` —— 那些都建立在 `open-store` 之后。把注册提前
    等于把整条装配顺序倒过来，而**顺序仍然脆弱**：浏览器在任何时刻重连都会再插一条
    转发监听器，倒过来只是把赌注从"插件慢"换成"浏览器慢"。
- **只在 `approval/request` 上加 prepend**
  - 最强的理由：事故只在审批上复现，提问侧没证据。
  - 为何被否：`api/remotes` 用**同一个循环**转发两个事件（`index.ts:57` 的
    `for (const event of events)`），提问侧的暴露面与审批完全相同。只修一半等于
    留下一个同形状的坑。
- **检测到桌面应答者就放弃 claim**
  - 最强的理由：不改变注册顺序。
  - 为何被否：Cordis 没有"列出某事件的监听器"的公开面，检测不了；而且
    "有桌面应答者就不接管"会让手机端的能力取决于浏览器开没开 —— 那是隐性耦合。

## Consequences

- 收益：审批/提问真的会被问到；`connector/tests/interaction-answerer-order.test.ts`
  （新增）用一条按事件名分派的假瀑布钉住顺序，并给出变异面
  （去掉 `prepend` 立刻红）。
- 收益：假瀑布顺手修了一个真缺陷 —— 第一版**不按事件名分派**，于是两个应答者都
  prepend 之后 `approval/request` 被喂给提问应答者（`questions is not iterable`）。
- 代价：`prepend` 让我们排在**所有**桌面应答者之前，包括将来 DSH 自己加的。
  这是有意的：本插件的 claim 判据（presence + 档位）比"浏览器在不在"更接近用户意图，
  且不接管时立刻 `next()`，不挡死桌面。
- 代价：`interaction-face.ts` 的 `registerApprovalAnswerer` 是**另一份**带看护的
  应答者。它没有 prepend，而两份同时挂上去 waterfall 只会走先注册的那个
  （该文件头已警告）。生产只用 `registerInteractions`；若将来切换，
  **必须把 prepend 一起搬过去**，否则本条修的全部效果消失。
- 仍未修：真机用例里"挑一个没有未决审批的会话"是必要的 ——
  `flutter test integration_test` 会先卸载再装测试包 ⇒ 手机 sqflite 被清 ⇒
  `since = 0` ⇒ 连接器把整段历史重放给手机，手机会先答到上一轮留下的作废审批上
  （实测：一个会话里两条 `approval/asked` 相隔 10 分钟、`decided = 0`）。
