# 新会话提示词:把「交互转手机」做到真机连通

> 复制下面 `---` 之间的全部内容到新会话。

---

## 任务

把**审批 / 提问 / 计划审查转到手机**这条链做完,并做出**第一次真机连通**。
这是本项目从"能看会话列表"变成"能遥控电脑"的那一步。

## 已经做好的(不要重做)

三侧门禁**全绿**,且跨实现一致性已闭环:

| 门禁 | 数字 |
|---|---|
| `node protocol/verify-fixtures.mjs` / `loopback` / `vectors` | 486 / 26 / 49 |
| `node app/tools/verify-platform-boundary.mjs` | 182 |
| `cd connector; pnpm exec tsc --noEmit && pnpm build && pnpm test` | **335** |
| `cd relay; pnpm typecheck && pnpm test` | **75** |
| `cd app; flutter test` / `dart analyze --fatal-infos` / `dart format` | **340** / 0 / 0 |

**已完成(有证据,别重做)**:
- 配对 v2 三侧收口(公开邀请 + 候选身份 + 每设备一条数据连接),`connector/tests/pairing-e2e.test.ts` 绿
- **跨实现一致性**:`connector/tests/cross-language-handshake.test.ts` 让 Dart 与 TS 的**产品代码**
  真打一次握手 + 双向封箱,比对派生的密钥与解开的明文(做过变异校验)
- 错误码表补齐(15 个 DSH 宿主层码)+ 跨端一致性门禁
- `connector/src/interaction-face.ts`(**已建好,31 项单测绿,但没接线**):
  待处理投影 / `interaction.respond` 校验与路由 / `createWatchdog` 看护计时器
- `connector/src/dsh/interactions.ts`(**已接线**):两个 answerer 已注册(`index.ts:302`)
- 契约 §5.7/§6 已按 DSH 源码核实并改正(含"空答案是合法跳过"、`open`/`continued` 两条路)

## 三个必须按顺序做的步骤(**顺序不能颠倒**)

读 `index.ts:156-162` 会发现完整因果链:

```text
没人写 liveRegistry → liveDevices() 返回 [] → decideTakeover 永不 claim
→ answerer 永远 next() 交还桌面 → index.ts:201-213 那个 fail-closed 桩根本跑不到
```

所以现在那个"审批转手机"的桩**不是"会拒绝",是"永远不触发"**。

### ① presence 上报(最前面,现在完全没做,两侧的活)

- **手机侧**:实现 `sync.hello`,带 `app: 'foreground' | 'background'`(契约 §5.4 已有这个字段,
  Dart 侧没实现)。`online` 由连接本身表达;`lastInteractedAt` 由手机每次答话时带上。
- **连接器侧**:`connection-scope.ts` 在四个时机回调挂载级 —— 鉴权完成 / 断开 /
  订阅变化 / 收到 `sync.hello`,写进 `index.ts:163` 的 `liveRegistry`。
  `subscribed` 在 `connection-scope.ts` 里**本来就有**(`sessionSubscriptions`),别另建一套。
- **验收**:`liveDevices()` 不再恒为空;`decideTakeover` 第一次真的能 claim;
  那个桩第一次**真的被触发**(此时它返回 `reject` 才是设计生效)。

### ② port 实现(把 index.ts:201-213 的桩换掉)

- "推给哪台手机"**现成就有**:`protocol/takeover.ts:37` 的返回本来就带 `deviceId`,
  `dsh/interactions.ts:128` 现在只用了 `.claim` 把它丢了 —— 先用起来。
- 看护 / 断连**复用** `interaction-face.ts` 的 `createWatchdog`,**不要**在 answerer 上
  再挂一个(waterfall 只走先注册的,另一个静默不触发)。
- fail-closed:审批回 `reject`,提问抛错(**绝不返回空答案伪装成"用户全跳过"**)。
- **落点是挂载级**:它负责"把 prompt 送到哪条连接"。

### ③ `interaction.respond` handler(每连接)

- 手机答的话要从**发问的那条连接**回来,所以 handler 属于 `connection-scope.ts`。
- 契约 §5.7 形状:`{ sid, callId, answers: [{id, selected[], custom?}] }`,幂等键 `i:<callId>`,
  **答案批次原样转发**(连接器不翻译,翻译层就是漂移层)。
- 路由到 `ctx.get('userQuestions').answer(agent, callId, batch)` ——
  **只覆盖 `state === 'continued'` 的提问**;`open`(调用还在等)走实时应答链,已经能跑。
- 空 `selected` 且无 `custom` 是**合法的「显式跳过」**(`tool-ask-user/src/timed.ts:172,179`),
  **不得拦截**。提问已结束 `answer()` 返回 `false` → 映射 `interaction/not-pending`,不是崩溃。

### ④ 手机侧 UI 与真机

- 输入栏接管(审批 / 提问 / 计划审查):照 `mock/proto/` 原型,形状见契约 §6.4。
- 真机:`docs/cookbook/next-session-real-device.md` 有完整跑法(adb reverse / stayon /
  base64 二维码 / 起 relay 与 profile)。
- **交付判据**:真机上"点开会话 → 收到审批 → 手机上答 → 电脑侧继续"+"发一句 / 回一句"。

## 前置事实(会卡住实施)

- Flutter **3.41.9 / Dart 3.11.5 已装好,版本锁死**(上界由鸿蒙 fork 定,不许升)。
  Android 构建要 `ANDROID_HOME='D:\soft\android-sdk'` 与
  `JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-21.0.9.10-hotspot'`。
- 本机联调编排:中转 `cd relay; node src/main.ts --config relay.config.json`(**改 `relay/src/**`
  必须重启**);电脑侧 `dsh --profile dsh-mobile-test --no-open --port 8099`(**不碰用户日常 GUI
  的 19387**;**改 `connector/src/**` 必须先 `pnpm build`**,真加载的是 `lib/index.js`);
  **重启前确认没有旧进程残留**(两个进程抢同一身份会让中转不停顶掉旧连接)。
- `connector/` 与 `relay/` 是两个独立 pnpm 工程,都不是 DSH workspace 成员,本仓库**没有 CI**。
  两处导入风格不同、**别顺手统一**:connector 写 `.js`(tsdown 打包),relay 直接跑 `.ts`。

## 门禁(每次改完都要全绿)

```powershell
node protocol/verify-fixtures.mjs            # 486
node protocol/verify-loopback.mjs            # 26
node protocol/verify-vectors.mjs             # 49
node app/tools/verify-platform-boundary.mjs  # 182
node mock/proto/tools/verify-icons.cjs; node mock/proto/tools/verify-tool-paths.mjs
cd connector; pnpm exec tsc --noEmit; pnpm build; pnpm test      # 335+
cd relay; pnpm typecheck; pnpm test                              # 75
cd app; flutter test; dart analyze --fatal-infos lib test integration_test
cd app; dart format --output=none --set-exit-if-changed lib test integration_test
```

**改断言必须做一次变异校验**(故意破坏不变量,确认**恰好**那一条红)。
**绝不允许削弱测试让它变绿。**

## 踩过的坑(别再踩)

1. **改源码只用编辑工具,不用 shell 字符串替换** —— shell 出错是静默的,本仓被这个坑写空过
   源文件两次。提交前必看 `git status` 完整清单,重点看**意外的文件**。
2. **`dart run` 首次跑要编译 + build hooks(20-30 s)**,且 `dart` 是 `.bat` shim ——
   Node spawn 它必须 `shell: true`,否则报 `ENOENT`(看着像没装 Dart)。
   被 kill 的测试作业**不会带走子进程**,下一个 `dart run` 会静默等构建锁 ——
   挂住先清孤儿:见 `tools.md` 的 Pitfalls。
3. **DSH 服务键只在源码里核实过,没在活宿主里跑过**:`userQuestions` / `approval` 是否真叫这个,
   `answer()` 的真行为,全部依据源码 + DSH 自己的 spec。**接完先跑一次真宿主再信。**
4. **两条 answerer 不能同时挂**:waterfall 只走先注册的那个,另一个静默不触发。
   看护属于 `RemoteInteractionPort`,不属于 answerer。
5. **空答案不是错误**:`selected` 空且无 `custom` = 用户显式跳过,原样转发。
6. 真机两个坑:屏幕灭掉 = 引擎暂停(用例挂住且无原因)⇒ `adb shell svc power stayon true`;
   明文 HTTP 要在 debug 构建放行(`network_security_config.xml` + `PairingPage.allowInsecureLocal`
   **两处都要开**)。

## 范围决定(已定,别再讨论)

- **刷新令牌轮换不做**:设备令牌长期有效 + 手动吊销;刷新令牌是本机凭据,摘要不上中转。
- **中转不做多实例**:单实例 + I7 重启收敛就是个人工具的形态。
- **鸿蒙暂缓**(不是放弃):Flutter 版本锁继续保留;OHOS 适配 / HUKS / 推送全部暂停。
- **直连监听面继续自起监听**,不改用 DSH 的 `registerUpgrade`(取舍见
  `.agents/notes/implemented/2026-10-09-direct-listener-keeps-own-socket.md`)。

## 已知缺口(不挡路,但别当已修)

1. 首配的匿名限流桶是**单一全局桶**,刷约 6 请求/秒可让所有新设备换票 429(约 10 s 恢复),
   与 `pairing-v2.md` §3 的要求不符。修法:把形状校验挪到取桶之前。
2. `relay/src/core.ts` 的 `stats.devices` 实为**通道数**(观测量,低危)。

## 相关文档(改之前先读)

- `docs/subsystems/remote-channel.md` §5.7(方法表)/ §6(交互层,已按源码改正)
- `docs/subsystems/pairing-v2.md`、`connector-and-relay.md` §1.7(直连)
- `memory.md`(当前状态 + 三步依赖链)、`tools.md`(命令与 Pitfalls)
- `.agents/notes/implemented/2026-10-09-*.md`(本轮五篇决策笔记)

非平凡改动**必须留决策笔记**(`.agents/notes/`),与代码**同批提交**。
