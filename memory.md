# dsh-mobile 项目状态

> 快照 + 最近窗口，**覆盖更新**，不做流水追加。历史在 git 与 `.agents/notes/`；
> 稳定命令与坑点在 `tools.md`；现状事实在 `docs/`。

## 现在（2026-10-28）

- **真机验收（2026-10-28，设备 d61cf622，隔离 home `D:\tmp\dsh-mobile-home`）**：
  代码高亮 / Markdown 预览 / 唤醒通知 / 任务状态 / 文件四类错误码七条全过，
  途中抓到并修掉一处真问题：**唤醒判据只认 `inbox-next-turn`** —— 宿主给子智能体的
  `agent-message` / `subagent-settled` 走的是 `next-step`（空闲时由 claim 开一轮），
  于是桌面上是「收到任务消息」的那一行手机上显示「上下文注入 · agent-message」，
  「子任务状态更新」一次都不出现。修法是照抄 DSH 的 `idleSteer` 分支
  （`dsh-client-ui-chat/lib/client.js:9857-9866`）；笔记
  `implemented/2026-10-28-turn-trigger-idle-steer.md`，现状事实 `docs/subsystems/turn-groups.md` §6.1。
  同批把预览页的「读取失败：」前缀去掉（四类码的整句由 `model/file_failure.dart` 给，
  加前缀会变成「读取失败：找不到这个文件」，桌面只画那一句）。
- **配对生命周期真机复验（2026-10-29，公司 wifi / Windows 判成「公用」）**：
  `07df938` 通过 —— 同机重配走 `replaces`：新行先与旧行并存、旧令牌仍可用，
  新身份握手成功后旧行被裁，且 `pairedAt` 沿用被替换那行（真机：3 行 → 2 行 → 清理后 1 行）；
  确认页会写「这次会换新密钥并替换那条记录，不会新增一行」。
  `dc3ce54` 通过 —— 故意改坏 `code` 的一位后确认，页面如实报
  「配对秘密或连接身份不匹配，请重新核对二维码（protocol/not-paired）」，不是静默；
  格式坏的载荷报「二维码不是合法 JSON（protocol/not-paired）」。
  环境两条：① 公用网络下 8787/8790 的入站被拦（规则只对 `node.exe` / `DeepSeek Harness.exe`
  放行，其它端口一律 RST），要么改专用网络、要么 `adb reverse` 走环回；
  ② 手机灭屏时 `input tap` 全被吞（`svc power stayon` 与 30 分钟超时都不管用），
  只能 `input keyevent 26` 唤醒 + `82` 解屏，且**别连按两次 26**（会把刚亮的屏再关掉）。
- **代码高亮语言集比桌面宽（28 种 vs ts/bash/json）**：这是渲染能力的扩展，数据源同一处
  （围栏 info string），已写进 `docs/subsystems/app-channel-client.md` §4.1 的「有意偏离」，
  笔记 `implemented/2026-10-29-code-highlight-language-set-wider-than-desktop.md`。
- **端点表按"哪台电脑报的"剪枝（2026-10-29）**：`Endpoint` 多一个客户端字段 `hostId`
  （= 那台电脑的 Ed25519 公钥 `pcSignPubHex`；**不用 `pcId`**，它是连接器 id，默认
  `"local"` 会撞），换电脑后旧电脑报过的自动条目直接剪掉（手填的永不动），
  并顺手清掉指向已删条目的"记住的那条"、把成功集裁到表内。
  同批给 `dialOrder` 加了**失败冷却**（失败距今 < 60s 的排队尾，**连记住的那条也不例外**，
  窗口一过回原位、成功即清）和**按电脑排序**（别的电脑报的排当前电脑之后、不删），
  `EndpointAttempt` 因此带了 `atMs`。真机账：表里两条 VMware 死地址原本每次冷启动
  白等 `3s×2`。理由与三个被否方案见 `implemented/2026-10-29-endpoint-host-scoped-pruning.md`；
  设计面 `docs/subsystems/app-channel-client.md` §6.2（一张表）。adb 转发不是端点的一种：
  真实用法是公网中转或局域网直连。
- **明文放行分两档（2026-10-29）**：非公网 `ws://`（局域网 / 回环 / 组网 CGNAT）**所有构建都用**；
  公网 `ws://`（自部署中转、暂无域名/证书）**只认用户显式确认**（偏好 `net.allow_plaintext_public`，
  确认点只有两个：手填端点勾选、配对页确认卡）。`wss://` 任何主机始终放行。
  理由：原来 `allowInsecureLocal: kDebugMode` 让 release 连局域网/组网直连都用不了；
  取舍与被否方案见 `implemented/2026-10-29-plaintext-public-relay-for-self-hosting.md`，
  现状 `docs/subsystems/app-channel-client.md` §6.2。自签证书 + 钉指纹仍留作下一步。
- **通道**：`protocol/`（配对 / 握手 / AEAD / 流控 / 恢复）+ `relay/`（中转）+ `connector/`（电脑侧网关）
  全部落地；手机侧 `app/lib/core/` 是连接层，`app/lib/wire/` 是**线上形状的唯一解码层**。
- **RPC 应答面（2026-10-26）**：`wire/rpc/` 18 个面文件、46 个方法；`app/lib`（`wire/` 外）
  零 `call<`；金样 46 个方法，`session.list` 有第二条**真实清单**样本（20 种形状）。
- **方法面 52/50**（差额 2 = `credentials.set` / `credentials.unset`）；改动卡与逐行差异的数据
  只来自桌面记录（`file.changes` / `file.diff` → 宿主 `workspaceChanges`），
  `docs/subsystems/changes-card.md`；分支走宿主 `session.fork`，
  `docs/subsystems/session-fork.md`。
  笔记 `implemented/2026-10-25-wire-rpc-layer-layout.md`。
- **2026-10-26 评审修复（六批）**：页级失败单通道、任务合并纯函数、必填口径、
  信封/值单一入口、门禁扩到全域、回指与死代码。笔记 `implemented/2026-10-26-wire-review-fixes.md`。
- **2026-10-26 发版清理**：产品里的「看示例数据」与「＋ → 演示：接管输入栏」已删除
  （示例内容搬进 `app/test/support/`，注入走两个 `@visibleForTesting` 缝）。
  笔记 `implemented/2026-10-26-remove-preview-and-demo.md`。
  **真机已验证**：删演示后重新扫码配对成功；停 relay 冷启动 **118ms 直连** 8790，
  留存端点生效（`endpoint.describe` 需在一次 serving 后才落盘）。
- **桌面四件事对齐（2026-10-26）**：正文提及 → `openFile` 预览；收口改动卡 + `file.changes`；
  逐行差异 `file.diff` + 共用 `DiffView`（手机上限 1000 行）；收口分支 `session.fork`
  （标题后缀在连接器）。笔记 `implemented/2026-10-26-desktop-alignment-plan.md` 与四篇实现笔记；
  文档 `prose-file-mentions.md` / `changes-card.md` / `session-fork.md`。
- **连通落点（2026-10-26）**：连上后落在「上次看的 → 在跑的 → 最近更新 → 空白」四档；
  桌面"当前打开哪个"是浏览器本地状态，宿主没有，手机不追。文档 `connect-landing.md`；
  笔记 `implemented/2026-10-26-connect-landing.md`。运行态来自 `session.list.running` +
  `api-session/status` 帧（落点选中在跑的会话就直接显示运行条）。
- **真机 UI 状态复验（2026-10-27，设备 d61cf622）**：抽屉折叠跨重启、页签按会话 +
  跨重启、草稿恢复不弹键盘、门槛四态(3/4)、模型回落宿主默认、设备库 schema=2 均**实测通过**。
  途中抓到并修掉两个真问题：①连上后落点被 blank 复用抢占（`ba534b8`，真机上曾让页签/草稿
  看起来"没恢复"，还覆盖 `host.last_session`）；②抽屉每组全渲染 + 搜索框是死控件
  （`490fa5f`，按桌面 watermark=5 + 「展开其余 N 个会话」+ 接通搜索）。
  真机**未测/阻塞**：子智能体在跑可见与提问草稿（免费渠道对 agent 真实请求回 403，裸/带 tools/流式
  单独打都 200）；发送模式真值（**「设置」页整屏白屏**，零语义节点、无 Flutter 异常 —— 新发现的待修问题）。
  断连重连**部分通过**：停/恢复中转后自动回「已连接」且同一会话还在；抽屉/页签/草稿无存量可验
  （本轮重新配对按设计清空了 `host.*`）。判据与截图见 `docs/subsystems/ui-state.md` §8。
- **UI**：会话/抽屉/输入区/审批与提问/任务/文件/@ 候选/插件/设置/用量/轨迹页全部接真数据；
  真机验收到 2026-10-24（W3/W4 四项）。
- **换网连不上（2026-10-26）**：连接 sheet 加「手动填写电脑地址」—— 只加进表、不自动拨，
  由用户在「换个连接方式」里选它连；配对凭据与地址无关，不需要重新扫码。
  文档 `app-channel-client.md` §6.1；笔记 `implemented/2026-10-26-manual-endpoint-entry.md`。
- **未验**：图片上限四条、`readBytes` 预览、插件安装/卸载的真实 pnpm 流程；
  桌面四件事的真机验收（**分支已通过**：子会话标题 `dsh-model-desk (1)` 自动打开；
  改动卡 / 差异 / 正文提及需要一轮**在当前宿主进程里跑完**的对话 —— 记录是内存态，
  重启即丢，桌面同样不画卡）；`caps.changes` 真机 **true**（已验证，事件也到手机）；
  计划审查卡**有意不接**。

## 下一步

0. **状态语义对齐（A–H 已全落地）**：现状事实在 `docs/subsystems/ui-state.md`；
   因果在 `implemented/2026-10-27-state-semantics-mechanism-decisions.md` 与
   `implemented/2026-10-27-appmodel-narrowing.md`；`guarded.dart` **决定不做**。
   真机复验补齐 4 条：子智能体在跑可见、提问草稿、发送模式真值、断连重连
   （要一次能跑完的模型请求 + 在线设备）。
1. 跑一轮真机复验改动卡 / 差异 / 提及（要模型请求 —— 先报价再跑）。
2. `usage.summary` 的 byDay 时区；`plugin.installStatus` 的 4 键/8 键两形态
   （真出现第二种时 `readPluginJob` 会红，属**已知的下一处**）。
3. 大改后巡检一次 `docs/` 与代码的漂移。

## 九条教训

1. **投影信封**：`session.projections` 回 `{kind, asOfSeq, values}`，手机要 `values`（整包透传曾让统计条全空）。
2. **模型目录是对象**（`{default, routableProviders, groups, failures}`）不是数组；认错形状曾一次没成功过。
3. `session/select-model` **没有"不能写"约束**：别把测试纪律升成产品约束。
4. **"空"有两种表达**：`items.isEmpty` 漏了 `OtherItem`；`usage == null` 漏了"字段齐全但全零"。
5. **判据要能区分"没命中"与"没实现"**：先一行 `debugPrint` 确认回调跑了，再怀疑手势。
6. **一个功能一次提交完整**：提交前 `git status --porcelain` 必须只剩有意的文件。
7. **生产路径上的假数据最容易漏**（不报错、不空屏，只是名字/数字是编的）。
8. **线上预算按帧算**：二进制 `N` → JSON base64 → box 再 base64url ≈ `1.78N`。
9. **用例喂的形状必须是线上形状**：真机事件/真库行先 dump 再写断言；
   字段类型只在 `wire/` 断言，回放真机样本。

## 门禁（改代码后必须全绿，项数以 `tools.md` 为准）

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | 454 / 26 / 49 项 |
| `node app/tools/verify-platform-boundary.mjs` | 639 项（25 条规则自检 + 148 个 Dart 文件） |
| `node app/tools/verify-rpc-single-caller.mjs` | `app/lib`（`wire/` 外）零 `call<` |
| `node mock/proto/tools/verify-{icons.cjs,tool-paths.mjs}` | 图标集 / 24 个工具脚本无硬编码盘符 |
| `cd app && flutter test` | 1528 项 |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format` | 各 0 |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + 689 项 |
| `cd relay && pnpm typecheck && pnpm test` | 类型 + 89 条 |

**改断言必须做一次变异校验**（故意破坏不变量，确认恰好那几条红，条数写进提交）。

## 真机联调的成本纪律

- 隔离实例：`$env:DSH_HOME='D:\tmp\dsh-e2e'` + `dsh --profile <name>`；`--profile` 只隔进程/插件/端口，
  `~/.dsh/{.credentials.yaml,sessions,storages}` 全局共用。**跑之前报轮次并拿到准**（审批探针花用户的钱）。
- 这台机器是 root（KernelSU）；长按拖动只能 `sendevent` 注，`input swipe` 做不出落点。
- 装 App 一律 `flutter build apk --debug` + `adb install -r`；`flutter install` 会先卸载（凭据全没）。
- 屏幕灭 = 引擎暂停 ⇒ `adb shell svc power stayon true`。

## 仍未注意就会翻车

- **改源码只用编辑工具**（shell 替换静默出错）；**`dart format` 会重排文件**，之后再编辑要重读。
- 其余稳定坑点见 `tools.md` → Pitfalls。

## 已知缺口（仍在）

- 计划审查卡手机上不存在（**有意**，契约 §15）；停用设备的"明说"在**中转链路**看不到（直连能看到）。
- 上述"未验"各项（含桌面四件事的真机验收）。

## 已落地索引

- 2026-09-30 通道协议定稿 / 配对 v1 / 连接层拆分 — `implemented/2026-09-30-*`、`2026-10-01-*`
- 2026-10-02 安卓里程碑 / 主题层 / 图标 / 本地库 / 配对 — `implemented/2026-10-02-*`
- 2026-10-07..09 配对 v2、设备身份、三处线上形状错 — `implemented/2026-10-0[789]-*`
- 2026-10-13..17 交互链、审批/提问、发送模式、端点切换、标题、设置页 — `implemented/2026-10-1[3-7]-*`
- 2026-10-19..24 渲染对齐、轨迹/轮组、用量、文件页、插件、任务、通知 — `implemented/2026-10-19-*`..`2026-10-24-*`
- 2026-10-25 RPC 应答面收口（8 批） — `implemented/2026-10-25-wire-*`
- 2026-10-26 评审六批 + 真实清单进金样 — `implemented/2026-10-26-wire-review-fixes.md`
- 2026-10-26 桌面四件事（提及 / 改动卡 / 差异 / 分支）— `implemented/2026-10-26-desktop-alignment-plan.md` 与四篇实现笔记
- 2026-10-26 真机对照修正（模型 pill fallback / 分支静默）+ 连通落点 — `implemented/2026-10-26-device-alignment-fixes.md`、`2026-10-26-connect-landing.md`
- 2026-10-27 UI 状态语义（审计 → 机制 → A–H 批）— `implemented/2026-10-27-state-semantics-mechanism-decisions.md`；
  现状事实 `docs/subsystems/ui-state.md`；审计/设计仍 `proposed/2026-10-27-*`
- 2026-10-27 真机复验修正 — `implemented/2026-10-27-connect-landing-single-path.md`（落点单一路径）、
  `implemented/2026-10-27-drawer-watermark-and-search.md`（抽屉 watermark + 搜索接线）
- 2026-10-28 渲染批次（高亮 / Markdown / 唤醒通知 / 错误码 / 配对生命周期）—
  `implemented/2026-10-28-code-highlight-with-re-highlight.md`、
  `implemented/2026-10-28-file-preview-error-codes.md`、
  `implemented/2026-10-28-atomic-repair-keeps-old-device-row.md`、
  **`implemented/2026-10-28-turn-trigger-idle-steer.md`**（真机验收抓到的唤醒判据缺陷）
