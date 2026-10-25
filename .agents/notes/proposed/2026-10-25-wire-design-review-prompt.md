# 下一轮提示词：线上格式层（wire）—— 设计与迁移方案的独立审查

> 用法：新会话整段复制粘贴，或直接说「读 `.agents/notes/proposed/2026-10-25-wire-design-review-prompt.md` 并按它执行」。
> **这一轮出方案，不写迁移代码**（允许写只读的扫描脚本 / 最小探针；不落业务改动，除非方案定稿且用户当场点头）。
> 预期成本：**0 个模型请求**（不跑真机、不发 prompt；要连真实例抓样本也只在桌面跑）。

---

## 0. 事实（已经发生，别再重查）

- 项目 `D:\sudy\myproject\dsh-mobile`（Windows / pwsh，中文回复）。
  `connector/`（TS，DSH 插件）+ `relay/` + `app/`（Flutter）+ `protocol/` + `docs/`。
- DSH 参考源码（只读）：`D:\sudy\github\deepseek-harness`，**0.2.1-rc.3**。
- 先读：`AGENTS.md`（铁律）、`memory.md`（现状 + 教训九条）、`tools.md`（配方，尤其「事件到了没」）、
  `.agents/notes/AGENTS.md`（笔记规则）、`docs/subsystems/remote-channel.md` §5.7 / §6.3。
- 门禁（改代码后必须全绿）：connector **657**、flutter **1241**、boundary **509**、
  `dart analyze --fatal-infos` 0、`dart format` 0（跑 `lib test integration_test`）、契约方法面 **49 / 实现 47**。
- **已经落地的两步（别推翻，除非拿出证据）**：
  1. `d934f69` 计划审查卡：`tool/call` 的 `arguments` 在线上是 **JSON 字符串**（真机库与会话日志两处证据）。
  2. `74498cd` + `38a41c2` 事件字段收成**一个读者**：
     `app/lib/wire/reading.dart`（三态 `WireReading` + `WireDiagnostics` 计数）、
     `app/lib/wire/events.dart`（事件 decoder，`export 'reading.dart'`）、
     门禁规则 `wire-field-single-reader`（`app/tools/verify-platform-boundary.mjs`）、
     回放用例 `app/test/event_wire_replay_test.dart` + `app/test/fixtures/real-session-events.json`。
- **还没落地的**：RPC 应答面（**28 个方法**）与 `session.projections` 的 15 个键，
  仍然是在 `app_model.dart` / `model/*.dart` 里就地 `result is Map ? result['x'] : null`。
- 已有一份方案草案：`.agents/notes/proposed/2026-10-25-wire-format-layer.md`
  （不变量 / 目录布局 / 七批顺序 / 四方案对比 / 取证办法）。
  **本轮的任务是审它、证伪它、或给出更好的**，不是照抄它。

## 1. 本轮要回答的三个问题

1. **这到底是"没做设计"还是"设计粒度不对"？**
   要求：用代码形态与事故序列作证（不是感慨）。事故至少三条：`repo.info.commands` 的两种数组、
   `session.projections` 的 `null` / `{values}` 两态、计划卡的 `arguments` 字符串 vs 对象。
2. **最优方案是什么？** 至少比较下面五条，并写清"谁是真值 / 失败语义 / 迁移成本 /
   漂移怎么被发现 / 评审能不能核 / 对 DSH 升级的韧性"六项：
   - a. 手写 decoder 层（`wire/reading` + `wire/events` + `wire/rpc/<族>`），即当前草案；
   - b. 从连接器 TS 类型**生成** Dart（codegen）；
   - c. 运行时 **schema 校验**（JSON Schema / 自研 spec / schemastery 的形状移植）；
   - d. 逐模型类 `fromJson`（现状改良，最少新概念）；
   - e. 把形状责任**推回连接器**（契约里定稳定 DTO，手机不解释宿主形状）。
3. **迁移路径**：若选 a，七批是否合理？每批"删掉旧读法"怎么机械化验收？
   若选 b/c/e，最小可行链路是什么、第一步落哪儿、怎么在不破 1241 条测试的前提下走。

## 2. 审查范围（必须逐处看，别抽样）

- `app/lib/data/projection.dart`（**64 处**裸 Map 读取：事件载荷 + 投影值两族）
- `app/lib/core/items.dart`（11 处）
- `app/lib/data/app_model.dart`（**30+ 处** `result is Map …`，覆盖 28 个方法里的绝大多数）
- `app/lib/model/*.dart`（plugins / usage_summary / model_catalog / command / tool_view /
  file_page / image_limits / subagent / workspace / permission / job）
- 形状的**生产者**：`connector/src/handlers.ts`、`connector/src/protocol/methods.ts`、
  `connector/src/dsh/*.ts`、契约 `docs/subsystems/remote-channel.md` §5.7
- 已有证据资产：`app/test/fixtures/real-session-events.json`（真机事件）、其余 `app/test/fixtures/*`
- **自己复核数字**（草案说 103 处 / 17 文件、`projection.dart` 64）：
  `fieldOf(` / `stringField(` / `nonEmptyString(` / `is Map` / `as Map` / `jsonDecode(`，
  并按"这个形状谁给的"归类。**照抄草案里的数字算不合格。**

## 3. 已知的坑（别重踩）

- `items` 是**一行一事件**：`tool/result` 覆盖同 id 的 `tool/call` ⇒ "库里只有 result"
  证明不了 call 没来过；反向，callId 那行在库里就证明结果到了。
- 抓手机库：`adb exec-out "cat /data/data/com.example.dsh_mobile/databases/dsh_mobile.db" > D:\tmp\phone.db`，
  查 `items(item_id, kind, seq, updated_at, payload_json)`。配方见 `tools.md`「事件到了没」。
- **用例喂手捏形状会把错误实现养绿**（计划卡就是这么漏的）：任何 decoder 的用例必须来自真样本，
  且 fixture 要有"键集合不缩水"的断言。
- `repo.info` 只在握手后取一次（`app/lib/data/app_model.dart:2540`），那时没有活 agent ⇒
  命令说明恒空（`memory.md` 未知缺口 18）。
- 连接器插件日志到不了 CLI stdout（`ctx.logger`），`console.error` 能到（`tools.md`）。
- 通道层两个坑：帧头 `id` 与幂等键是两个标识符；单帧上限 8 MiB、二进制在线上放大 ≈1.78 倍。

## 4. 交付物

1. 新笔记 `.agents/notes/proposed/<日期>-wire-design-review.md`：
   结论 + 五方案 × 六判据的对比表 + 推荐 + 迁移步骤（每步一条可机械验证的验收）+ 被否方案与代价。
2. 对 `proposed/2026-10-25-wire-format-layer.md` 的处理：保留（同意）或标注"被 `<新篇>` 取代"并移入
   `archived/`。**不许删旧结论**（`.agents/notes/AGENTS.md`）。
3. 若结论是继续 a：给出**第一批（`session.list` / `session.page`）**的具体形状 ——
   decoder 签名、产出哪个已有模型类（不新造 DTO）、fixture 从哪抓、要删掉哪些旧读法（精确到行）。
4. 若结论是 b/c/e：给出最小可行链路 + 一个端到端样例（一个方法即可）+ 失败怎么可见。
5. **不写迁移代码**（除非用户当场同意再做）。

## 5. 硬规则

- 引用 DSH / 连接器行为给 `packages/...:行号` 或 `connector/src/...:行号`；查不到写「未找到」，**禁止猜**。
- **不许把"枚举/猜类型"当方案**：每个字段的形状必须有出处，出处写进笔记。
- 改源码只用编辑工具（`edit` / `write`）；提交前看完整 `git status`。
- 成本纪律：本轮 **0 个模型请求**；要跑桌面 App 抓样本先报一句"约几分钟、不花请求"。
- 门禁数字唯一出处 `tools.md`；改断言必须补一次变异校验（故意破坏，确认**恰好**那几条红）。

## 6. 明确不做

- 不在这一轮迁完 28 个方法（只出方案 + 第一批的形状）。
- 不引入新依赖（除非对比里证明必要，并给出体积、维护、升级代价）。
- 不动 `mock/proto/`（与原型无关）。
- 不重新论证"要不要有 wire 层"——事件面已经落地；问题只剩"这一层的**形状与迁移方式**是否最优"。

## 7. 起手命令

```powershell
cd D:\sudy\myproject\dsh-mobile
git log --oneline -6; git status --short
Get-Content .agents\notes\proposed\2026-10-25-wire-format-layer.md
Get-Content app\lib\wire\reading.dart -TotalCount 60
Get-Content app\lib\wire\events.dart -TotalCount 40
# 自己数一遍（别照抄草案）
node -e "const fs=require('fs');const p='app/lib';const walk=d=>fs.readdirSync(d,{withFileTypes:true}).flatMap(e=>e.isDirectory()?walk(d+'/'+e.name):e.name.endsWith('.dart')?[d+'/'+e.name]:[]);let n=0;for(const f of walk(p)){const t=fs.readFileSync(f,'utf8');const c=(t.match(/fieldOf\(|stringField\(|nonEmptyString\(|\bis Map\b|\bas Map\b|jsonDecode\(/g)||[]).length;if(c){n+=c;console.log(String(c).padStart(4),f)}}console.log('total',n)"
# 形状的生产者
Select-String -Path connector\src\handlers.ts -Pattern "^\s*async\s+[a-zA-Z]+|reply\(" | Select-Object -First 40
```
