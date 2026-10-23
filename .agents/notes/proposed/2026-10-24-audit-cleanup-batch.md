# Agent Note: 开工单 Z1–Z6 —— 审计后的零碎清理（每行一个提交）

Status: proposed

这六件都来自总账 `.agents/notes/proposed/2026-10-24-native-rules-audit.md`，都是**单点**
修复：没有备选方案、不改跨端契约的形状、不需要新测试策略。所以不给每件单独立一篇笔记，
但**每件仍然是一个独立提交**，提交信息里回指本篇的编号与总账的行号。

---

## Z1（删规则）`danger-full-access` 下"审批不入队" —— ✅ 已落地

- **位置**：`app/lib/ui/takeover.dart`（`enqueue` 的分支 + `fullAccess` 字段 + 文件头第 2 条）、
  `app/lib/ui/chat_page.dart`（`_syncTakeoverAccess` 与 build 里那一行 + 那句 toast）。
- **为什么删**：DSH 在 `danger-full-access` 预设下把审批策略写成 `never`
  （`packages/bundle/base/cordis.patch.yml:274-276`、`packages/interaction/permission-presets/src/index.ts:193-195`），
  而 `never` 在 **dispatch 之前**就 `rejected`（`packages/interaction/user-approval/src/index.ts:270-275`）
  ⇒ **根本不产生 `approval/request`**。这条过滤过滤的是一个不会发生的场景，
  配的那句"完全权限下不再逐步确认：X 直接执行"因此永远显示不出来。
  浏览器侧也没有任何同类过滤（`packages/client/ui-approval/src/client/index.ts` 全文）。
- **改什么**：`enqueue` 去掉分支与字段；`chat_page.dart` 去掉 `_syncTakeoverAccess` 与整块
  `if (!_takeover.enqueue(...))` toast；文件头第 2 条改成"**没有**这条过滤"并写出处。
- **判据**：`takeover_test.dart` 的两条旧用例（"完全权限下不入队"）删掉，换成两条新的
  （"审批也照常入队"、"三种交互都进同一个桶，顺序只由优先级决定"）；
  `chat_takeover_wiring_test.dart` 那条改成"切到完全权限后审批**仍在队列里**（排最后）"。
- **变异校验**：在 `enqueue` 里临时 `if (approval) return false` ⇒ 接管层与接线层**成片红**
  （审批相关的全部用例，含新加的两条）。**注**：`fullAccess` 字段已删，做不了"只恢复旧条件"的
  精确变异 —— 这是能拿到的最接近的一组。
- **门禁**：flutter **1141 → 1141**（删 2 条、加 2 条，净持平）、`analyze` / `format` 0、boundary 360。

## Z2（删死码）`presence.onOffline` 与它的监听桶 —— ✅ 已落地

- **位置**：`connector/src/presence.ts`（契约面 / 桶 / `offline()` 里的通知 / 实现，四处）。
- **为什么删**：生产**零调用**（全仓只有 `presence.test.ts` 一条）。它服务的是
  已经删掉的规则（"手机断开 → 看护收口 → `unavailable`"，A2/A4），而今天的真相是
  "断线只撤投递、不结算"（`packages/api/gateway/src/index.ts:717-721`）。
  注释还指着那条不存在的契约。
- **改什么**：删接口方法、监听桶、`offline()` 里的通知块、对应单测；`offline()` 的注释改成
  "这里不通知任何人"并写上出处。**顺手把 `presence.test.ts` 里过期的措辞一起改**
  （"仲裁判定的唯一输入" / "decideTakeover" / "不进仲裁" —— 那些概念都不存在了）。
- **判据**：`grep -r onOffline` 零命中；`presence.test.ts` 少一条（**断言随行为删除**，
  不是放宽）。
- **门禁**：connector **616 → 615**、`tsc --noEmit`、`pnpm build`。

## Z3（修）首配匿名限流的**单一全局桶** —— ✅ 已落地

- **位置**：`relay/src/http-face.ts`（键是字面量 `'pairing:anonymous'`）；
  桶参数 `relay/src/server.ts`（容量 60 / 每秒 6）。
- **为什么修**：所有**未配对**设备共用一个桶 ⇒ 约 6 req/s 就能让全部新设备吃 429
  （约 10 s 才恢复）。这是实现缺陷，不是策略：策略（"匿名要限流"）本身对。
- **改什么**：匿名键带上来源（`pairing:anonymous:<remoteAddress>`），取不到地址时退到
  `unknown`（等价于改动前的全局桶，不更坏）；`HttpRequest` 多一个**可选** `remoteAddress`，
  由 `server.ts` 从 `request.socket.remoteAddress` 填。`rate-limit.ts` 的头注写清
  "认证过的按身份、未配对那一跳按来源地址"，并如实写明**反代之后会塌成一个桶**
  （那时与改动前等价）。
- **判据**：`relay/tests/http-face-rate-limit.test.ts` 改了键形状断言、加一条
  "两个来源地址互不牵连"；变异校验：把键改回字面量 ⇒ **恰好那两条红**（85 绿 / 2 红）。
- **门禁**：relay **86 → 87**、`pnpm typecheck`。cookbook 里那句"单一全局桶"同步改成新形态。

## Z4（删字段）`stats.devices` 与 `stats.channels` 恒等 —— ✅ 已落地

- **位置**：`relay/src/core.ts` 的 `stats` getter：`devices: channels.size` 与 `channels: channels.size`。
- **为什么改**：名字说"设备数"，值是"通道数"，两个字段在同一行给出同一个数 ——
  读它的人会以为在数设备。设备数本来就在名册（`deviceRegistry.stats.devices` / `bound`）。
- **改什么**：删 `devices` 字段（类型 + getter + 注释写出处），消费方只有一条测试断言，
  改成"键集合里没有 `devices`"。`docs/cookbook/next-session-real-device.md` 里那句
  "别信这个数"跟着改成"设备数看名册、通道数看 channels"。
- **判据**：`relay/tests/core.test.ts` 断言 `Object.keys(core.stats).sort()` 等于四个键；
  变异校验：把 `devices: channels.size` 加回去 ⇒ **恰好那一条红**（85 绿 / 1 红）。
- **门禁**：relay **86 → 86**（一条断言替换，不增不减）、`pnpm typecheck`。

## Z5（修一行）配对码输入框关掉输入法联想 —— ✅ 已落地

- **位置**：`app/lib/ui/pairing_page.dart:413` 的 `TextField`。
- **为什么修**：二维码内容是 JSON，用户**手打**时输入法联想/纠错会改写它（粘贴没事）。
- **改什么**：`enableSuggestions: false` + `autocorrect: false`。
  **原计划里的第三个属性（`keyboardType: visiblePassword`）查了 SDK 后砍掉** ——
  `visiblePassword` 的文档只说"要一个字母和数字都顺手的键盘"
  （`packages/flutter/lib/src/services/text_input.dart:554-557`），**没有**说它关联想；
  真正管用的是那两个布尔：`enableSuggestions` 在 Android 是独立的 `NO_SUGGESTIONS` 标记，
  iOS 的联想**跟着 `autocorrect` 走**（同一文件 `:623-636`）。三件一起上就是猜。
- **判据**：`app/test/widget_test.dart` 新增一条 widget 断言（两个属性都是 false）；
  变异校验：把 `enableSuggestions` 改回 true ⇒ **恰好那条红**。
- **门禁**：flutter **1140 → 1141**、`dart analyze` / `format` 0。

## Z6a（修字 + 清单）内置预设文案**已经漂了** —— ✅ 已落地

- **位置**：`app/lib/model/agent_preset.dart` 的 `kBuiltInPresetCopy`（`minimal` 那一条）。
- **事实**：DSH 的 zh 字典是 `presetMinimalDescription: 'Agent 使用终端和图片读取工具，并支持上下文压缩，适合测试和对比其基础表现。'`
  （`packages/client/ui-agent-preset/src/client/locales.ts:100`），
  我们抄的是旧文案「Agent 仅使用终端工具完成任务…」。其余三档本来就一致。
- **为什么只能抄**：内置预设**不发布** `name`（`packages/preset/agent-preset-registry/src/display.ts:48-49,63-73`
  的 `presetDisplayText` 要一个 locale 查表函数，只有客户端有）⇒ 手机拿不到。
- **改什么**：改那一条文案；`app/test/agent_preset_test.dart` 里那条断言加注
  "**这不是与 DSH 一致性的证据**，它复述的是手抄串"（它钉的是分摊逻辑）。
  在 `tools.md` 的"DSH 升级后要重跑"那一段加一条**重抄四档**（含来源行号与"已漂过一次"的教训）。
- **判据**：机械比对 DSH `zh` 字典与 Dart 表的四条 name + 四条 description，**逐字相等**
  （2026-10-24 跑过一次全 OK）。
- **门禁**：flutter **1141 持平**、`analyze` / `format` 0。

## Z6b（写进 docs，不改码）IPv6 隐私地址仍会上报

- **位置**：`connector/src/transport/listener.ts:131-145`（只跳过 `fe80` link-local）、
  `:150`（IPv4 排前）。
- **为什么不动代码**：Node 的 `os.networkInterfaces()` 不暴露 `temporary` 标记（RFC 4941
  地址只能靠前缀/接口 id 猜），**判据不可靠** ⇒ 不猜。当前形态（IPv4 排前、IPv6 回落）
  已经把代价压到最小。
- **改什么**：契约 §15 加一条"IPv6 隐私地址仍会出现在候选里，只是排在 IPv4 之后"。
- **门禁**：无（只改文档）。

---

## 提交顺序建议

Z5（一行、零风险）→ Z2（删死码）→ Z1（删规则）→ Z4 → Z3 → Z6a → Z6b。
四条工单（W1–W4）与这六件**互不依赖**，但 W1 会重写 `interaction-claims` 与
`interaction-face`，Z 批不碰那两个文件 —— 可以并行，冲突面为零。

Note: 总账见 `.agents/notes/proposed/2026-10-24-native-rules-audit.md`；原则见
`implemented/2026-10-24-native-semantics-first.md`。
