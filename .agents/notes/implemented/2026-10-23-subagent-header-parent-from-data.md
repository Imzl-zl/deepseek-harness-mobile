# Agent Note: 子会话头部的"父级"来自**会话数据**，不是导航记忆

Status: implemented（2026-10-23）。**契约方法面变了**：`session.list` 的子会话行多一个
`parentSessionId`（别名形式），根会话行不给这个键 —— 老手机忽略未知键，新手机连老连接器
时退到目录扫描 / 导航记忆。

## 起因

用户 2026-10-23 原话：

> 「你看 dsh 原生的主会话调用子智能体它上面会显示，但是你进入子智能体，子智能体会话上面
> 显示的就是自己的东西了，没有就不会显示；我们这个 APP 进入子智能体上面还是显示
> 子智能体啥的就是它自己，然后能无限循环了。」

真机复现（症状截图 `shots-2026-10-23/u2-child-header.png` / `u3-switcher.png` /
`u4-grandchild-header.png`，不进仓库）：

1. 父会话 `Nested Subagent Spawn Test` 头部正常（`1 个子智能体` 计数 chip）；
2. 进子会话 `Spawn grandchild, report result`：头部正常（`←` + 子级名）；
3. 从面板下钻到孙级：**头部显示的仍是祖父那一层** —— `_subagentLabel` 在**祖父的目录**里
   找不到孙级那一行 ⇒ 回落到 `currentTitle`（无标题时是字面量「子智能体」）；
   `←` 会**跳过真正的父级**直接回祖父。屏幕上的观感就是"每一层都还是它自己"。

## 原来为什么必然坏

父级只有一个来源：**导航记忆** `_subagentReturnFrom`（进目录行时记下当前会话）。

- 它**只有一层**：从切换面板再往深处走时不更新 ⇒ 父级永远停在第一次进入时那个会话；
- 名字查找用"记忆里的父级目录" ⇒ 深一层的会话必然查不到 ⇒ 落进字面量兜底。

## DSH 的形状（全部来自数据）

| 位置 | 规则 | 出处 |
|---|---|---|
| 根会话头部 | 只有 `SubagentCatalogAction`：`isChild` ⇒ `return null`，否则 `variant="count"` | `packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:760-767` |
| 子会话头部 | `parentId` 依次取 `address.parentSessionId` → 扫 `projectionsBySession` 的 catalog → `summary.parentId`；`undefined ⇒ return null` | 同上 `:789-801` |
| 头部内容 | `variant="switcher"`（root = **父级**，当前行高亮，标题只有当前子级名）+ 可选 `variant="count"`（root = 自己） | 同上 `:801-820`、`:490-495` |
| 空目录 / 失败 | `visible = presentedCatalog !== undefined && (variant === 'switcher' \|\| state === 'error' \|\| entries.length > 0)`；`if (!visible) return null` | 同上 `:617-631` |
| 点当前行 | `open()` 重新打开同一个会话 + 关面板（对桌面无害，对手机是纯噪音） | 同上 `:279-287` |

## 落地的形状（六步）

1. **连接器**：`session.list` 的逐字段构造里加了
   `parentSessionId: await deps.aliases.ensure(row.parentSessionId)`，**根会话不给这个键**
   （`connector/src/handlers.ts` 的 `session.list`）。必须过别名：线上只许出现 `sid`，
   与 `session.create` 那条同一个纪律。`SessionSummaryRow.parentSessionId` 早就在
   （`connector/src/dsh/sessions.ts:146-153`，子会话地址与 `subagent.prompt` 都在用它），
   缺的只是"发出去"这一步。
2. **App 模型**：`SessionSummary.parentSid` + `_parseSessionList` 解析（空串按没有处理）。
3. **头部三档**（`app/lib/ui/chat_page.dart` 的 `_subagentParentSid`）：
   ① 清单行 `parentSid` → ② `AppModel.subagentParentOfCatalogEntry`（扫**已读**目录）→
   ③ 导航记忆（**只在这一层确实是"走进去的那个会话"时**才算）。
   `_subagentLabel` 改成"在**真正的父级**目录里找当前那一行"，查不到回落**会话自己的标题**，
   **删掉「子智能体」字面量兜底**。
4. **切换面板 root = 当前会话的父级**；当前行点下去只关面板（`_switchSibling` 首行早退）。
   面板打开时若父级目录还没读到，先现拉一次（否则空面板会被读成"没有兄弟"）。
5. **`←` 走数据里的父级**，记忆降级为老连接器兜底；`PopScope.canPop` 与发送方法
   （`session.prompt` / `subagent.prompt`）也都改用同一个判据 —— 三个地方各判一次
   就会各漂一次。
6. 两个小差：顶栏标题**只显示当前子级名**（去掉 `父会话 › 子级名` 前缀与那套量宽逻辑，
   `dsh_app_bar.dart` 的 `_SubagentCrumb` 随之删除）；目录**读失败**时计数 chip 仍出现
   （前导图标换成重试，点开面板里有「无法加载子智能体 / 重试」）——
   照 DSH 的 `visible`，失败也是"值得渲染"的理由。

## 代价与风险

- **契约方法面变更**：`session.list` 行多一个键。老手机忽略它；**新手机连老连接器**
  时 `parentSid` 为空 ⇒ 第 3 档记忆不能删，否则退回 2026-10-21 那个"进子会话出不来"
  （返回按钮根本不出现）。
- **三处重建必须跟上**：`SessionSummary.copyWith` / `withCounters` / `withTitle` 都是
  逐字段构造函数（历史事故：漏字段 ⇒ "某些时刻它突然变 null"）。本轮 `parentSid`
  三处都补了，并有一条用例同时钉三条路径。
- **顶栏不再显示父级名**：DSH 的 switcher 标题只有 `switcherDisplayTitle`
  （`:490-495`），我们照它。后果是"父级叫什么"要看 `←` 的落点与切换面板的 root；
  要父级名回到顶栏是**另一个决定**（不预先发明）。
- **只读 / 可续聊仍看导航记忆**：`_subagentMode` 只有在走进目录那一刻才知道。
  若按数据父级把"恢复出来的子会话"判成子会话，mode 未知 ⇒ 输入栏会被换成只读框 ——
  凭空禁掉输入，是另一个方向的"说的和做的不一致"。所以这条判据留在记忆上，
  并写进 `docs/subsystems/subagent-page.md` §4 的取舍里。
- `aliases.ensure` 是异步，但 `session.list` 本来就在 `Promise.all` 里分配别名，
  加一行不改变复杂度；**根会话的 `undefined` 不建别名**（否则别名表会多一行空映射）。

## 判据（全部已过）

- 连接器 `connector/tests/handlers.test.ts`：「session.list：逐字段映射…」断言
  子会话行带 `parentSessionId === 'sid_dsh-1'`（**别名**，不是 `dsh-1`）、
  根会话行 `'parentSessionId' in row === false`。`pnpm exec tsc --noEmit` /
  `pnpm build` / `pnpm test`（586 项）全绿。
- App `app/test/session_list_wiring_test.dart`：`parentSid` 解析（根 / 子 / 空串 / 老连接器）
  + **三条重建路径都留住它**。变异校验：把 `copyWith` 里的 `parentSid` 去掉 ⇒ 恰好这条红
  （`Expected: 'sid_root' / Actual: <null>`）。
- App `app/test/subagent_enter_test.dart`（13 条）：三档各一条（数据 / 目录扫描 / 记忆）、
  父→子→孙逐层返回、孙级面板 root 不列祖父的子级、点当前行**不多发一次
  `session.subscribe`**、名字查不到时显示会话自己的标题且不出现「子智能体」、
  目录读失败时 chip 仍在且「重试」真的再读一次。
  变异校验：去掉 `_switchSibling` 的"当前行早退" ⇒ 恰好那条红（`Expected: <3> / Actual: <4>`）。
- 真机（同一隔离实例，连接器重建后重启；截图 `D:\tmp\dsh-e2e\shots-2026-10-23\`）：
  `v4-child-header.png`（子级名取自父级目录）、`v7-grandchild-header.png`
  （标题 `Reply with fixed text` = 它在 `Spawn grandchild…` 目录里的 label ——
  旧逻辑只会退成会话自己的标题）、`v8-back-to-child.png` / `v9-back-to-parent.png`
  （逐层返回）、`v5-switcher-child.png`（面板 root = 真正的父级）、
  `v11-current-row-tap.png`（点当前行后仍在该子会话）。
- 门禁：flutter **1117** / connector **586** / relay 86 / protocol 486·26·49 /
  boundary 357（98 个 Dart 文件）/ icons / tool-paths / analyze+format 0。

## 被否掉的替代

- **把 `parentId` 塞进 `subagentCatalog` 投影**：那个投影的 view 是宿主的形状
  （`packages/subagent/subagent/src/catalog.ts:77-94`，只有直接子级的 id/createdAt/mode/label），
  改它要动宿主；而 `session.list` 已经有了这个字段，没必要多一条会漂的真值。
- **让 `session.list` 直接发 DSH 的原始 `parentSessionId`**：会把宿主会话 id 漏过线，
  与别名表的边界（`connector/src/dsh/sessions.ts:89`）冲突。
- **App 侧自己维护一张"父级表"**（记每次进入的父级）：那正是这次的坏形状
  —— 第二份会漂的真值，重启即丢。
