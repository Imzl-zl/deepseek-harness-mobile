# Agent Note: 投影包**属于某个会话**，换会话就不许再当成当前的

Status: implemented（2026-10-23）。

## 起因

用户看完子智能体修复后追问：

> 「子智能体显示的都是自己的啊，没问题了是吧？不会又有细节不到位吧？」

这句话把问题指向"**有没有显示别人的数据**"，而不是"某一格空着"。顺着这条查，
发现一处真会串台的地方（与上一轮的子智能体修复无关，但症状同类）。

## 发现

`AppModel` 只有一个 `_projections` 包（`session.projections` 的 `values`），
统计条 / token / 上下文 / 权限档 / 队列 / 标题都从它取。而它**没有"属于谁"的标记**：

- `openSession(sid)` 第一件事就是 `_currentSid = sid` + `notifyListeners()`；
- 新那包要等 `session.projections` 的应答回来才落地（一次往返）；
- **中间那一刻**（以及新会话那一读**失败**时），所有 getter 拿到的还是**上一个会话**的数字。

真机上的形态就是"从父会话切进子会话，统计条先闪一下父会话的 142K，再跳到 93.5K"；
读失败时干脆一直显示别人的。这条与"`session.list` 的模型从活 agent 读"是同一类错：
**数据没有所有权，界面就会说别人的事**。

## 改法

一个不变量，写在读出口上：

```dart
String? _projectionsSid;                    // 这一包是哪个会话的
Map<String, Object?>? get projections =>    // 不匹配就当作没有
    _projectionsSid == _currentSid ? _projections : null;
```

- `_applyProjectionValues(sid, values)` 落包时同时记 `_projectionsSid = sid`
  （它本来就有 `sid == _currentSid` 的守卫，所以这一包永远属于当前会话）；
- **内部 10 处读取全部改走 getter**（`tokenUsage` / `sessionStats` / `turnOutline` /
  `contextBreakdown` / `contextPressure` / `permissionValue` / `queueOf` / `inbox` 两处 /
  `agentPresetValue`）—— 只改 getter 而不改私有直读等于没改。

## 代价与保留的行为

- **换会话后、新包落地前，统计条显示空态**（约一次往返）。这是有意的：
  显示"上一个会话的数字"比空一拍更坏 —— 后者用户知道"还在读"，前者是**谎**。
- **同一个会话重读失败仍保留旧值**（"刷新不闪空"，`_readProjections` 的原注释）：
  sid 没变，包还是它的，旧值仍是这个会话自己的。
- 这条只保证"不显示别人的"；"自己的数字慢半拍"仍在（列表与投影都是快照，
  与标题、token、模型同一条边界）。

## 判据

- `app/test/session_projections_test.dart` 新用例：A 有全套投影 → `openSession('sid_B')`
  且 B 的读失败（形状不对）⇒ `projections` / `tokenUsage` / `sessionStats` /
  `permissionValue` 全 `null`。**先红后绿**（红的时候是 A 的那包）。
- 全量：flutter **1120** / analyze+format 0 / boundary 357。
- 真机（同一实例，只换包）：父 `2 轮 10 步 · 52 tok/s` + `142K tok · 41%`、
  子 `2 轮 6 步 · 63 tok/s` + `93.5K tok · 52%`、孙 `1 轮 2 步 · 70 tok/s` + `26.4K tok · 49%`
  —— 三层各自的数字，切过去不再先闪别人的（`y3/y4/y5-*.png`）。
- 另外把"模型"这条也复验了：三层都显示 `auto`（这是这台实例**唯一**的模型 ——
  15 个会话全是 `lightvela-free/auto`），所以"显示的是自己的"在真机上靠
  **每行独立解析**（单测里子会话行给 `m-child-0`、父会话行没有 ⇒ 同屏两个不同答案）
  来钉，而不是靠两个不同模型名。

## 没有做的事

- **没有**把 `_projections` 改成按 sid 存的一个 map：那会变成"记住所有会话的最后一包"，
  内存与失效都更复杂；这里要的只是"**这一包能不能用**"，一个 sid 就够。
