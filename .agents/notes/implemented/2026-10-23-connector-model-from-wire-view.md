# Agent Note: 连接器的模型从 **wire view** 读，不从宿主 state 读

Status: implemented（2026-10-23）。

## 起因

审查清单 I1（`proposed/2026-10-23-subagent-parent-and-model-truth-review.md` §2）：

`connector/src/dsh/models.ts` 的 `modelOf` 用 `sessionProjections.stateOf(...)` 的返回去读
`.next` —— 而 `stateOf` 给的是**宿主 state**，字段叫 `pending`，所以 `.next` 恒 `undefined`，
`??` 永远落到 `lastUsed`：顶层 `model` 的实际语义是"上一次请求用的"。

三处文档承诺的却是 `next ?? lastUsed`：`app/lib/model/chat_item.dart:852-858`、
`models.ts` 的 `modelOf` 文档注释、以及
`implemented/2026-10-23-subagent-composer-model-and-mode-source.md` 的改法一节。

**测试为什么绿**：`connector/tests/models-face.test.ts` 的替身把**线格式**喂给了 `stateOf`
（`stateOf: () => ({lastUsed, next})`）—— 替身复现的不是真形状，"next 优先"在假数据上成立。
这与 `memory.md` 八条教训第 1/2 条的形态相同：**替身与生产各有一套形状**。

## 病根：同一事实有两个读面

| 读面 | 给什么 | 出处 |
|---|---|---|
| `stateOf(session, key)` | 宿主内部 state `{lastUsed, pending}` | `packages/session/session-projection/src/index.ts:312-328`（原文 "Read one unit's current host state"） |
| `snapshot(session, keys)` | 过 `viewSchema` 的**线格式** `{lastUsed, next}` | 同上 `:330-345`；映射在 `packages/api/session-controller/src/model-selection-projection.ts:63-65` 的 `view: state => ({lastUsed, next: state.pending ?? state.lastUsed})` |

手机侧（`app_model.dart` 的 `_modelSelectionOf`）读的一直是线格式 —— 它解析的是
`session.list` 行里的 `projections.values.modelSelection`，那已经是过 view 的值。
只有连接器读错了那一层。

## 决定

1. `modelOf` 改读 `projections.snapshot(session, ['modelSelection']).values.modelSelection`，
   取值表达式 `next ?? lastUsed` 与手机**逐字相同**。
2. 端口类型从 `stateOf(...): ModelSelectionProjectionView` 改成 snapshot 形状
   （`{values: {modelSelection?: ...}}`）—— **类型说线格式，运行时就必须给线格式**。
3. 测试替身改成**两层各实现一遍**：`stateOf` 给宿主 state、`snapshot` 给线格式（表达式照抄
   DSH 的 `view`）。新增的"刚切完模型"用例走的是 `pending` 有值、`lastUsed` 还是上一轮
   那个 —— 这一条在旧实现下必红。

## 代价与边界

- **不多一次往返**：`snapshot` 与 `stateOf` 同为同步方法，都会 `materializeCells`。
  `snapshot` 多出的工作只是按 key 过滤后过一遍 `viewSchema`，量级相同。
- **子会话仍然读不到顶层 `model`**：`agents.get(id)?.session` 对子会话是 `undefined`
  （它不在"活 agent"表里）。这一档本来就只是**老连接器兜底** —— App 的第一档是行里的
  投影提示（`_modelSelectionOf`），子会话靠那一档。改完这一档"不再给出与文档相反的
  值"，但它依然覆盖不到子会话。
- **顶层 `model` 字段是否从线上删掉**是另一个决定（老手机只认它），本轮不动。

## 判据

- `connector/tests/models-face.test.ts`「modelOf：待定优先（宿主 state 的 pending 经
  wire view 变成 next）」：`pending` 有值 ⇒ 返回待定那个；`pending` 被清 ⇒ 退回 `lastUsed`；
  两者都空 ⇒ `undefined`；别名不认识 ⇒ `undefined`。
- 变异校验：把取值改成 `view?.lastUsed ?? view?.next` ⇒ **恰好这一条**红
  （`Expected: {provider:'p', model:'new'} / Actual: {provider:'p', model:'old'}`，585/586）。
  撤回后 586 全绿；`pnpm exec tsc --noEmit` 与 `pnpm build` 同时通过。

## 被否掉的替代

- **只把端口类型改成 `{lastUsed, pending}`、取值改成 `pending ?? lastUsed`**
  - 最强理由：两行改完 `tsc` 就过，测试一行都不用动。
  - 为何被否：它把"state 与 view 是两个东西"继续藏在连接器里 —— App 读 view、连接器读
    state，同一事实在两端仍是两个名字；下一个读 `model` 的人（第二个客户端、诊断脚本）
    还得再踩一次。要修就修到"一个形状"。
- **让 `modelOf` 改读 `sessionController.projections`**
  - 最强理由：与手机读的是同一个方法，形状天然一致。
  - 为何被否：那是**每行一包全部投影**（几十 KB），只为一格模型；而 `session.list`
    是连上 / 开面板就会调的方法。读同一行里已有的键是零额外往返。
- **删掉顶层 `model` 字段，只留 `projections.values.modelSelection`**
  - 最强理由：两者已是同一事实，删掉就只剩一个真值。
  - 为何被否：契约变更（老手机只认顶层 `model`），要单独决定，不在这一笔里顺手做。
