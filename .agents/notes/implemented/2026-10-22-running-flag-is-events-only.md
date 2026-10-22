# Agent Note: 「在跑吗」只有一个真值 —— `session.list` 只补初值、不许撤销

Status: implemented

## Problem

真机（`d61cf622`）2026-10-22 晚：一轮 5 分钟的 `Start-Sleep` 在电脑侧 21:12:26 就
`turn/end` 了，App 到 21:17 还在显示「深度求索中」，输入栏一直停在「排队发送」；
**杀 App 重开才消失**（重开重读了 `session.list`，那一刻的值是 `false`）。
用户当场问：「web 都停止了吧？APP 还在转呢？」

`runningOf` 当时是这么写的（`app/lib/data/app_model.dart`）：

```dart
bool runningOf(String sid) =>
    _runningSids.contains(sid) || (sessionOf(sid)?.running ?? false);
```

`_runningSids` 由 `turn/start` 加、`turn/end` 删 —— 事件是实时的，这条没错。
问题在右边那一半：**`sessionOf(sid).running` 是 `session.list` 那张快照**，
而快照只在连上 / 收口 / 打开面板时重读。于是一旦快照是 `true`：

- `turn/end` 只把 sid 从 `_runningSids` 里移掉，快照那一位没人动；
- `||` 于是永远为真 ⇒ 运行条永远转、输入栏永远「排队发送」。

现场证据（同一台机、同一个会话）：电脑侧会话日志的尾部
`91 13:12:26 turn/end {"turn":4,"reason":{"kind":"completed"}}`（UTC，本地 21:12:26）；
App 21:17 的 `uiautomator` 里仍有 `深度求索中`，且**没有秒数** ——
说明 `_turnStartedAt` 是空的：这一轮的事件根本没进过 `_runningSids`，
屏幕上那一条完全来自快照。`am force-stop` + 重开（会话重新从 `session.list` 取
`running=false`）后立刻正常。

## Decision

`runningOf(sid) => _runningSids.contains(sid)` —— **一个真值**，另外两处配合：

1. `_applySessionList`：读到 `running === true` 的行就 `_runningSids.add(sid)`，
   **只补不撤**。补是为了"打开会话那一刻还没有任何事件"——那时这一笔是唯一的初值
   （2026-10-22 早些时候正是因为列表滞后 `false`，一整轮运行条都没出现）；
   不撤是因为列表同样可能**旧地**说 `false`（轮次已开始、还没重读），
   撤掉等于把正在跑的轮次关掉。撤销只由 `turn/end` 做。
2. `chat_page.dart` 的 `_running`（排队发送 / 发送模式禁用 / 工具明细自动展开）
   与子智能体行的 `running` 都改读 `AppModel.runningOf`，不再直读快照 ——
   否则那两处还是会被旧快照带偏（真机上「排队发送」就是它）。

## Alternatives considered

1. **`_runningSids.contains(sid) || (快照.running && !_endedSids.contains(sid))`**
   （再记一个"这一轮已经结束"的集合来压住快照）
   - 最强理由：快照仍旧参与判断，中途订阅（事件流没覆盖到这一轮）时不会漏掉运行条。
   - 为何被否：多一个集合就多一处要清（新轮次 `turn/start` 要清、重连要清、换会话要清），
     而且它的语义与 `_runningSids` 正好互补 —— 两个集合表达同一件事，迟早漂移。
2. **每次 `build` 顺手重读 `session.list`**
   - 最强理由：快照就不旧了。
   - 为何被否：把"界面滚动"变成"网络轮询"，`session.list` 是整表快照（几十行带投影），
     而运行态是**秒级**的事；而且它仍然会在一轮开始的瞬间滞后（真机上就是这么漏掉整轮的）。
3. **只在连上/收口时清空 `_runningSids`，其余照旧**
   - 最强理由：一行改动。
   - 为何被否：不解决本 bug —— 快照 `true` 的那一路还在，清事件集也不会让 `||` 变假。

## Consequences

- 收益：运行条与输入栏的"在跑吗"只跟事件流走，电脑侧 `turn/end` 一到就停（真机验证见下）；
  另外两处（`_running`、子智能体行）不再各读一份快照。
- 代价：
  - **没订阅过的会话不再有"在跑"的实时性**：`runningOf` 只认 `_runningSids`，
    而它只被"读到的列表行"与"该会话的事件"喂饱 —— 关掉的会话在列表重读前
    保持上次的值。已知边界，接受（抽屉里那枚点不是秒级指标）；
  - 断线期间发生的 `turn/end` 收不到 ⇒ 重连前运行条会一直转。这条**今天也存在**
    （`_runningSids` 本来就要靠 `turn/end` 才清），本次没动它；
  - `turnStartedAtOf` 在"只有快照、没有事件"时仍然是 `null` ⇒ 运行条只说
    「深度求索中」、不编秒数（与 `running-cues.md` §2 同一条纪律）。
- 判据：
  - 单测：`app/test/shimmer_test.dart` 的「session.list 说在跑，turn/end 之后必须停」——
    `session.list` 走**真解析器**（`{'sessions':[{'sid':'s1','running':true}]}`），
    先断言初值生效（`runningOf` 为 true），再推一条 `turn/end`，断言变 false。
    变异校验做过：把 `runningOf` 改回 `||` 形状，该条红在最后那个 `isFalse` 上（恰好一条）。
  - 真机（`d61cf622`，`adb install -r` 原地装）：`Start-Sleep -Seconds 150` 跑一轮，
    执行中 `shots-2026-10-22/g-213439.png`（工具行前是 loading 图标、末尾运行条
    「用时 1 分 54 秒」）；`turn/end` 之后 `i1-after-turn-end.png` 运行条消失、
    输入栏回到发送箭头 —— **全程 App 在前台，没有重启**。
