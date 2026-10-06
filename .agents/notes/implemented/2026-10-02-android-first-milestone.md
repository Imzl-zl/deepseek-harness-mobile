# Agent Note: 先做安卓一端，版本闸门不再由鸿蒙决定

Status: implemented（2026-10-02 落地：`app/lib/{model,data,ui}/` + 安卓模拟器跑通）

## Problem

### 一、我把"三端同时上"当成了前提，而从来没人要求过

此前几轮我做了两件由这个自造前提推出的事：

1. **锁死 Flutter 3.41.9**，理由是 `app-platform-boundaries.md` §4 写的
   "三端共用一条 Flutter 版本线，上界由鸿蒙 fork 决定"；
2. 反复研究鸿蒙 fork 的成熟度（CPF-Flutter 到 3.44/3.47、release 档未验证、机型矩阵……）。

后果是**手段倒置**：为了让最后才做的那一端（鸿蒙）能对齐，把先做的两端
（iOS / 安卓）也拖在 4 个月前的版本线上。

用户指出："先做安卓啊，安卓最简单啊，又不是非要一下子三端都上啊，
哪有一下子三端同时的？你自己非要这么搞。"

**这是对的，而且指出了方法论上的错**：里程碑安排决定了技术约束，
而我让技术约束去决定了里程碑安排。

### 二、随之暴露的：`SessionDelta` 在 `core/` 就把语义丢了

接线 `data/projection.dart` 时才发现：`SessionDelta.items` 是 `ItemRecord`
（只有 `itemId` / `text` / `seq`），而"把事件投影成界面条目"需要事件的
`type` 与 `data`（"这是消息还是工具调用？内容在哪个字段？"）。

`core/` 解析了真实事件、推导了 `itemId`，然后**把 `type` 与 `data` 丢掉了**。
于是上层只剩两条路：从 `text` 里猜类型（`text` 还是空的），
或者每屏各自再解析一遍载荷 —— 后者正是"UI 各自解释事件"的开端。

## Decision

### 一、里程碑：安卓 → iOS → 鸿蒙；版本闸门按"当前在做的端"定

- **先做安卓**（Flutter 的一等公民：工具链最全、文档最全、Material 是它自家设计系统、
  模拟器现成）。目标：**在安卓模拟器上真跑起来**，而不是"研究清楚了"。
- iOS 排在安卓之后（同一份 Dart 代码，Flutter 侧支持成熟；障碍在签名与真机）。
- 鸿蒙最后，**且那时重新评估"Flutter+fork 还是 ArkTS 原生"**。
- **版本闸门改为"按当前在做的端定"**：只有安卓时，可以跟上游最新 stable；
  鸿蒙开工时再重估（那时才需要"三端共用一条线"这个约束）。

**为什么这不浪费工作**：`protocol/fixtures`（486 断言）与 `vectors`（49 项）
本来就是为"跨语言各实现一遍、跑同一批已知答案"设计的。
Dart 那份给 Flutter 用；将来若鸿蒙用 ArkTS 原生，判据已经现成。

### 二、`SessionDelta` 带上原始事件，而不是"条目"

改成带 `SessionEvent`（`itemId` + `type` + `seq` + `time` + `data`）：

- **`itemId` 的推导留在 `core/`**（契约 §5.2 的规则只有一处，不变量 I9）；
- **原始 `type`/`data` 原样带给上层**，由 `data/projection.dart` 解释语义。

分工就在这条线上：`core/` 知道"这一条是谁"，`data/` 知道"它长什么样"。

同时把流式与持久**在类型上分开**：`SessionDelta.events`（持久事件）与
`SessionDelta.liveText`（流式累加器内容）。混在一起会让 UI 需要
"从 itemId 猜这是不是流式内容"，而那个判据迟早写歪。

### 三、准入判据（可机械判定）

1. **能跑起来**：`flutter build apk --debug` 成功 + 装到模拟器 + 界面显示出来。
2. **测试全绿**：`flutter test`（当前 141 项）、`dart analyze --fatal-infos` 0 问题。
3. **一处投影**：事件 → 界面条目的翻译只在 `data/projection.dart` 一处。
4. **空 ≠ 错**：界面必须分开显示"真没有会话"与"请求失败了"。

## Alternatives considered

1. **继续按"三端同时"锁 3.41.9，先把三端的边界都研究清楚**
   - 最强的理由：将来做鸿蒙时不用返工，版本线天然对齐。
   - 为何被否：**没人要求三端同时**，而它让"先做出一个能跑的"无限期推迟。
     实测代价：几轮过去了，一个能运行的界面都没有。而且鸿蒙那两个 fork
     的成熟度不是"研究"能解决的（release 档与机型矩阵要真机才知道），
     研究到某个点边际收益就是零。
2. **立刻升到最新 Flutter stable**
   - 最强的理由：跟上上游，免得太久不升将来一次跳很多版本。
   - 为何暂不做：现在 3.41.9 已装好、141 项测试全绿、analyze 干净；
     升级要重跑全部门禁，而**升不升不影响安卓能不能做完**。
     记进"待重估"，等安卓 UI 真跑起来（那时才知道真实需求）再决定。
3. **`SessionDelta` 只带 `itemId`，让 `data/` 自己去订阅原始帧**
   - 最强的理由：`core/` 更纯粹（完全不碰载荷）。
   - 为何被否：那等于**开第二条读路径**，而两条读路径的时序一致性没有任何保证
     （§5.1 明写"同一个 `seq` 会经两条读路径各出现一次"——那已经是协议的一部分，
     不该在客户端再造一条）。原始载荷由 `core/` 顺手带上，代价是零。
4. **给 `SessionDelta` 加一个 `rawPayload` 字段而不是换掉 `items`**
   - 最强的理由：改动最小，`items` 的既有用法（fixtures 的收敛对比）不动。
   - 为何被否：`items` 与 `rawPayload` 会**同时存在**，而它们描述的是同一件事
     （一条事件）—— 两份表示迟早不一致。直接换掉，让类型只有一个意思。
     `DeviceSession` 内部的 `ItemRecord` 保留（它是**水位与收敛**用的，与投影无关）。

## Consequences

- 收益：**安卓端第一次真正能跑**（`model/` + `data/` + `ui/` 三层落地）。
- 收益：版本闸门不再为一个远期的端服务；升级与否变成"需要时再定"的普通决定。
- 收益：事件语义不再在 `core/` 丢失；"持久 vs 流式"在类型上分开。
- 代价：`core/sync_client.dart` 的 `SessionDelta` 换过字段，`sync_client_impl.dart`
  与测试同步改（已改完，141 项绿）。
- 代价：`main.dart` 的 `BootstrapConfig` **是占位值**（`relayUrl` 指向 `relay.invalid`、
  密钥为空）。所以**现在连不上电脑是预期的** —— 配对（契约 §12.1）落地前，
  它只能显示空列表与"未连接"。这一点在代码里写明了，没有假装能用。
- **仍未做**：真实配对流程、本地库（sqflite）、`ui/adaptive/`、三端能力包。
  版本重估待安卓 UI 稳定后进行。

## 落地时改动的文件

| 文件 | 做了什么 |
|---|---|
| `app/lib/model/chat_item.dart` | **新增**：领域模型（`ChatItem` sealed + 消息/工具/审批/其它） |
| `app/lib/data/projection.dart` | **新增**：事件 → 界面条目的**唯一**投影 |
| `app/lib/data/session_store.dart` | **新增**：条目表（upsert-only、按 `seq` 排序、通知合并到微任务） |
| `app/lib/data/app_model.dart` | **新增**：应用级状态（`ChangeNotifier`），UI 的唯一数据入口 |
| `app/lib/ui/session_list_page.dart` | **新增**：会话列表（空/错分开、连接状态 chip） |
| `app/lib/ui/chat_page.dart` | **新增**：对话页（气泡/工具行/审批行/输入栏） |
| `app/lib/main.dart` | **改**：装配点（唯一知道用哪个实现的地方） |
| `app/lib/core/sync_client.dart` | **改**：`SessionDelta` 带 `SessionEvent`；流式与持久分开 |
| `app/lib/core/sync_client_impl.dart` | **改**：`_eventFromPayload` 保留 `type`/`data` |
| `app/test/widget_test.dart` | **改**：替掉 `flutter create` 的 counter 模板测试 |

证据（实测，非推断）：`flutter test` **141 项全绿**；
`dart analyze --fatal-infos lib test` **0 问题**；`dart format --set-exit-if-changed` 0 文件。
