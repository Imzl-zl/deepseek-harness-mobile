# dsh-mobile 项目状态

> 快照 + 最近窗口，**覆盖更新**，不做流水追加。历史在 git 与 `.agents/notes/`；
> 稳定命令与坑点在 `tools.md`；现状事实在 `docs/`。

## 现在（2026-10-26）

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
- **UI**：会话/抽屉/输入区/审批与提问/任务/文件/@ 候选/插件/设置/用量/轨迹页全部接真数据；
  真机验收到 2026-10-24（W3/W4 四项）。
- **未验**：图片上限四条、`readBytes` 预览、插件安装/卸载的真实 pnpm 流程；
  桌面四件事的真机验收（改动卡 / 差异 / 正文提及待验；**分支已真机通过**：
  子会话标题 `dsh-model-desk (1)` 自动打开）；`caps.changes` 在真机上是否 true **待查**；
  计划审查卡**有意不接**。

## 下一步

1. 真机复验上面四项（各要模型请求 —— 先报价再跑）。
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
| `node app/tools/verify-platform-boundary.mjs` | 587 项（25 条规则自检 + 136 个 Dart 文件） |
| `node app/tools/verify-rpc-single-caller.mjs` | `app/lib`（`wire/` 外）零 `call<` |
| `node mock/proto/tools/verify-{icons.cjs,tool-paths.mjs}` | 图标集 / 24 个工具脚本无硬编码盘符 |
| `cd app && flutter test` | 1381 项 |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format` | 各 0 |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + 685 项 |
| `cd relay && pnpm typecheck && pnpm test` | 类型 + 87 条 |

**改断言必须做一次变异校验**（故意破坏不变量，确认恰好那几条红，条数写进提交）。

## 真机联调的成本纪律

- 隔离实例：`$env:DSH_HOME='D:\tmp\dsh-e2e'` + `dsh --profile <name>`；`--profile` 只隔进程/插件/端口，
  `~/.dsh/{.credentials.yaml,sessions,storages}` 全局共用。**跑之前报轮次并拿到准**（审批探针花用户的钱）。
- 这台机器是 root（KernelSU）；长按拖动只能 `sendevent` 注，`input swipe` 做不出落点。
- 装 App 一律 `flutter build apk --debug` + `adb install -r`；`flutter install` 会先卸载（凭据全没）。
- 屏幕灭 = 引擎暂停 ⇒ `adb shell svc power stayon true`。

## 仍未注意就会翻车

- **改源码只用编辑工具**，不用 shell 字符串替换（shell 出错是静默的）。
- **`dart format` 会重排文件**；之后再编辑同一文件要**重新读一遍**。
- 其余稳定坑点见 `tools.md` → Pitfalls。

## 已知缺口（仍在）

- 计划审查卡手机上不存在（**有意**，契约 §15）。
- 停用设备的"明说"在**中转链路**看不到，直连能看到（写进契约 §15）。
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
