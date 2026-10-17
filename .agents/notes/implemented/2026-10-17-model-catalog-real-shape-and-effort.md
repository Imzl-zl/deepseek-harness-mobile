# Agent Note: 模型目录按 DSH 真形状解析（`{default, routableProviders, groups, failures}`），推理等级进二级 sheet

Status: implemented

## Problem

真机反馈（2026-10-17）："输入框中的模型…都没有对接吧"。

读码发现**模型目录在生产里一次都没解析成功过**：`AppModel._refreshModelCatalog`
认的是一个臆想形状 `List<{provider, models:[{id}]}>`，而连接器原样过线的是
DSH `buildModelCatalog` 的返回值（`packages/api/session-controller/src/catalog.ts:20-72`）：
顶层是**对象** `{default, routableProviders, groups:[{id,name,models}], failures}`。
于是 `catalog is! List` 直接静默返回，`modelCatalog` 恒为 null，
picker 永远说"拿不到模型目录"。

而单测全绿：`model_switch_test.dart` 的替身给的正是那个臆想形状。
**替身复现的不是真形状，它证明的就是别的东西**——与 2026-10-15 投影信封
那个 bug 同一类。连接器自己的夹具（`connector/tests/models-face.test.ts` 的
`CATALOG`）从头到尾都是真形状，两边各测各的，中间那一跳没人测。

另外目录里的 `reasoning`（efforts + defaultEffort）整块被丢掉，
于是 Web 有的"推理等级"选择在手机上不存在。

## Decision

1. **新增 `model/model_catalog.dart`**：按 DSH 真形状解析
   （`ModelCatalog` / `ModelProviderGroup` / `ModelCatalogEntry` / `ModelReasoning` /
   `ModelCatalogFailure`），逐字段转型、不整体 cast；`groups` 为空或形状不对
   → null（picker 说"拿不到"，不摆空列表——空列表会被读成"没有可用模型"）。
2. **`failures` 必须显示**（设置页模型组）：静默丢掉 = "key 没配"在手机上
   毫无痕迹，而用户看到的是"我的 provider 不见了"。
3. **模型 sheet 两级流动**（照 Web `ModelSelect` 的 root → model → effort drill）：
   点模型行 → 有推理档的进等级 sheet（默认档预选，与 Web `choices` 的构造一致：
   带 `reasoning.defaultEffort`），没有推理档的直接切。
   "默认"一项只在 `defaultEffort` 缺省时出现（`ModelSelect.tsx:129-140`）。
4. **切模型带 effort**（`session/select-model` 的 `reasoningEffort`），与 Web
   同一个 DSH 方法（`ui-model-selection/src/client/directory.ts:98`）。
5. **chip 与设置页显示模型展示名**（目录里的 `name`，退到 id），effort id
   翻成展示名（Web 的 `effortLabel` 同一条链）。

## Alternatives considered（否掉的）

- **在旧解析器上补丁**（认 List 也认 Object）：两种形状并存 = 第二份真值，
  且臆想形状永远没有生产者，补丁是死代码。
- **模型行内直接列 effort 标签**（不做二级 sheet）：§7.9 的行结构禁第三列，
  标签组在名称下方；effort 是**可选项**不是展示标签，混进行结构会歪。
- **选模型不带 defaultEffort**（让宿主自己定）：与 Web 行为分叉——
  Web 的 `choices` 明确带 `defaultEffort`，不带则换模型后 effort 可能漂。

## Consequences

- 收益：picker 第一次能列出电脑侧真实目录；effort 可切；拉取失败的 provider
  在设置页可见。
- 代价：`session/modelCatalog` 的应答从"摊平列表"变成整棵目录树，AppModel
  多一个 `ModelCatalog` 类型；老替身测试全部重写（这正是要点——旧替身
  一直在证明错误的东西）。
- 回归用例的形状逐字复刻连接器夹具（那就是 DSH 真形状）。
