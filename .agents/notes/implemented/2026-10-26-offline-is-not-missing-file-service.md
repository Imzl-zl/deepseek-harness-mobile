# 离线不是"没有文件服务"：能力位要分"没读到"与"读到了没有"

- 日期：2026-10-26
- 状态：已落地
- 相关：`implemented/2026-10-26-remove-preview-and-demo.md`（同日真机清理）

## Problem

2026-10-26 真机：停掉电脑侧之后点「文件」页，页面说

> 这台电脑没有文件服务：连接器版本较旧，或没装 workspace-files。

而真实原因是**没连上**。`filesPage` 的判据只有 `app.filesAvailable`，它初值是
`false`，只在 `repo.info` 成功后才更新 —— 于是"还没读到"与"电脑说没有"在界面上
是同一句话。两者下一步动作完全不同：一个去重连，一个去换连接器版本。

## Decision

`AppModel` 增加 `repoInfoKnown`（**成功读到过** `repo.info` 才置 true）。
文件页在 `!filesAvailable` 时按它分两句：

- `repoInfoKnown == false` ⇒ 「还没连上电脑：连上后再看文件。」
- `repoInfoKnown == true` ⇒ 原来的"没有文件服务"。

**门槛**：离线（没拉过 `repo.info`）时文件页不出现"没有文件服务"；
老连接器（读到了、`caps.files` 缺失）仍出现。两条都用例钉住。

## Alternatives considered

1. **用连接状态判断（`connection == serving`）**。
   最强理由：不改模型，`AppModel.connection` 现成。
   被否：连接态是传输事实，不是能力来源；"刚连上、`repo.info` 还没回来"这一小段
   仍会把"还没读到"说成"没有"，而且测它要造连接流，脆。
2. **把 `filesAvailable` 改成三态（`unknown/false/true`）**。
   最强理由：类型上彻底，调用点不可能忘。
   被否：要改 getter 签名、所有 `if (filesAvailable)` 调用点与夹具；为一个文案引入
   一个新枚举不划算。一个 known 位足够表达"读没读到"。
3. **保持原样，只在文档里写清楚**。
   最强理由：离线是少见路径，用户重连后自然恢复。
   被否：这正是把用户下一步动作引错的一类文案（重连 vs 换版本），而且它已经骗到
   了一次真机。

## Consequences

- 收益：离线与"真没有这个面"分开说；文件页的下一步动作是对的。
- 代价：`AppModel` 多一个状态位；将来再加能力位时，要记得同时维护
  `repoInfoKnown`（目前只有 `repo.info` 一处写入，风险低）。

## 代码入口回指

- `app/lib/data/app_model.dart`（`repoInfoKnown`）
- `app/lib/ui/files_page.dart`（`!filesAvailable` 的两句话）
- `app/test/files_page_test.dart`（离线 / 老连接器两条）
