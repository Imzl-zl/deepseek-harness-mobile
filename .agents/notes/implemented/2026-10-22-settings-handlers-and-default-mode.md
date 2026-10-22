# Agent Note: 挂上 settings.describe / settings.update，解锁三行电脑侧设置

Status: implemented

## Problem

开工单 §4/§5：连接器里 `SettingsPort`（`connector/src/dsh/settings.ts:51-70`）**写好了、有单测**，
但 `createSettingsPort` **从没被调用**，`settings.describe` / `settings.update` 两个 handler
在 `protocol/methods.ts:91-94` 列着、`handlers.ts` 里搜不到 = 差额 4 个方法里的 2 个。

后果是手机只能"这一次用哪个预设"（`session.create({agentPreset})`），**不能设成以后默认**；
"新会话默认权限"与"Session Log 开关"同样没有入口。

## Decision

1. **挂两个 handler**（`connector/src/handlers.ts`），接到已有的 `SettingsPort`：
   - `settings.describe`：读方法、不带幂等键；
   - `settings.update`：写方法、带幂等键，`expectedRevision` 乐观锁，过期回 `settings/conflict`。
   两者都按 `settings` 服务的能力位挂 —— 服务不在就**不挂**（`repo.info` 也就不报）。
2. **在端口之上再加一层 allowlist**（`connector/src/dsh/settings-face.ts`），因为
   "能读整棵设置树"与"能写任意 ns 的任意字段"都太大了：
   - 可读 ns 三个（`permission` / `agent-preset-registry` / `session-log-deepseek`），问别的**静默跳过**；
   - 可写字段**按 (ns, path) 逐条**（三条），越界回 `gateway/bad-request`。
     不按"ns 可写"放行：`mutate` 能写密钥字段（`packages/settings/settings/src/index.ts:81-83`），
     而 `settings.update` 不是密钥的通道（密钥走 `credentials.set`）。
3. **手机侧**：`AppModel.refreshSettings()` + `updateSetting(ns, path, value)`；
   设置页三行（新会话默认权限 / 新任务默认模式 / 上传 Session Log）。
   **拿不到目录 / 名册时行在但点不动** —— 不摆假入口。

## Alternatives considered

1. **直接透传 `settings.describe()` 的全部 ns**
   - 最强理由：一行代码，将来加设置行不用改连接器。
   - 为何被否：手机这一版只有三行会用到，其余都是把电脑的配置拓扑白送给手机界面；
     而且"端口脱敏"不等于"该给" —— 两份清单里任意一份写错都是一个泄漏面。
     用 allowlist 把"手机能看什么"写成一行可审查的事实。
2. **写面按 ns 放行（"`permission` 可写"）**
   - 最强理由：实现最省事，`setField` 本来就是按 path 写的。
   - 为何被否：同一个 ns 里既有 `defaultPreset` 也有密钥类字段，而 `mutate` 两种都能写。
     手机的密钥通道必须是 `credentials.set`（单向、只发新值），
     让 `settings.update` 也能写密钥等于**绕过那条通道**。
3. **`settings.update` 不带 `expectedRevision`**
   - 最强理由：省掉一次 describe，手机侧更简单。
   - 为何被否：契约 §5.7 明写"带 `expectedRevision` 乐观锁，过期回 `settings/conflict`"，
     而电脑上的设置可能同时被 Web / 桌面改；不带锁就是"最后一次写赢"，用户会看到自己没改过的值。
4. **冲突时自动重试这次写**
   - 最强理由：用户点一下就该成功，为什么要他再点一次？
   - 为何被否：冲突意味着值在两次读之间被**别人**改过，盲目重试会用旧意图覆盖别人的新值。
     现在的做法是**重读 + 返回 false**：界面刷新成真值，用户看到的是"现在是什么"，
     要改再点一次 —— 与 DSH Web 的 `refresh-settings` 动作同一条。

## Consequences

- 收益：三行设置有了真入口；方法面差额从 4 收到 2（`credentials.set/unset` 仍未实现）；
  `settings.update` 的写面是三条明码列出的字段，审计只需看一个数组。
- 代价：
  - 手机改的是**电脑侧真值**：同一台电脑的 Web / 桌面会立刻看到变化（这正是"遥控器"的语义，
    但也意味着手机不是"只影响自己"）。
  - 可写面写死三条：DSH 以后新增的设置项不会自动出现在手机上，要改那个数组 + 加一行 UI。
  - `settings/conflict` 之后**不重试**（见 Alternatives 4），用户会看到"改设置失败：settings/conflict"
    并发现值被刷新 —— 这是刻意的。
  - Session Log 开关只做连电脑模式（本机模式的语义完全不同，见 `settings-porting-notes.md` §1）。
- 单测：连接器 8 条（allowlist / 密钥位只有 path+set / 冲突码 / 越界码 / 能力位）、
  手机 5 条（落表 / 只发新值 / 冲突重读 / 三行渲染 / 目录缺失点不动）。
- 真机证据（`d61cf622`，`shots-2026-10-22/`）：设置页改成「PTC 模式」后，
  连接器账本里 `settings.update` 的结果是
  `{"ns":"agent-preset-registry","revision":1,"values":{"selectedDefault":"ptc"}}`；
  紧接着 `session.create` 回 **`{"sid":"…","agentPreset":"ptc"}`** ——
  手机没有传 `agentPreset`，新会话拿到的就是电脑侧的新默认。
