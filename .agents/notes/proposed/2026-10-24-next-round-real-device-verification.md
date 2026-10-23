# Agent Note: 下一轮提示词 —— 真机验证 W3 / W4（只验证，不改代码）

Status: proposed（**已执行 2026-10-24 02:14–02:59**：四项都跑了，结果回写进各自的 implemented
笔记；本文件留作配方与判据的出处）

> 用途：队列 11 件已全部落地（代码 + 门禁全绿，0 个真机回合）。这一轮**只做真机验证**，
> 把三件"代码对了但没在真机上看见"的事验掉，并把证据写回笔记。**默认不改代码**——
> 发现问题先记录、报价、拿准，不顺手改。

## 提示词（整段复制）

```text
项目：dsh-mobile（D:\sudy\myproject\dsh-mobile，Windows / pwsh）。中文回复。

本轮只有一件：**真机验证 W3 与 W4**（以及 W1 遗留的"计划审查卡"能不能看见）。
不改代码 —— 除非我当场点头。

## 0 先读（别跳）

- memory.md 的「真机联调的成本纪律」（隔离实例、`adb reverse`、`svc power stayon`、
  `flutter build apk --debug` + `adb install -r`；**`flutter install` 会先卸载 App，配对凭据一卸全没**）
- tools.md 的「真机验『桌面卡被手机撤掉』的配方」（headless Web GUI 就是真客户端；
  点手机按钮**必须用 `uiautomator dump` 的 bounds**；**别信 `adb reverse --list`**，从手机侧 `curl` 验）
- 三篇笔记（要验的判据都在里面）：
  `.agents/notes/implemented/2026-10-24-terminal-identity-from-pc.md`（W3）
  `.agents/notes/implemented/2026-10-24-running-from-native-status.md`（W4）
  `.agents/notes/implemented/2026-10-24-interaction-identity-from-native-ids.md`（W1 尾巴）
- 总账：`.agents/notes/proposed/2026-10-24-native-rules-audit.md`（11/11 已落地，真机未跑）

## 1 报价（先报再动）

三个验证项，约 **3–4 个轮次**（含起隔离实例、装包、一次模型真跑）：

1. **W3-a 中转重启恢复**（约 1 轮，不改代码就能做）：最便宜，先做。
2. **W3-b 电脑停用设备**（约 1–2 轮）：可能要在"中转路径"与"直连路径"上各试一次。
3. **W4 运行条按推送收口**（约 1 轮）：要一次真跑完的回合（花模型钱）。
4. **W1 尾巴 计划审查卡**（可选，约 1 轮）：只验"看不看得见"，**不改设计**。

**开跑前把这份报价发给我并拿到准**，再动 `dsh` / `adb`。

## 2 前置（一次做完，别反复）

```powershell
adb devices                        # 设备在
adb shell svc power stayon true    # 屏幕别灭（灭屏 = 引擎暂停）
$env:DSH_HOME='D:\tmp\dsh-e2e'     # 隔离实例的数据根，**不动我日常那个 DSH**
dsh --profile mobile-e2e --port 63900 --no-open
```

- 中转：`cd relay; node src/main.ts`（**先 `pnpm install`**；`ws` 是运行时依赖）。
- 手机走中转：`adb reverse tcp:8787 tcp:8787`，并从**手机侧**验一次：
  `adb shell 'curl -m 5 -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:8787/'` → **405 = 对**。
- 装包：`flutter build apk --debug` + `adb install -r`（**不卸载**）。
- 截图目录：`D:\tmp\dsh-e2e\shots-2026-10-24-verify\`（自己建；每条证据一个文件）。
- 先复跑一遍门禁证明基线：`node protocol/verify-fixtures.mjs`（454）、
  `node app/tools/verify-platform-boundary.mjs`（360）、`cd connector; pnpm test`（616）、
  `cd relay; pnpm test`（87）、`cd app; flutter test`（1144）。

## 3 三个验证项（每项：步骤 → 判据 → 证据）

### W3-a 中转重启 → 手机自动恢复、配对不掉（**这是 W3 的主判据**）

1. 手机连上隔离实例（会话列表能加载、能发一句回一句）。
2. **杀掉中转进程**（`Ctrl-C` 那个 `node src/main.ts`），手机应显示离线/重连中。
3. 重启中转，**不做任何操作**，等手机自己回来（约 10–30 s；电脑侧会重连并重放名册）。
4. 判据：① 手机**没有**回到配对页；② 凭据还在（重开 App 仍直接进会话页）；
   ③ 会话列表/投影重新加载出来；④ 管理面 `/api/dsh-mobile/status` 的 `devices[].online` 回 true。
5. 证据：重启前后的两张截图 + `adb logcat -d | Select-String 'not-paired|relay/offline|unauthorized'`
   的原文（**要能看到 401/offline，而不是 not-paired**）。

**反面对照（W3 之前的行为）**：如果手机回了配对页，说明"401 被读成终态"没改干净 ——
如实记，别改代码，先把 logcat 与时间点贴出来。

### W3-b 电脑停用这台设备 → 手机**明说**"不再认可本机"

**这一项要如实分辨两条路径**（本轮最可能暴露设计缺口的地方，别猜）：

1. 先在中转路径上做：管理面 `POST /api/dsh-mobile/devices/enabled`
   （body `{ devId, enabled: false }`；devId 从 `GET /api/dsh-mobile/status` 的 `devices[]` 拿）。
2. 观察手机：是**明说"这台电脑已不再认可本机"并回配对页**，还是**一直在离线/重试**？
   - W3 的代码把"换票 401"归成可恢复（`relay/offline`），而**中转那一侧根本到不了电脑** ——
     停用后名册里没有它，换票就 401。所以**预期**：中转路径上只能看到重试，
     看不到"明说"。**这正是要验的**。
3. 再在**直连路径**上试一次（`adb reverse --remove-all`，让 App 走局域网/Tailscale 直连；
   地址来自 `endpoint.describe` 学到的 direct 那条）：这时手机能到电脑的握手层，
   电脑的 `peerOf` 拒绝会以**关闭码 4003 + `protocol/not-paired`** 到达 ⇒ 应看到"明说"。
4. 判据：两条路径各自的实际表现（截图 + 文案原文）。**两条都要记录**，
   "中转路径看不到明说"本身就是一个要写进契约 §15 的事实。
5. 恢复：把设备 `enabled: true`，确认手机能重新连上（不必重新扫码）。

### W4 运行条按推送收口（断线期间跑完一轮）

1. 在一个会话里发一句会让模型跑十几秒的提示（**报一次模型成本**）。
2. 运行条出现后，**断掉传输**：`adb reverse --remove-all`（USB 隧道没了 = 手机连不上）。
3. 等这一轮在电脑侧跑完（看电脑侧日志/管理面，不要等手机）。
4. 恢复：`adb reverse tcp:8787 tcp:8787`，**不做任何点击**。
5. 判据：回网后**立刻**（≤1–2 s）① 运行条消失；② 输入栏主键从「停止」回到「发送」；
   ③ 这一轮的结束条目/统计出现。
6. 证据：断网前 / 回网后两张截图 + `adb logcat` 里 `status` 帧相关的行（若没有日志，
   就只报现象与时间点）。**"运行条还转着"= 失败**，如实记，别刷屏重试。

### W1 尾巴（可选）计划审查卡在手机上**看不看得见**

1. 在 `plan` 模式里让模型给一个计划并调用 `/exit_plan_mode`（一次模型成本）。
2. 判据：电脑上出现计划审查卡（已知事实）；**手机上是否出现任何卡片**（预期：没有，
   因为卡的来源是请求、手机侧只有会话事件）。若手机上**出现了**，说明我判断错了，
   把截图和会话事件片段贴出来。
3. **只验不改**：要让它变成"能答"，缺的是"卡来自请求"的投递（下一件独立的活，不在这轮）。

## 4 收尾（一个提交）

- 把三（四）项的结果写进对应笔记的「真机验证」一节：**判据、命令、输出原文、截图路径**；
  没验成的写"没验成 + 卡在哪一步"，**不许写"应该没问题"**。
- 若 W3-b 证实"中转路径看不到明说"：在 `docs/subsystems/remote-channel.md` §15 加一行
  （事实陈述，不加代码）。
- memory.md 的待办/已知缺口按结论更新（收口的划掉）。
- `git status` 只看有意改动，一个提交。

## 5 纪律（本轮最容易犯的三条）

1. **不许为了让验证通过而改代码**。发现问题 → 记录 + 报价 + 等我点头。
2. **判据要能区分"没命中"与"没实现"**（第八条教训）：先看 logcat / 管理面，
   再怀疑手势坐标；点按一律用 `uiautomator dump` 的 bounds，别目测。
3. **真机回合要算钱**：一次模型真跑就是一次请求；三个验证项别顺手多发 prompt。
```

## 写这份提示词时核实过的事实

- 队列 11/11 已落地：`4acb23c` W1、`1ba20a0` W2、`67d0397`/`55ea630`/`cdc9aa9`/`bbfa5f7`/
  `eee1569`/`748edcf`/`e1a421a` Z5/Z2/Z1/Z4/Z3/Z6a/Z6b、`7cc334f` W3、`334822a` W4（+ `2da3745` 修红门禁）。
- 门禁现值：protocol **454·26·49**、boundary **360**、connector **616**、relay **87**、
  flutter **1144**、analyze/format **0**。
- 隔离实例与截图配方来自 `memory.md` 的「真机联调的成本纪律」与 `tools.md` 的
  「真机验『桌面卡被手机撤掉』的配方」；`relay` 用 `node src/main.ts` 起（`tools.md:9`）。
- **W3-b 的"预期"是从代码推出来的，不是实测**：中转只回 401（`relay/src/device-registry.ts:88`），
  而"明说"来自电脑的握手层（`connector/src/protocol/handshake-driver.ts:164` →
  `connection.ts:660`）。所以中转路径上看不到明说是**合理预期**，但必须实测确认 ——
  若实测相反，说明我对名册推送时机的判断错了，以实测为准。
