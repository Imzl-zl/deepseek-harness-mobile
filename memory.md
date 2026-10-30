# dsh-mobile 项目状态

> 快照 + 最近窗口，**覆盖更新**，不做流水追加。历史在 git 与 `.agents/notes/`；
> 稳定命令与坑点在 `tools.md`；现状事实在 `docs/`。

## 现在（2026-10-30）

- **多机四步全部落地**（方案 `proposed/2026-10-29-one-phone-many-computers.md`）：
  ① 归属（`Endpoints.id = hostId|url` / `host.<hostId>.*` / `repo.info.hostName`，120ea3a）；
  ② 凭据分槽（`dsh.pairing.<hostId>.*` + `active`，cb2bd1d）；
  ③ 拨号竞速 + 缓冲按"在服务的设备"裁剪（ba9e438）；
  ④ 独占与切换（**今天三次提交**）：`device/busy` 四处门禁同批（错误码 35→36）、
  占用位 = `presence.serving()`、握手 `acceptHello` 准入（同一 devId 放行）、
  拒绝理由带占用者（`协议码 说明`，≤120 字节）、控制面 `?id=` 必带自报、
  面板「在服务」档 + 显式「接管」（走既有停用写路径）（eb9696e）；
  手机侧「切换电脑」= 换槽 + 重新装配 + 「切回上一台」、被占用停机（`busy-wait`）、
  15s 拨号总预算、2s/8s 提示、结论后 60s±20% 静默慢重试（e2a2499）；
  过期的一轮拨号不许动连接（真机抓到的 `backoff→handshake` 崩溃）（129b1a0）。
  笔记四篇 `implemented/2026-10-30-*`。
- **真机验收（10-30）**：`serving` 随连接出现/断开（关 App 后 **873ms** 内释放），
  relay-only 与直连两条路径都能进 serving；面板实测那一行是
  `运行中 · 前台 · 在服务` 且只有它有「接管」；`?id=` 实测 OPEN / 403 / **不带也 403**。
- **第二台设备 = 逐跳静态审查**（没有第二台真机）：出票 → 中转开通道 → 拨数据面 →
  `hello` → `peerOf` → `occupantOf` → 4003 → 中转转发 → `busy-wait` → 界面，逐跳核对后
  抓到并修掉**两个真漏洞**：① 中转把 4003 吞成 4000（门槛 4 走中转必失效）；② 停用只标
  `revokedAt` 而不收连接（占用位已释放、旧 socket 还在收发）。另收紧两处竞态：换网重连
  的迟到 `offline` 不删新记录（每连接令牌）；准入判"任何别的在线设备"（不只第一条）。
  **旧数据/旧客户端兼容全删**（`?id=` 必带、凭据/UI 状态的平铺键迁移、端点元数据旧 id
  补前缀）—— 协议未发版，没有存量。笔记 `implemented/2026-10-30-drop-legacy-compat.md`。
  审计后仍**证明不了**两件：两台"同时"握手那一瞬（要"在途占位"维度）；**删除**设备后
  手机只会重试（行被名册差集删掉 → 401 `device-unknown`，而它与"名册还没同步"在中转
  侧不可区分；停用是 `device-revoked`，手机侧早已清凭据回配对页）。
- **面板 / 装配 / 端点 / 明文（10-29）**：「连接」卡只碰白名单三格 + 令牌三态（值永不过线）；
  `start-transport` 放过两种允许的缺席（缺令牌 / `listenPort = 0`）；装配层三处判据搬出
  `index.ts`（`rebuild.ts` / `startup.ts` / `readConnectionState`，由 `assembly-wiring`
  读源码盯）；`Endpoint.hostId` = 电脑公钥（不用 `pcId`，会撞），`dialOrder` 带失败冷却；
  明文 `ws://` 非公网放行、公网只认用户确认。笔记 `implemented/2026-10-29-*`（六篇）。
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

0. **多机第 4 步的真机复验**：只剩两条要**两台设备**才能做的（第二台被
   `device/busy` 拒并说出占用者、切回上一台的真实链路）—— 单测已覆盖，
   真机可用"第二个 DSH_HOME + 另一份连接器身份"补；命中不了的按未验证如实说。
1. **状态语义对齐（A–H 已全落地）**：现状 `docs/subsystems/ui-state.md`；真机复验还差 4 条
   （子智能体在跑可见、提问草稿、发送模式真值、断连重连）。因果见 `implemented/2026-10-27-*`。
2. 跑一轮真机复验改动卡 / 差异 / 提及（要模型请求 —— 先报价再跑）。
3. `usage.summary` 的 byDay 时区；`plugin.installStatus` 的 4 键/8 键两形态
   （真出现第二种时 `readPluginJob` 会红，属**已知的下一处**）。
4. 大改后巡检一次 `docs/` 与代码的漂移。**已知一处**：`connector/src/dsh/interaction-client.ts:63`
   import 了 `transport/backoff.js`，而 `connector-and-relay.md` §1.2 写着「`dsh/` 不 import `transport/`」；
   两者选一个改（补机械规则会立刻红，改文档则承认这条方向可用）。

## 门禁（改代码后必须全绿，项数以 `tools.md` 为准）

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | 454 / 26 / 49 项 |
| `node app/tools/verify-platform-boundary.mjs` | 645 项（25 条规则自检 + 149 个 Dart 文件） |
| `node app/tools/verify-rpc-single-caller.mjs` | `app/lib`（`wire/` 外）零 `call<` |
| `node mock/proto/tools/verify-{icons.cjs,tool-paths.mjs}` | 图标集 / 24 个工具脚本无硬编码盘符 |
| `cd app && flutter test` | 1579 项（约 1 分钟） |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format` | 各 0 |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + **770** 项 |
| `cd relay && pnpm typecheck && node --test` | 类型 + **91** 条 |

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
  明文两档 / 高亮语言集 — `implemented/2026-10-29-*`（六篇）
- 2026-10-30 多机四步（归属 / 凭据分槽 / 拨号竞速与缓冲裁剪 / 独占与切换） —
  `implemented/2026-10-30-*`（五篇，方案页仍留在 `proposed/` 作为决策源）
