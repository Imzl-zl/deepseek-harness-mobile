# 新会话提示词:跑通真机审批回合 + 补 lifecycle observer

> 复制下面 `---` 之间的全部内容到新会话。**这个会话已经很长且充满误判,新会话从这份开始。**

---

## 任务

把「审批转手机」在**真机**上跑完最后一跳。

两处小改(测试等待窗口 + lifecycle observer)已在 2026-10-13 完成并复跑门禁全绿;
**剩下的是真机验证这一件事**:起服务 → 出码 → 跑 `interaction_real_device_test.dart`
→ 按下面的判据验收。

## 当前状态(2026-10-13,全部有证据)

三侧门禁**全绿**:

| 门禁 | 数字 |
|---|---|
| `node protocol/verify-fixtures.mjs` / `loopback` / `vectors` | 486 / 26 / 49 |
| `node app/tools/verify-platform-boundary.mjs` | 186 |
| `cd connector; pnpm exec tsc --noEmit && pnpm build && pnpm test` | **369** |
| `cd relay; pnpm typecheck && pnpm test` | **75** |
| `cd app; flutter test` / `dart analyze --fatal-infos` / `dart format` | **372** / 0 / 0 |

真机(USB,小米 23113RKC6C / Android 16,序列号 `d61cf622`)**已验到**:
两段配对 → 建连 → 握手 → `sync.hello`(`app:'foreground'`)→ `session.list` 拿到真会话 →
`session.subscribe` 后 `ev` 流进来 → `session.prompt` 发出去的那句**作为 `user/message`
回到手机** → **`等待审批` 卡片画在手机输入栏上** → 点「允许一次」→ `interaction.respond`
带对 `callId` / `requestId: 'i:<callId>'` / 字面值 `"allowed-once"` → 卡片收束 →
**`approval/decided` 确实回来了**(这证明 prepend 修复有效,应答者真被问到了)。

**根因已在上一轮修掉**:`askApproval` 曾在"呈示不了"时 `return 'reject'`,
于是一个 outcome 同时代表"用户点了拒绝"和"手机不在线 / 看护断了" ——
**在替用户做一个他没做过的决定**(真机那条 tool result 写着
*"the user rejected … so stop and explain"*,而用户什么都没点)。
已改成抛,由 `interactions.ts` 归一成 `'unavailable'`。
**原生依据与取舍**:`.agents/notes/implemented/2026-10-13-approval-must-not-fake-rejection.md`
(参照 `packages/client/ui-approval/src/client/index.ts` 的 `answerApproval` 三个出口)。

## 免费渠道(不花用户钱)

`~/.dsh/profiles/dsh-mobile-test/cordis.patch.yml` 里已配好 `llm-pi-ai` 手写 route
(`lightvela-free`,`auto` 实际落到 `glm-5.3-flash`),`agent-default-model` 也指过去了。
**key 不落仓库** —— 启动 profile 时 export `LIGHTVELA_API_KEY=...`(值向用户要)。
配法见 `tools.md` 的「真机联调的免费渠道」。**不要配 `maxTokens`**(context 1M,pi-ai 对不写的字段用渠道上限)。

## 成本纪律(拿钱换来的,务必遵守)

`--profile` **只隔进程/插件/端口**;`~/.dsh/.credentials.yaml`、`~/.dsh/sessions/`、
`~/.dsh/storages/` **全是全局共用**。所以"起个测试 profile"给不了任何隔离感。
**规矩**:不另起 profile;专用会话走「问 → 建 → 跑 → 用户确认后删」四步;
每次跑之前报一句"这次约几个轮次"并拿到准。现在有免费渠道,这条 mainly 是别污染用户的会话列表。

## 起服务(照抄)

```powershell
# 1) 中继(改过 relay/src/** 必须重启;它没有构建步骤)
cd relay; node src/main.ts --config relay.config.json

# 2) profile(带免费渠道的 key)
$env:LIGHTVELA_API_KEY = '<向用户要>'
dsh --profile dsh-mobile-test --no-open --port 8099

# 3) 真机
adb -s d61cf622 reverse tcp:8787 tcp:8787
adb -s d61cf622 shell svc power stayon true

# 4) 出码:Web UI 里对**一个现成的空闲会话**跑 `/dsh-mobile-pair`
#    (POST /api/commands/execute,信封形状见 tools.md;不要为此新建会话)
```

**改过 `connector/src/**` 必须先 `pnpm build`**(真加载的是 `lib/index.js`)。
**跑完把自己起的进程杀干净。**

## 两处小改(2026-10-13 已完成,别当未修)

### ① 测试侧:步骤 ④ 的等待窗口

`app/integration_test/interaction_real_device_test.dart` 步骤 ④ 原用 `_waitFor` 的
默认 30 秒等 `user/message` 回读,而 `session.prompt` 是排队写 —— 会话正在跑轮次时走
`agent.followup`(`packages/api/session-controller/src/commands.ts` 的 prompt 分支),
`user/message` 要等当前轮次结束才落盘。免费渠道一个轮次轻易超 30 秒。

**已改**:这一步改用 `_waitForModel`(3 分钟)档;挑空闲会话的既有逻辑保留(只降概率,
不是保证)。**判据没动**:电脑侧确实受理了,不等模型回什么。

### ② 产品侧:lifecycle observer

`setAppState` 曾在 `app/lib` 里没有任何调用点 ⇒ 客户端从构造起就以为自己在**前台**:
`sync.hello` 恒报 `foreground`(电脑侧 `foreground` 档于是把审批继续推给退到后台的手机),
后台也维持连接与心跳(违反 §2.2 / §13 / §9),契约 §6.3.1 那句"退到后台自动 delegate"
是断的。

**已改**:装配点(`app/lib/main.dart` 的根 State)挂 `AppStateReporter`
(`app/lib/platform/app_state_reporter.dart`),`didChangeAppLifecycleState` 调
`setAppState`;**只把 `resumed` 算前台,其余(inactive/paused/hidden/detached)
fail-closed 报后台**。取舍、被否方案与代价见
`.agents/notes/implemented/2026-10-13-app-lifecycle-observer.md`。

## 跑通之后的验收判据

1. 电脑侧 `approval/decided` 的 outcome 是 **`allowed-once`**(不是 `unavailable`);
2. 那条越权命令真的跑出结果(`tool/result` 带 `dsh-probe-ok`);
3. 连续重连 N 次都成立 —— 别把"重启后第一次成功"当能力。

## 排查时的三个坑(都已写进 `tools.md`,别重踩)

1. **读会话日志必须按帧解压**:`~/.dsh/sessions/**/session.v4.jsonl.zstd` 是逐帧追加的
   zstd,Node 的 zlib **只解第一帧**(61 KB 只解出 211 字符)。按帧魔术字 `0x28B52FFD` 切段。
2. **`ctx.logger` 到不了 stdout,`console.error` 能**;`appendFileSync` 被 DSH 沙箱挡。
   **所以"日志没生成"不是"代码没跑到"的证据。**
3. **`flutter test integration_test` 跑完会卸载 App** —— 仪表里看到的 `onclose`
   可能是装卸造成的,**没有时间戳的两个事件,间隔什么都不说明**(上一轮就这样把一个
   42 秒的装卸周期误读成"连接莫名中断",白绕一轮)。

## 还没做的(别当已修)

- **模型切换**:`session/select-model` 会顺手 `saveSelection` 回写**全局默认**,
  波及用户日常 profile,所以本期只读不写。
- **模型 picker 接真目录**:`session/modelCatalog` 已在连接器侧接好(`dsh/models.ts`),
  手机侧显示的名字已是真值,但 picker 列表还是手抄的。
- 方法面剩 8 个未接(`session.create` / `session.cancel` / `settings.*` / `credentials.*` /
  `devices.revoke` / `push.configure`)。
- `always` 档下没订阅该会话的手机看不到卡片(看护超时后 fail-closed)。

## 相关文档(改之前先读)

- `.agents/notes/implemented/2026-10-10-interaction-to-phone-chain.md` —— 整条链的取舍
- `.agents/notes/implemented/2026-10-13-answerer-must-be-prepended.md` —— 应答者必须 prepend
- `.agents/notes/implemented/2026-10-13-approval-must-not-fake-rejection.md` —— 上一轮修的根因
- `tools.md` / `memory.md` —— 命令、坑点、当前状态

---
