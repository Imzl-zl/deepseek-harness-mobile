# dsh-mobile 项目状态

> 快照 + 最近窗口，**覆盖更新**，不做流水追加。历史在 git 与 `.agents/notes/`；
> 稳定命令与坑点在 `tools.md`；现状事实在 `docs/`。

## 现在（2026-10-29）

- **连接配置进面板（`2c9876f`）**：「手机」面板顶部「连接」卡
  （`GET/POST /api/dsh-mobile/connection`，逻辑在 `admin/connection-card.ts`）：中转地址 /
  公网明文开关 / 令牌 / 直连端口 + "已连接"真信号（`ChannelState.connected`，原来只有
  `running`，答不了"手机那头通没通"）。四条已定案：① 只碰白名单三格（`relayUrl` /
  `allowInsecurePublic` / `listenPort`），该条目另外 8 个 volatile 字段不上卡；② 地址在写入
  **之前**用 `relayUrlOf` 校验"保存之后的完整状态"（schema 不管语义）；③ 一次保存只有一次
  `settings.update`（逐字段 mutate 会让 revision +1、第二次必 409）；④ 令牌三态（留空/替换/
  清除），**值永不过线**（GET 只回 `{configured, writable}`）。保存顺序：配置优先、令牌其次，
  令牌失败回 400 带 `configApplied=true`。取舍见
  `implemented/2026-10-29-panel-connection-card.md`。
- **无令牌可挂载（同批）**：`start-transport` 只放过两种"配置里本来就允许的缺席" ——
  `RelayTokenError`（凭据里还没令牌）与 `listenPort = 0`（明说"不监听"）；坏地址、端口被占
  照旧整体抛出。原行为是"删令牌 → 重启 → 管理面没挂上 → 面板 404"，删一次就锁在门外。
  `endpoint.describe` 因此**总是挂**（否则面板把直连从 0 改成 8790 后手机拿不到新端点）。
- **装配层回归网（`7d1e6a1`，今天）**：三处判据搬出 `index.ts` 闭包 ——
  `transport/rebuild.ts`（键集合 → 重建哪条通道 + 重建串行队列，失败落成「连接」卡一句话）、
  `transport/startup.ts`（上面那两种容忍的判据与起停顺序）、
  `admin/connection-card.ts` 的 `readConnectionState`（面板读取投影）。装配层是否真接上由
  `tests/assembly-wiring.test.ts` **读 `index.ts` 源码**盯。connector 719 → **748 项**。
  笔记 `implemented/2026-10-29-assembly-regression-net.md`。
- **配置改成用时读取（`2c9876f`）**：`Assembly.config` 从挂载快照换成 accessor；说"哪台中转"
  的四处（拨号、出码、名册上报、端点自报）都读当前值 —— 只让拨号读新值会出现"连接连到新
  中转，二维码还写着死地址"。已知 UX 缺口：保存后只轮询 6 秒（12×500ms）看是否连上。
- **端点按电脑剪枝 + 失败冷却（10-29）**：`Endpoint.hostId` = 那台电脑的 Ed25519 公钥
  （**不用 `pcId`**，它是连接器 id、默认 `"local"` 会撞）；换电脑后旧电脑报过的自动条目剪掉，
  手填的永不动。`dialOrder` 加失败冷却（60s 内排尾，连"记住的那条"也不例外）+ 按电脑排序。
  笔记 `implemented/2026-10-29-endpoint-host-scoped-pruning.md`，设计面 `app-channel-client.md` §6.2。
- **明文放行分两档（10-29）**：非公网 `ws://`（局域网/回环/组网 CGNAT）**所有构建都用**；
  公网 `ws://` 只认用户显式确认（偏好 `net.allow_plaintext_public`，确认点只有手填端点勾选
  与配对页确认卡）；`wss://` 任何主机始终放行。笔记 `implemented/2026-10-29-plaintext-*`。
- **配对生命周期真机复验（10-29，公司 wifi 判成「公用」）**：重配走 `replaces`（新行先与旧行
  并存、旧令牌仍可用，新身份握手成功后旧行被裁，`pairedAt` 沿用）与"改坏一位 code 如实报
  `protocol/not-paired`"两条实测通过。公用网络下 8787/8790 入站被拦，要么改专用网络、
  要么 `adb reverse` 走环回。
- **通道全景**：`protocol/`（配对/握手/AEAD/流控/恢复）+ `relay/`（中转）+ `connector/`（电脑侧
  网关）全部落地；手机侧 `app/lib/core/` 是连接层，`app/lib/wire/` 是**线上形状的唯一解码层**
  （`wire/rpc/` 18 个面文件、46 个方法；`wire/` 外零 `call<`；方法面 52/50，差额 2 =
  `credentials.set` / `credentials.unset`）。
- **UI**：各页全部接真数据，真机验收到 10-28。**唤醒判据**已照 DSH 的 `idleSteer` 修好：
  子智能体的 `agent-message` / `subagent-settled` 走 `next-step` 也算唤醒
  （`implemented/2026-10-28-turn-trigger-idle-steer.md`，现状 `turn-groups.md` §6.1）。
- **未验**：图片上限四条、`readBytes` 预览、插件安装/卸载的真实 pnpm 流程；桌面四件事的真机
  验收（**分支已通过**；改动卡/差异/提及需要一轮在**当前宿主进程里跑完**的对话 ——
  记录是内存态，重启即丢）。`caps.changes` 真机 **true**；计划审查卡**有意不接**。

## 下一步

0. **状态语义对齐（A–H 已全落地）**：现状 `docs/subsystems/ui-state.md`；真机复验还差 4 条
   （子智能体在跑可见、提问草稿、发送模式真值、断连重连）。因果见 `implemented/2026-10-27-*`。
1. 跑一轮真机复验改动卡 / 差异 / 提及（要模型请求 —— 先报价再跑）。
2. `usage.summary` 的 byDay 时区；`plugin.installStatus` 的 4 键/8 键两形态
   （真出现第二种时 `readPluginJob` 会红，属**已知的下一处**）。
3. 大改后巡检一次 `docs/` 与代码的漂移。**已知一处**：`connector/src/dsh/interaction-client.ts:63`
   import 了 `transport/backoff.js`，而 `connector-and-relay.md` §1.2 写着「`dsh/` 不 import `transport/`」；
   两者选一个改（补机械规则会立刻红，改文档则承认这条方向可用）。

## 门禁（改代码后必须全绿，项数以 `tools.md` 为准）

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | 454 / 26 / 49 项 |
| `node app/tools/verify-platform-boundary.mjs` | 639 项（25 条规则自检 + 148 个 Dart 文件） |
| `node app/tools/verify-rpc-single-caller.mjs` | `app/lib`（`wire/` 外）零 `call<` |
| `node mock/proto/tools/verify-{icons.cjs,tool-paths.mjs}` | 图标集 / 24 个工具脚本无硬编码盘符 |
| `cd app && flutter test` | 1537 项（约 1 分钟） |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format` | 各 0 |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + **748** 项 |
| `cd relay && pnpm typecheck && node --test` | 类型 + **89** 条 |

**改断言必须做一次变异校验**（故意破坏不变量，确认恰好那几条红，条数写进提交）。

## 九条教训

1. **投影信封**：`session.projections` 回 `{kind, asOfSeq, values}`，手机要 `values`。
2. **模型目录是对象**（`{default, routableProviders, groups, failures}`）不是数组。
3. `session/select-model` **没有"不能写"约束**：别把测试纪律升成产品约束。
4. **"空"有两种表达**：`items.isEmpty` 漏了 `OtherItem`；`usage == null` 漏了"字段齐全但全零"。
5. **判据要能区分"没命中"与"没实现"**：先一行 `debugPrint` 确认回调跑了，再怀疑手势。
6. **一个功能一次提交完整**：提交前 `git status --porcelain` 必须只剩有意的文件。
7. **生产路径上的假数据最容易漏**（不报错、不空屏，只是名字/数字是编的）。
8. **线上预算按帧算**：二进制 `N` → JSON base64 → box 再 base64url ≈ `1.78N`。
9. **用例喂的形状必须是线上形状**：真机事件/真库行先 dump 再写断言；字段类型只在 `wire/` 断言。

## 真机联调的成本纪律

- 隔离实例：`$env:DSH_HOME='D:\tmp\dsh-mobile-home'` + `dsh --profile dsh-mobile-test`；`--profile` 只隔
  进程/插件/端口，`~/.dsh/{.credentials.yaml,sessions,storages}` 共用 —— **跑之前报轮次并拿到准**（花用户的钱）。
- 装 App 一律 `flutter build apk --debug` + `adb install -r`（`flutter install` 会先卸载）。

## 仍未注意就会翻车

- **改源码只用编辑工具**（shell 替换静默出错）；**`dart format` 会重排文件**，之后再编辑要重读。
- **同一件事只有一处判据**（重建哪条通道 / 起传输容忍什么 / 面板读什么）：都已有同名模块 + 回归用例
  （`transport/rebuild.ts`、`transport/startup.ts`、`connection-card.ts`），别在 `index.ts` 再写；坑点见 `tools.md`。

## 已知缺口（仍在）

- 计划审查卡手机上不存在（**有意**，契约 §15）；停用设备的"明说"在**中转链路**看不到（直连能看到）；
  保存「连接」卡后只轮询 6 秒判是否连上，慢网会停在"重连中"；上述"未验"各项仍在。

## 已落地索引

- 2026-09-30 通道协议定稿 / 配对 v1 / 连接层拆分 — `implemented/2026-09-30-*`、`2026-10-01-*`
- 2026-10-02 安卓里程碑 / 主题层 / 图标 / 本地库 / 配对 — `implemented/2026-10-02-*`
- 2026-10-07..09 配对 v2、设备身份、三处线上形状错 — `implemented/2026-10-0[789]-*`
- 2026-10-13..17 交互链、审批/提问、发送模式、端点切换、标题、设置页 — `implemented/2026-10-1[3-7]-*`
- 2026-10-19..24 渲染对齐、轨迹/轮组、用量、文件页、插件、任务、通知 — `implemented/2026-10-19-*`..`24-*`
- 2026-10-25 RPC 应答面收口（8 批） — `implemented/2026-10-25-wire-*`
- 2026-10-26 评审六批 + 真实清单进金样 + 桌面四件事 + 连通落点 — `implemented/2026-10-26-*`
- 2026-10-27 UI 状态语义（审计 → 机制 → A–H 批） — `implemented/2026-10-27-*`；现状 `docs/subsystems/ui-state.md`
- 2026-10-28 渲染批次 + 唤醒判据修正 — `implemented/2026-10-28-*`
- 2026-10-29 连接卡 / 无令牌可挂载 / 装配层回归网 / 删掉空转的 `deviceLimit` / 端点剪枝 /
  明文两档 / 高亮语言集 — `implemented/2026-10-29-*`（六篇）；多机方案仍 `proposed/2026-10-29-*`
