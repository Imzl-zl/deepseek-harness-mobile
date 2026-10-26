# Agent Note: 真机对照桌面后修掉的两处偏离（模型 pill / 分支失败）

Status: implemented

## Problem

2026-10-26 真机（`dsh-mobile-test` profile + USB 反代中转）验证「桌面四件事」时，
用户直接指出两处与桌面不一致：

1. 输入栏模型 chip 显示 `c518aa0a-…:deepseek-4.1-flash` 这样的**路由 id**；
2. 分支失败会弹 toast。

桌面的规矩：模型触发器**从不显示原始 id**（`ui-model-selection/src/client/ModelSelect.tsx:424-429`
的 `currentChoice?.model.name ?? t('trigger.fallback')`，「请选择模型」在 `locales.ts:17`）；
分支失败**静默**（`ui-chat/src/client/apply.ts:307-310` 的 `.catch(() => {})`，注释写明
"leaves the source view unchanged"）。

## Decision

两处都按桌面改：

1. `_modelLabel` 只认两档 —— 目录里有这一项给 `displayName`，否则「请选择模型」。
   **不再走 `ModelCatalog.displayNameOf`**：那一个在缺项时退回模型 id（picker 需要），
   直接用它就会漏出原始 id。手机独有的传输态（没连着 → 「未连接」、没选会话 → 「未选择」）
   保留，它们是桌面没有的状态。
2. 分支失败不弹任何东西，源视图不动；原因留在 `AppModel.lastError` 供排错。

## Alternatives considered

1. **保留原始 id 作为兜底**（原实现）
   - 最强的理由：目录拉不到时至少能看出"哪条路由/哪个模型"。
   - 被否：那是排错信息，不是给用户看的名字；桌面在同样数据下显示「请选择模型」，
     同一个数据源出现两套显示就是漂移。用户原话：「数据源不都是同一个，桌面是啥 APP 也就是啥」。
2. **把「请选择模型」也改成"未选择"**（把两档并成一句）
   - 最强的理由：手机已经有"未选择"这个词，少一个词表项。
   - 被否：桌面的 `trigger.fallback` 是「请选择模型」，而"未选择"保留给"还没选会话"这个
     手机独有的状态；两个状态两句话，才能从文案上分清"没开会话"与"会话里没选模型"。
3. **分支失败继续弹 toast**
   - 最强的理由：用户点了没反应像卡住。
   - 被否：桌面 `.catch` 就是空实现，且失败时**源视图不变**已经表达了"没成功"；
     加弹窗等于给同一个失败造第二个信号源。

## Consequences

- 收益：模型 chip 在目录缺项时与桌面同文案，不会再漏出 uuid 形态的路由 id。
- 收益：分支失败与桌面同语义（静默 + 源视图不变）。
- 代价：目录拉不到时，用户**看不出**当前是哪条路由 —— 需要排错就看连接页/日志，
  这正是桌面让"目录"承担的唯一可见性。
- 代价：测试里"输入栏显示子会话模型"这类用例不再能断言原始 id：改为
  **数据层断言 `currentModel.model`** + **显示层断言「请选择模型」**（假电脑没有目录）。

## 代码入口回指

- `app/lib/ui/chat_page.dart`（`_modelLabel` / `_fork`）
- `app/test/subagent_enter_test.dart`、`app/test/widget_test.dart`（两处断言改成数据 + fallback）
