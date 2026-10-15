# Agent Note: `session.create` 补上 —— "契约有、App 有、中间层空着"

Status: implemented

## Problem

手机点"新建会话"只回一句 `新建会话（session/create: connector/unsupported）`。

三边都像接了,唯独中间是空的:
- **契约 §5.7** 有 `session.create` 这一行(还标着"本期未实现");
- **`app/lib/data/app_model.dart` 的 `createSession()`** 写全了(带幂等键、建完打开、塞进列表);
- **`connector/src/handlers.ts`** 里没有这个 handler —— `repo.info` 报的表的键来自
  `Object.keys(handlers)`,所以手机侧看到的是"这台没这个方法"。

## Decision

**照 DSH 的形状透传,且一个字段都不替电脑猜。**

- `SessionController.create`(`packages/api/session-controller/src/index.ts:280`)
  请求 `{workspaceId?, cwd?, sessionId?, agentPreset?}`,回 `{sessionId, agentPreset?}`
  (`src/types.ts:288,296`)。
- **`workspaceId` / `cwd` 都不传**:手机侧不知道电脑有哪些工作区(那要另接
  `workspace-controller` 的 `@Remote('list')`),而不传时 DSH 用它自己的当前工作区 ——
  与 Web 上点"新建会话"一致。硬传一个猜的比不传更糟。
- **只在给了参数时才进请求体**:DSH 对缺省字段有自己的默认(当前工作区 / 默认预设),
  塞空串会被当成"显式选空"。
- **带幂等键**(`IDEMPOTENT_METHODS` 里本来就有它):点了两次不该建出两个会话。

## Alternatives considered

1. 让手机传 `cwd`(用户手输或从某处选)
   - 最强的理由:用户可能想在别的目录开会话。
   - 为何被否:手机侧没有工作区清单这个信息源,手输一个路径的错误率极高,
     而建错的会话**删不掉**(`workspace-controller` 的 `delete` 也没接)。
     先把"能在当前工作区新建"做对,比给一个会建错的功能好。
2. 建在本地、等同步
   - 最强的理由:零延迟,断线也能建。
   - 为何被否:会话的 owner 是电脑侧(标题推导、事件序号、待处理收件箱都在它那里),
     本地建一个会让 sid 与电脑侧对不上,而症状是"建了但发不出去"。

## Consequences

- 收益:新建会话这条链从"三边齐全中间空"变成真能建;`repo.info` 的表多一个键,
  手机上那个按钮从灰的变成能用的。
- 代价:
  - 手机侧仍**不能选工作区**(要另接 `workspace-controller`,本期不做);
  - 契约 §5.7 的"本期未实现"标记与 §5.8 / §9 的三处描述已改成当下事实;
    **方法数仍是 24** —— 这个方法本来就在封闭集里,所以 `methods.test.ts` 与
    `method-name-table.test.ts` 两道计数门禁不会因它红,红的是各处
    "实现清单"的期望数组(`handlers.test.ts` 4 处 + `connection-methods.test.ts` 1 处)。

## 验证

- `connector/tests/session-create.test.ts`(新,5 条):空参数时请求体是 `{}`、
  给了的参数原样过线、非字符串字段在本地就拦(`protocol/bad-frame` 且不问 DSH)、
  DSH 侧失败照旧抛。
- connector `pnpm test` **389** 全绿 + `tsc` + `build`;
  app `flutter test` **464**、`dart analyze --fatal-infos` 干净;
  protocol 486·26·49、平台边界 204、relay 75 全绿。

## 同源缺口(尚未接的 `@Remote`,事实记录)

`session.rename` / `session.fork` / `session.search` / `session.attachment` /
`session.updateQueue` / `session.openWorkspacePath` / `workspacePathApplications`,
以及 `workspace-controller`、`settings-controller`、`workspace-files`、
`terminal-controller`、`account-controller`、`llm`、`skill-catalog`、
`permission-presets`、`subagent`(写面)、`commands` 的全套 `@Remote`。
这些面的读取次序见 `.agents/notes/proposed/2026-10-15-phone-surface-inventory.md`。
