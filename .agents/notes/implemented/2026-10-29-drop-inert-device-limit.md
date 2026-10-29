# Agent Note: 删掉空转的 `deviceLimit`（而不是实现它）

Status: implemented

## Problem

`connector/src/config.ts` 的 schema 里有一个 `deviceLimit`（`z.number().step(1).min(1).default(8).volatile()`，接口里是 `Volatile<number>`，注释写"允许配对的设备数"），而**全仓没有任何一行读它**：`src/` 里零引用、`tests/` 里零引用，只有 `docs/subsystems/connector-and-relay.md` 的字段表抄了它的默认值。

它的害处不是"少一个功能"，是**一个不生效的旋钮会出现在界面里**：`.volatile()` 的字段会进手机端的通用配置表单（`config.ts` 文件头原话），于是用户能读到"允许配对的设备数 8"、能改、能保存，而改完什么都不会发生。这正是 `memory.md` 第 7 条教训（"生产路径上的假数据最容易漏：不报错、不空屏，只是数字是编的"）的另一种形态。

更硬的一条：**契约本来就写着不设上限** —— `docs/subsystems/remote-channel.md:811`「设备上限 | 不设上限 | 每设备一把密钥 ⇒ 吊销粒度小;重新配对即新身份,记录随用户主动重配而增加,清理走管理面」。所以 schema 与契约互相矛盾：删字段是与契约对齐，实现它才是改契约。

## Decision

**从 schema 删掉这个字段**（不实现上限）。删之前按用户要求先确认 DSH 对"配置里有 schema 之外的键"的行为，四条证据：

1. **校验只会在 `issues` 时失败**：`vendor/cordis/src/fiber.ts:50-62` 的 `resolveConfig` 走
   `runtime.Config['~standard'].validate(config)`，只有 `result.issues` 才抛 `ValidationError`，
   否则原样返回 `result.value`。
2. **schemastery 的 object 解析把未知键抄进结果**：
   `@deepseek-ai/schemastery@3.18.5` 的 `src/index.ts:812-823`（`Schema.extend('object', …)`）只遍历
   schema 自己的 `dict`，最后 `if (!strict) merge(result, data)`，而 `merge`（`:805-810`）把
   "结果里没有的键"逐个抄进去；`strict` 在 `Schema.resolve` 的默认值是 `false`（`:515`）。
   实测（同一版本的 `~standard.validate`）：`{relayUrl, deviceLimit:9, totallyBogus:1}`
   → `issues: null`，`value` 里两个未知键都在。
3. **隔离实例实测（删掉字段之后）**：把 `deviceLimit: 3` 手工写进
   `D:\tmp\dsh-mobile-home\profiles\dsh-mobile-test\cordis.patch.yml` 的连接器 `config:` 块，
   重启实例 → 插件照常挂载：`GET /api/dsh-mobile/status` 200（`caps.direct=true`）、
   `GET /api/dsh-mobile/transport` 里 relay `running:true,connected:true`、direct 监听 `0.0.0.0:8790`。
   **多余键既不报错也不挡挂载。**
4. **面板保存不会抹掉它**：经 `POST /api/dsh-mobile/connection` 改一次 `listenPort`（一次
   `settings.update`，会整段重写该条目的 `config:` 块）之后，yml 里 `deviceLimit: 3` 仍在
   （`listenPort` 已改）。写回保留未知键这条与上轮 `approvalTakeover` 的观察一致
   （`implemented/2026-10-29-panel-connection-card.md` 的 Consequence、
   `packages/boot/config-editor/src/index.ts:110,127`）。

结论：**不需要迁移**。已写进 yml 的那一行会留着、不再进 schema、不再出现在 `settings.describe`、
也不影响任何行为；想清干净就手删那一行。

改动的四处（同一个提交）：`connector/src/config.ts`（接口 + schema 各删一行，并留一段说明为什么
"没有这个字段"是对的）、`connector/src/transport/rebuild.ts` 的注释示例换成真实存在的 volatile 字段、
`connector/tests/transport-rebuild.test.ts` 的"无关键"清单同样换掉、`docs/subsystems/connector-and-relay.md`
的字段表删行并加一段"没有设备数上限"的说明（指回契约那张表）。

准入门槛（落地时逐条可机械判定）：

1. 全仓 `deviceLimit` 只剩笔记与 `archived/`：`src/`、`tests/`、`docs/` 各 0 处。
2. `cd connector; pnpm exec tsc --noEmit` 0；`pnpm test` **748/748**（删字段不改任何用例的断言数）。
3. 隔离实例按上面第 3、4 条复验（patch 带多余键 → 挂载 + `/status` 200；面板保存后该行仍在）。
4. `dart analyze` / `flutter test` 不受影响（本轮不碰 `app/`）—— 但若将来手机端通用表单缓存了
   字段清单，要重进一次设置页才看得到少了一格。

## Alternatives considered

1. **实现它：超限拒配对 + 面板报原因**
   - 最强的理由：schema 承诺了就该兑现；"家里 + 公司 + 平板"确实可能超过 8，一个数量界能挡住
     "名册无限增长"。
   - 为何被否：契约明写"不设上限"并给了理由（吊销粒度、重配即新身份、清理走管理面）——
     要实现就得先改契约，而"拒配对"是本通道**新增的拒绝路径**，它要连带决定：吊销的行算不算、
     删掉一行能不能立刻补位、并发配对时谁来判、手机侧文案怎么说、面板怎么报原因。
     这些语义的复杂度远大于它挡住的成本（一行名册几百字节）；而"名册膨胀"的真实来源是反复重配
     留下的旧行，那由管理面清理（`admin/device-admin.ts`），不是靠一个数挡。
2. **保留字段，但在 description 里注明"暂未生效"**
   - 最强的理由：零风险零迁移，schema 与界面都不用动。
   - 为何被否：等于把 TODO 写进用户界面，而且它照样占着手机通用表单的一格。一个明知不生效的
     旋钮，比没有这一格更糟 —— 用户会以为自己配过上限。
3. **改成警告而不是拒绝（超限只记日志 / 面板一条黄条）**
   - 最强的理由：不阻断用户，又能让人注意到名册在涨。
   - 为何被否：警告要有阈值，而阈值正是被删掉的那个数；面板的设备列表本来就显示行数，
     用户直接看得见，不需要第二个派生信号（"两个来源会漂"）。
4. **把上限下沉到中转（中转拒注册第 N+1 台设备）**
   - 最强的理由：真实资源在中转（内存、连接数、限流桶），在那里设限更接近成本。
   - 为何被否：中转发设备名册是**电脑侧权威的投影**（`POST /devices` 重放摘要，
     `relay/src/device-registry.ts` 只负责收敛），在投影侧设限量会和"I7：中转清空重启后
     电脑侧重放即收敛"直接打架。中转侧该管的是通道数与限流（`relay/src/core.ts:99`、
     `server.ts:140` 的 slow consumer），不是设备数。

## Consequences

- 收益：schema 与契约重新一致（"不设上限"只有一个出处）；手机端通用表单少一个假旋钮；
  `REBUILD_KEYS` 的注释与用例不再拿一个不存在的字段当示例。
- 收益：`ConnectorConfig` 少一格 —— 将来谁想加上限，必须先改契约再带着"拒绝路径"一起设计，
  而不是像今天这样只加一个数就以为有了。
- 代价：已经写了 `deviceLimit:` 的 yml（真实用户或旧的隔离 profile）会留一行僵尸键：值还在
  patch 里、不再被 schema 认识、不再显示、也不生效。**不需要迁移**，想清就手删那一行；
  反过来说，别人看到那行会以为它有用 —— 这是删掉一个曾经"存在过"的配置键的固定代价。
- 代价：如果这个部署靠 `.volatile()` 字段清单做"配置页缓存"（手机端设置页在首帧读一次），
  升级后要重进一次设置页才会看到少了一格 —— 只是显示延迟，没有行为影响。
- 未处理（本轮不碰）：另外三个 volatile 字段同样**没有一个从 config 读到它们的调用点**——
  `config.pushDigest` / `config.frameLimitBytes` / `config.refetchThresholdBytes` 各 0 处引用；
  管线是有的（`createPushMerger(level)`、`createSessionPager` 的 `refetchThresholdBytes`、
  连接层读帧时用的是常量），只是没人把配置值喂进去。它们与 `deviceLimit` 同类，但**不在本轮议题**：
  删它们要连带确认"推送摘要粒度 / 帧上限应该由谁决定"，那是产品与协议决定，不是清理。
  （记录在此是为了不让下一个人以为"这个坑已经一起清了"。）
