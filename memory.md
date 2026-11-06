# dsh-mobile 项目状态

> 快照 + 最近窗口，**覆盖更新**，不做流水追加。历史在 git 与 `.agents/notes/`；
> 11-04 及更早的条目在 `memory/archive/2026-11.md`；稳定命令与坑点在 `tools.md`；
> 现状事实在 `docs/`。

## 现在（2026-11-06）

- **v0.2.9 已发版**（`app/pubspec.yaml` `0.2.9+4`；Release：`dsh-mobile-v0.2.9.apk`（release 签名）
  + `dsh-mobile-connector-0.1.21.tgz`）：内容 = P1 能力口与事件载荷端口、S0–S4、设置行值封顶 42%、
  一批过期与多余的解释句。**connector 0.1.21 一并发了**：`v*` 标签本来就会发插件
  （`publish-connector.yml:19` 同时监听 `v*` 与 `connector-v*`，发布步没有标签守卫），npm
  `latest` 现在就是 0.1.21（带 SLSA provenance）；它缺的三条链往返仍未验，见下一步 0。
- **分层现状**（PR #9 → main `47b3472`）：`data → wire` 走能力口（`HostReads` 18 / `HostWrites`
  22，`HostRpcHolder` 两个 getter），事件载荷走 `EventFields` 端口（core 声明、wire 实现）；
  `core → wire` 与 `data/`、`ui/`、`core/` 的 `wire/` import 都是 **0**。`data/` 字段名读点
  **22 → 0**，门禁 `data-no-field-name` 钉住（把线上字段名当字面量传给 `fieldOf` /
  `stringField` / `intField` 即红，报行号）。代价：5 个测试文件因"字段名撞端口方法名"改名、
  端口返回 `SnapshotReply` 三态、`core → model` 多了一条纯类型环。
- **存储与主机**：`HostScope` + 装饰器 + v2→v3 迁移，**换电脑不再清库**（`clear()` 删掉只剩
  `clearScope()`）；`HostSessions` 按 `hostId` 池化（切电脑 = 换可见指针，跨台通知 id 带主机
  前缀）；`AppServices` 持唯一 `NotifyPort`。**未做**：S5（AppModel 切片、`chat_page` 拆文件）。
- **真机验收**：真机库副本（24.5 MB）喂 v2→v3 —— 4136 条条目一条不少、14 个水位键全带前缀、
  `device.*` 原样；debug 包装机实测迁移（未分域行 0、无崩溃，验完复原空 v3）。**唯一没验**：
  两台电脑同时配对后切电脑外观不回默认（要两次扫码）。
- **生产中转已更新到 v0.2.9 代码**（`dsh.0t0.me`，华为云 `/opt/dsh-mobile`，`6c9d906`）：镜像重建 +
  重启，含"匿名管理桶按真实来源地址分"那条修复。重启踩到一颗雷 —— 令牌表里两条记录都绑
  `connectorId: local`（两个租户的电脑都用默认 `pcId`），中转**拒绝启动**，停了约 4 分钟；清掉
  其中一条的绑定后恢复。根因与候选修法见
  `proposed/2026-11-06-connector-pcid-collides-across-tenants.md`，重启前自检步骤已写进
  `docs/cookbook/relay-on-a-server.md` §6.6。
- **门禁**：app 1761 / boundary 833（29 条自检 + 188 文件）/ connector 836 / relay 174 /
  protocol 454·26·49；`dart analyze --fatal-infos` 与 `dart format` 各 0。

## 下一步

0. **connector 0.1.21 已上线，但三条链真实往返仍未验**（投影 / 子代理 / 审批）—— 真宿主上只做到
   "插件起来、13 个能力位全亮" + 双轨判定。npm `latest` 已是 0.1.21，所以 0.2.2 线的用户装到的
   就是它。测法与隔离环境见 `proposed/2026-11-05-022-rollout-handoff.md`；发现问题就
   `npm deprecate` + 补丁版，别悄悄改 `dist-tag`（0.2.1 宿主靠 `engines` 判到 0.1.20）。
1. **`pcId` 默认 `local` 在多租户中转上必撞**（选址待定）：新装用随机 id，还是由
   `pcSignPubHex` 派生（后者等于全部重新配对）—— 见上面那条 proposed 笔记。
2. **数据面收敛（三批已落地）**：触发源按来源拆、行只带手机读的五个投影键、列表分页、
   重连带落盘水位、十个只读快照带 `digest`、出站账补齐。留给以后的：`permission.catalog` /
   `repo.info` 仍在 `connectLanding`；`session.projections` 仍是 20+ 键一整包；权限预设目录
   的真机验收；摘要表是每进程的（冷启动要十份快照正文）。
3. **多设备并发准入真机复验**：两台手机同时连同一台电脑；吊销 A 后 B 仍在线。两条关闭路径
   分开看 —— A 答完时 B 由会话事件（`approval/decided` / `tool/result`）关门，B 迟一步再答
   才拿 `interaction/not-pending`；单测已钉，端到端要两台真机。
4. **状态语义对齐（A–H 已落地）**：真机复验还差 4 条（子智能体在跑可见、提问草稿、
   发送模式真值、断连重连）。
5. 真机复验改动卡 / 差异 / 提及（要模型请求 —— 先报价再跑）。
6. `usage.summary` 的 byDay 时区；`plugin.installStatus` 的 4 键/8 键两形态。
7. 大改后巡检 `docs/` 与代码漂移。已知一处：`connector/src/dsh/interaction-client.ts:63`
   import 了 `transport/backoff.js`，与 `connector-and-relay.md` §1.2 的「`dsh/` 不 import
   `transport/`」矛盾。
8. **投影包按消费者拆**（方案 `proposed/2026-11-04-projection-payload-split.md`，未实现）。

## 门禁（改代码后必须全绿，项数以 `tools.md` 为准）

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | 454 / 26 / 49 项 |
| `node app/tools/verify-platform-boundary.mjs` | 833 项（29 条规则自检 + 188 个 Dart 文件） |
| `node app/tools/verify-rpc-single-caller.mjs` | `app/lib`（`wire/` 外）零 `call<` |
| `node mock/proto/tools/verify-{icons.cjs,tool-paths.mjs}` | 图标集 / 24 个工具脚本无硬编码盘符 |
| `cd app && flutter test` | 1761 项（约 1 分钟） |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format` | 各 0 |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + **836** 项 |
| `cd relay && pnpm typecheck && node --test` | 类型 + **174** 条 |

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

- 隔离实例：`$env:DSH_HOME='D:\tmp\dsh-mobile-home'` + `dsh --profile dsh-mobile-test`；
  `--profile` 只隔进程/插件/端口，`~/.dsh/{.credentials.yaml,sessions,storages}` 共用 ——
  **跑之前报轮次并拿到准**（花用户的钱）。
- 装 App 一律 `flutter build apk --debug` + `adb install -r`（`flutter install` 会先卸载）。

## 仍未注意就会翻车

- **改源码只用编辑工具**（shell 替换静默出错）；**`dart format` 会重排文件**，之后再编辑要重读。
- **同一件事只有一处判据**（重建哪条通道 / 起传输容忍什么 / 面板读什么）：都已有同名模块 +
  回归用例（`transport/rebuild.ts`、`transport/startup.ts`、`connection-card.ts`），别在
  `index.ts` 再写；坑点见 `tools.md`。

## 已知缺口（仍在）

- 计划审查卡手机上不存在（**有意**，契约 §15）；保存「连接」卡后只轮询 6 秒判是否连上，
  慢网会停在"重连中"；「清空全部记录」会把还在用的离线设备一起删掉（确认框里写明）；
  上述"未验"各项仍在。
- **已落盘的旧历史修不回来**：合并载荷只从写入路径开始生效（`2026-11-04-merged-payload-on-write`
  的结论）；要修历史得单独做一次 `session.page` 重放，未做。

## 已落地索引

- 2026-09-30 通道协议定稿 / 配对 v1 / 连接层拆分 — `implemented/2026-09-30-*`、`2026-10-01-*`
- 2026-10-02 安卓里程碑 / 主题层 / 图标 / 本地库 / 配对 — `implemented/2026-10-02-*`
- 2026-10-07..09 配对 v2、设备身份、三处线上形状错 — `implemented/2026-10-0[789]-*`
- 2026-10-13..17 交互链、审批/提问、发送模式、端点切换、标题、设置页 — `implemented/2026-10-1[3-7]-*`
- 2026-10-19..24 渲染对齐、轨迹/轮组、用量、文件页、插件、任务、通知 — `implemented/2026-10-19-*`..`24-*`
- 2026-10-25 RPC 应答面收口（8 批） — `implemented/2026-10-25-wire-*`
- 2026-10-26 评审六批 + 真实清单进金样 + 桌面四件事 + 连通落点 — `implemented/2026-10-26-*`
- 2026-10-27 UI 状态语义（审计 → 机制 → A–H 批） — `implemented/2026-10-27-*`
- 2026-10-28 渲染批次 + 唤醒判据修正 — `implemented/2026-10-28-*`
- 2026-10-29 连接卡 / 无令牌可挂载 / 装配层回归网 / 端点剪枝 / 明文两档 — `implemented/2026-10-29-*`
- 2026-10-30 多机四步 + 中转可观测·限额·面板 — `implemented/2026-10-30-*`
- 2026-11-04 轨迹页重读、目标条、中转三块收口 — `implemented/2026-11-04-*`
- 2026-11-05 双轨版本线 / 撤独占准入 — `implemented/2026-11-05-*`
- 2026-11-06 S2 存储分域 / S4 主机池 / HostRpc 能力口 / 事件载荷端口 — `implemented/2026-11-06-*`
