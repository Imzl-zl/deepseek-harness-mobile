# Agent Note: DSH 0.2.2 兼容核对结论（连接器不需要改代码，只差真机确认）

Status: implemented

## Problem

DSH 进 `0.2.2` 线后，需要回答一个问题：**连接器要不要改代码？** 判错的两种代价都很贵 ——
说"不用改"但运行时解析崩，用户看到的是静默失败；说"要改"则凭空造出一轮迁移。

核对范围：`0.2.1-rc.5`（旧基线）→ `0.2.2-rc.1`（新线首个 rc）。

## 核对结果

**结论：代码不改，只抬清单。** 依据分四层。

| 层 | 手段 | 结果 |
|---|---|---|
| 类型 | 把 devDeps 钉到 `0.2.2-rc.1`，`tsc --noEmit` | 0 错（`interaction-face.ts` 的 `QuestionIntent` 已在迁移中补过 `approval` 分支） |
| 行为 | `pnpm test` | 847/847 |
| 升级条目 | `docs/upgrade-guide/v0.2.2-alpha.2/` 21 条 + `alpha.3/` 2 条逐条判 | 仅 1 条半命中，见下 |
| 字符串键 | 服务键 / 事件键 / bundle 挂载点逐个核发行源码 | 全部仍在，无改名 |

## 逐条判定

**命中（1 条，且不是破坏）**

- `subagent-names`：`subagentCatalog` 写 v3 载荷，新增同级唯一 `name`
  （`packages/subagent/subagent/src/catalog.ts:40`）。旧字段 `childId` / `mode` / `label` 全保留，
  所以解析不会崩；缺的是**呈现**——没配 label 的行在手机上显示的是一串会话 UUID。
  已在 `app/lib/core/job.dart` 补 `name` 解析，`displayLabel` 改成
  「label → name → id」。取法照 DSH：`entry.name ?? entry.id`
  （`packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:211-214`）。

**不命中（各有一条具体理由，不是"看着像没关系"）**

- `projection-event-frames`：改的是 `session/control` 与 `observeProjections` 的**流式帧**。
  我们读 `@Remote('projections')` 请求/响应（`connector/src/dsh/projections.ts:88`），不订阅这两条流。
- `projection-snapshot-scope`：`session.list` 摘要不再带 `contextPressure` / `contextBreakdown`。
  手机的这两项来自**全量投影**（`app/lib/data/app_model.dart:729`、`:735` 读
  `wire.SessionProjections`），不从列表行读。另外我们调 `snapshot(session, keys)` 本来就带 keys
  （`connector/src/dsh/models.ts:144`），`cachedSnapshot` 一次都没用。
- 其余 19 条：Web 客户端 UI（右键菜单 / CSS 锚点 / 会话操作菜单）、desktop 更新渠道、
  PTC 超时、schedule 工具、web-search 凭据、forge、cua、SDK run、loader 子类、
  fs 观察策略、LLM 用途声明、pi-ai 图片裁剪、Team owner —— 都不在我们消费的面上。

## 字符串键核对（tsc 看不见的那一半）

`ctx.get('…')` 与 `ctx.on('…')` 的键是字符串，宿主改名不会报错，只会**静默失效**。逐个核过：

| 键 | 0.2.2-rc.1 位置 | 挂载 |
|---|---|---|
| `workspaceChanges` | `packages/deliverables/workspace-changes/src/index.ts:120` | `bundle/web-app/cordis.patch.yml:370-371` |
| `workspaceFiles` | `packages/api/workspace-files/src/index.ts:200` | `bundle/web-app/cordis.patch.yml:128-129` |
| `sessionReferenceResolver` | `packages/context/session-reference/src/index.ts:100` | `bundle/web-app/cordis.patch.yml:90-91` |
| `pluginManager` | `packages/boot/plugin-manager/src/index.ts:358` | `bundle/base/cordis.patch.yml:20-21` |
| `credentials/record-updated` | `packages/credentials/credentials/src/types.ts:99` | 经 `packages/api/remotes/src/remote-events.ts:38` 转发 |
| `credentials/reference-updated` | 同文件 `:87` | 同 `:39` |
| `llm/adapters-updated` | `packages/llm/llm/src/types.ts:24` | 同 `:47` |
| `permission-presets/catalog-changed` | `packages/interaction/permission-presets/src/types.ts:48` | 同 `:49` |
| `settings/document-updated` | `packages/settings/settings/src/types.ts:75` | 同 `:55` |
| `subagent/catalog` | `packages/subagent/subagent/src/catalog.ts:52` | — |

投影信封也没变：`SessionProjectionsValue` 仍是
`{kind:'sequenced', asOfSeq, values}` | `{kind:'migration-required', values}` | `null`
（`packages/api/session-controller/src/types.ts`），`connector/src/dsh/projections.ts` 的拆信封逻辑继续成立。

## 双轨判定的实测（两代真宿主）

隔离方式：`DSH_HOME` 指向测试目录内的 `home`（0.2.2-rc.1）与 `home021`（0.2.1-rc.5），
两代宿主互不干扰，未触碰 `~/.dsh`。

| 插件版本 | 0.2.1-rc.5 宿主 | 0.2.2-rc.1 宿主 |
|---|---|---|
| `0.1.20`（`>=0.2.1-rc.5 <0.2.2`） | 接受并组合 | **也接受** —— 旧上界的缺陷：放行 0.2.2 预发布 |
| `0.1.21`（`>=0.2.2-rc.1 <0.2.3-0`） | **拒绝**，原文 `installation rejected: Plugin dsh-mobile-connector@0.1.21 is incompatible with dsh 0.2.1-rc.5: requirements {"engines.dsh":">=0.2.2-rc.1 <0.2.3-0"}`，并回滚 `package.json` / `pnpm-lock.yaml` / `node_modules` | 接受并组合 |

在 0.2.2-rc.1 上另做了运行时确认：连接器激活后
`GET /api/dsh-mobile/status` 的 13 个能力位全为 `true`
（`sessions storage approval questions jobs subagents references plugins files changes settings credentials direct`），
也就是每个 `present(ctx, '<服务键>')` 都在真实宿主上解析到了 —— 上面那张字符串键表从源码级证据升到运行级。

## 仍未验证 / 一条单向门

- **三条链没有真实往返**：投影 / 子代理 / 审批需要已配对的手机客户端。真宿主上验过的是
  加载、激活、能力位与 host 版本读取；数据形状靠类型、847 条单测、Flutter 实测与上面的源码核对，
  没有一次真实的手机⇄电脑往返。单测用的是替身，覆盖不到真实宿主的形状 —— 这条限制写在
  `docs/cookbook/release.md` §3 的抬线 playbook 第 4 步。
- `subagentCatalog` v3 是**持久化单向门**：0.2.2 写下的目录，0.2.1 拒绝打开
  （`docs/persistence-changes/2026-11-02-subagent-catalog-names.zh.md`）。
  它不影响本插件，但决定了「不能靠多留几条版本线求稳」，见
  `2026-11-05-dual-track-host-version-lines.md`。

## Consequences

- 0.2.2 抬线是**清单 + 文档**动作，不是代码迁移；`0.1.21` 与 `0.1.20` 的代码差异只有 `name` 呈现。
- 下一次抬线可以直接复用这份核对顺序：类型 → 单测 → 升级条目 → 字符串键 → 真机。
- 记法补进 `tools.md` 的兼容性坑点，避免下次只跑 `tsc` 就下结论。
