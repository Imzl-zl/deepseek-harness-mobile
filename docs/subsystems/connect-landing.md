# 连上之后落到哪个会话

手机连上电脑后落在哪个会话，以及"电脑那边正在跑"怎么显示。

## 1. 主机侧没有"当前会话"

桌面的"当前打开哪个会话"是**浏览器本地 UI 状态**（`ui-chat` 的 `ctx.uiWorkspace.openSession`），
宿主没有这个字段。所以手机**拿不到**"你桌面此刻在看哪一个"，也不该自己发明一个
（那会给宿主加一个它没有的概念）。

能拿到的只有 `session.list` 行的两列：`updatedAt` 与 `running`。

## 2. 落点规则（`AppModel.landingSessionOf`）

四档，按顺序：

1. **上次看的那个还在** → 回到它（`host.last_session` 偏好在 `openSession` 时落盘，
   键方案见 `ui-state.md` §2）；
2. 否则 **`running` 的里面 `updatedAt` 最新的**（"电脑那边还在跑"是最该先看见的状态）；
3. 再否则 `updatedAt` 最新的；
4. 列表为空、或只有子会话 → 保持空白屏（**不发明会话**）。

子会话不参与落点：它属于某个父会话的视图，从子智能体页另开一条路进入。

触发时机：进服务态（`ConnectionState.serving`）之后、`refreshSessions()` 回来的那一步
（`AppModel._landOnSession`）。已经有会话时不覆盖（用户点开的那个优先）。

**只有这一条入口**：`refreshSessions()` 自己**不选会话**。它曾经在末尾复用 blank
（`reuseOrCreateBlank`），于是 blank 先被选中、`_landOnSession` 随后早退 ——
落点永远是 blank，`host.last_session` 还被覆盖。现在 blank 复用只是第 4 档兜底
（`.agents/notes/implemented/2026-10-27-connect-landing-single-path.md`）。

## 3. "在跑"的显示

- 数据：`session.list.running`（快照）+ `api-session/status` 推送（实时）。
- 会话页：运行条 + 活时钟（`RunningBar`，见 `running-cues.md`）。
- 列表：行首状态点。
- 落点落在在跑的会话上时，看到的就是"在跑"——这是本条规则的产品目的。

## 4. 已知边界

- 手机不会跟随桌面**切换**会话（无法知道）；用户想看别的会话要在列表里点。
- 落点选中的会话如果本机没有历史条目，页面走空白 hero，看不到运行条（空会话无内容可画）。
- `host.last_session` 是手机自己的偏好（换电脑时整段清掉）；它指向的别名可能已失效，
  失效时按第 2/3 档处理。
