# Agent Note: 子会话头部的"父级"要从**会话数据**来，不是导航记忆

Status: proposed（**只分析，未改代码**）

## Problem

用户 2026-10-23：

> 「你看 dsh 原生的主会话调用子智能体它上面会显示，但是你进入子智能体，子智能体会话上面
> 显示的就是自己的东西了，没有就不会显示；我们这个 APP 进入子智能体上面还是显示
> 子智能体啥的就是它自己，然后能无限循环了。」

真机（`d61cf622`，2026-10-23）复现路径与观察：

1. 父会话 `Nested Subagent Spawn Test`：顶栏有 `1 个子智能体` 计数 chip（✅ 与 DSH 一致）；
2. 从右抽屉「子智能体」面板点进子会话 `Spawn grandchild, report result`：顶栏变成
   `← 返回父会话` + 子会话自己的名字 + 它自己的 `1 个子智能体`（✅ 这部分也对）；
3. **点标题开「切换子智能体」**：面板里列着**当前这个子会话自己**那一行，
   展开它还能看到它的下级（孙级 `Reply with exactly the text:`）；
4. 点孙级 → 确实进了孙会话，但**顶栏的"父级"仍是最初那个父会话**：
   `_subagentLabel` 在**父会话的目录**里找不到孙级那一行 ⇒ 回落到
   `currentTitle`（标题为空时就是字面量「**子智能体**」）；
   `← 返回父会话` 会**跳过真正的父级**，直接回到祖父。

截图：`D:\tmp\dsh-e2e\shots-2026-10-23\u2-child-header.png`（子会话头部）、
`u3-switcher.png`（面板里列着它自己）、`u4-grandchild-header.png`（孙会话头部）。

## 事实对照

### DSH 原生（三档父级，全部来自**数据**）

| 位置 | 规则 | 出处 |
|---|---|---|
| 根会话头部 | 只有 `SubagentCatalogAction`：`if (isChild) return null`，否则 `variant="count"`（root = 自己） | `packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:745-767` |
| 子会话头部 | `parentId` 依次取 `address?.parentSessionId` → 扫 `projectionsBySession` 的 catalog → `summary.parentId`；`parentId === undefined → return null`（根会话没有面包屑） | 同上 `:784-801` |
| 子会话头部内容 | `variant="switcher"`（root = **父级**，当前行高亮，标题只显示**当前子级名**）+ 可选 `variant="count"`（root = **自己**，只在 `openTitle === undefined` 时） | 同上 `:801-820` |
| 空目录 | `visible = presentedCatalog !== undefined && (variant === 'switcher' \|\| state === 'error' \|\| entries.length > 0)`，`if (!visible) return null` —— **没有子智能体就整枚不渲染**（连"0 个"都不显示；加载失败时反而给可重试入口） | 同上 `:618-631` |

### 我们（父级来自**导航记忆**）

| 位置 | 规则 | 出处 |
|---|---|---|
| 顶栏计数 chip | `subagentCount: subs.length`，`0` 不显示（等价于 DSH 的空目录规则；差别：加载失败时我们没有可重试入口） | `app/lib/ui/chat_page.dart:651`、`app/lib/ui/dsh_app_bar.dart:335` |
| 子会话头部 | `title = _subagentLabel`、`parentTitle = _subagentParentLabel`、`← 返回父会话`；父级 = `_subagentReturnFrom`（**进入时记下的那个会话**） | `chat_page.dart:628-640`、`:1141-1152` |
| 子级名字 | 在**记忆里的父级目录**中找当前子级的行，找不到回落 `currentTitle ?? '子智能体'` | `chat_page.dart:1174-1183` |
| 切换面板 | `SubagentTree(rootSid: parent)`，`onOpen → _switchSibling(node)`：**只改 `_subagentChildSid`，不改 `_subagentReturnFrom`** | `chat_page.dart:1200-1230` |

### 差在哪（一句话）

**DSH 的"父级"是会话数据（`address.parentSessionId` / 目录扫描 / `summary.parentId`）；
我们的"父级"是导航记忆（只有一层，且从面板往深处切换时不更新）。**
于是：往下钻一层，"父级"不跟着变 ⇒ 面包屑里的父级永远是第一次进入时的那个会话，
名字查找必然落空 ⇒ 屏幕上出现「子智能体」这种字面量，且层级越走越深、头部却不变 ——
用户说的"就是它自己 / 能无限循环"就是这个观感。

## 数据其实已经在链路上（只差一步）

- 连接器**已经**有这个字段：`connector/src/dsh/sessions.ts:147-154` 的
  `parentSessionId?: string`（注释写明它是子会话的准入凭据，`subagent.prompt` 的地址解析
  也已经在用它，`handlers.ts:614-640`）。
- 但 `session.list` **没有把它发出去**：`handlers.ts:553-585` 是逐字段构造
  （`sid / updatedAt / running / blank / subagent / model / cwd / projections`），
  没有 `parentSessionId`。手机侧 `SessionSummary` 因此也没有这个字段
  （`app/lib/model/chat_item.dart` 的 `SessionSummary`），只能靠导航记忆。

## 建议的改法（按顺序，未实施）

1. **连接器**：`session.list` 的逐字段构造里加一行
   `parentSessionId: await deps.aliases.ensure(row.parentSessionId)`（**必须过别名**：
   线上只许出现 `sid`，DSH 的原始会话 id 不能漏，与 `handlers.ts:536-541` 同一条纪律）。
   缺父级（根会话）就不给这个键 —— 不给 = 根，不给假值。
2. **App 模型**：`SessionSummary` 加 `parentSid`；`_parseSessionList` 解析它。
3. **头部改数据驱动**（照 DSH 的三档）：`parentSid ?? 目录里扫到的父级 ?? 记忆`；
   `_subagentLabel` 改成"在**真正的父级**目录里找当前行"，找不到才回落 `currentTitle`
   （**去掉「子智能体」这个字面量兜底** —— 它会把"查不到"伪装成"名字叫子智能体"）。
4. **切换面板 root 改成当前会话的父级**（数据里的那个），并让**当前行不可点**
   （或只关面板）：现在 root 用记忆 + 当前行可点，正是"点自己"的来源。
5. **`← 返回父会话`** 走数据里的父级；`_subagentReturnFrom` 降级为"老连接器没有
   `parentSid` 时的兜底"（保留但不作为真值）。
6. 顺带两个小差：DSH 的 switcher 标题**只显示当前子级名**（父级在树里），我们是
   `父 › 子` 前缀（放得下才显示）；DSH 在目录**加载失败**时给可重试入口，我们直接不显示。

## 代价与风险

- 连接器加字段 = **契约方法面变更**（`session.list` 的行多一个键）：老手机不认识它（无害，
  未知键被忽略），新手机连老连接器时 `parentSid` 为空 ⇒ 必须保留记忆兜底，否则
  "进子会话看不到返回"（这正是 2026-10-21 修过的那个坑）。
- 面板 root 改成"当前会话的父级"后，**兄弟之间切换**仍是同一个 root（父级相同），
  行为不变；但"从面板往下钻"这条路径会变成"进入子会话后父级跟着变"——
  这才是 DSH 的形状，需要一次真机回归（父 → 子 → 孙 → 返回两次）。
- `aliases.ensure` 是异步：`session.list` 已经是 `Promise.all` 里分配别名，加一行
  不会改变复杂度；但要**避免**为根会话的 `undefined` 也建别名（会污染别名表）。

## 判据（实施时）

- 连接器：`session.list` 的子会话行带 `parentSessionId`（别名形式），根会话行**没有**这个键；
  单测断言"父级是别名而不是 DSH 原始 id"。
- App：`SessionSummary.parentSid` 解析；头部三档（数据 / 目录扫描 / 记忆兜底）各一条；
  名字查不到时**显示会话自己的标题**，不再出现「子智能体」字面量。
- 真机：父 → 子 → 孙，每层头部显示各自的父级；`←` 逐层返回；从面板点当前行不再"进自己"。
