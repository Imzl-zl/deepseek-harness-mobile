# Agent Note: `$events` 换代不撤在途 claim —— claim 挂在挂载上，不挂在传输上

Status: implemented

## Problem

`connector/src/dsh/interaction-client.ts` 原来在一条 `$events` 流走到头时（`api/remotes`
重新注册事件源 / peer 失效 / 任何让 `for await` 结束的原因）**撤掉这一代全部在途 claim**，
并 `await Promise.allSettled([...tasks])`：

```ts
} finally {
  generation = null
  clientId = null
  for (const eventId of [...deliveries.keys()]) cancelDelivery(eventId)  // ← 撤 claim
  await Promise.allSettled([...tasks])                                    // ← 等人答完才重连
}
```

后果是一段**真窗口**：手机在这一拍点答 → 没有 claim → DSH 回 `false` → 我们回
`interaction/not-pending` → App **撤卡**，而桌面那张卡**还在**（gateway 没结算它）。

形状与已经删掉的 A4 一样：**把一个连接事件翻译成一条语义终态**。

## Decision（已落地）

1. **一代流结束不撤 claim，也不 await 挂着的人。** `deliveries` / `tasks` 的寿命是**挂载**：
   只有 `cancel` 帧与 `dispose()` 能撤 claim。与 DSH 同构 ——
   断线只撤投递、不结算（`packages/api/gateway/src/index.ts:717-721`），
   新 client 上来把在途事件**重投**（`:571`），`eventId` 相同就跳过、不重复 claim。
2. **换代窗口里答的答复不丢。** `reply()` 在 `clientId === null` 时**等下一代的 `ready`**
   （挂载级的一个 promise），拿到新 `clientId` 再 POST；`dispose()` 把它解成空串 ⇒
   留声并放弃。这是**补通道**（传输短暂不在），不是替宿主决定：结果要么发出去，
   要么在卸载时放弃；不重试、不发明 outcome。
3. `dispose()` 才是终态：解 ready → abort 这一代 → 撤全部在途 claim → 等分批任务 → 释放 peer。

## 判据（0 个真机回合）

- **connector 615 → 616**：`interaction-client.test.ts`
  - "换代窗口：还在等手机时流断了 → **不撤 claim**"（并断言"要撤只有两条路：gateway cancel / 卸载"）；
  - "换代窗口里手机答了 → 结果等下一代 `ready` 再用新 clientId 发出去（不吞掉）"（新）；
  - "流断开 → 退避重连；在途 claim 不断，重投的同一 `eventId` 不造第二条 claim"（改写：原来断言 `pending === 0`）。
- **变异校验两组**（做完即还原）：
  ① 在 `finally` 里恢复"撤 claim" ⇒ **恰好 3 条红**（上面那三条）；
  ② `reply` 不等 `ready`（`clientId ?? ''`）⇒ **恰好 1 条红**（"换代窗口里手机答了"）。
- 证据全部在 DSH 源码与 DSH 自家用例上：`api/gateway/src/index.ts:571,685-689,717-721`、
  `gateway-stream.host.spec.ts:1320`（fan-out + 第一个 result 结算）、`:1402`（全员 next 才交还）。

## 代价（如实）

- **新的一处挂载级内存**：在途 claim 跨代存活。风险是"流一直连不上、claim 永远挂着" ——
  但那正是 DSH 的语义（没人答就一直等，契约 §6.2），不是新边界。
- **残余窗口**：如果"换代期间**别人**先答了"，gateway 不会再投递这条事件，
  我们也就收不到 `cancel` ⇒ 那条 claim 变成**陈旧**（手机再答一次会得到 `ok` 但结果被
  gateway 拒，留一声 warn）。**不会更坏**：手机那张卡由会话事件关
  （`approval/decided` / `tool/result`），与我们的 claim 无关；陈旧 claim 在下次作答或卸载时消失。
  这条窗口没有加计时器去兜 —— 加就是自创边界。
- **"等下一代 ready"没有超时**：上限就是插件寿命（`dispose` 会解开）。同样不加超时。

## 契约与现状同步

`docs/subsystems/remote-channel.md` §6.2 新增一条"`$events` 流换代也不结算"
（换投递、重投不重复 claim、窗口里的答复等下一代 ready 再发）。
memory 的"已知缺口 13 / `$events` 换代窗口"一并划掉。

Note: 来自总账 `.agents/notes/proposed/2026-10-24-native-rules-audit.md` 的 C13
（根因分段 2："把连接态当语义态"）。
