# 下一轮提示词：剩余缺口调研 —— DSH 原生能力 + 最轻量实现

> 用法：新会话整段复制粘贴。**这是一轮调研，不写代码**（除非明确写了"允许改"）。
> 预期成本：**0 真机回合、0 次模型请求**，只读源码 + 读本仓文档。

---

## 0. 你要接手的现状

项目 `D:\sudy\myproject\dsh-mobile`（Windows / pwsh，回复用中文）。
它把 DSH（`D:\sudy\github\deepseek-harness`）的 Web 能力搬到手机上：`connector/`（电脑侧插件，TypeScript）
+ `relay/`（中转）+ `app/`（Flutter）+ `protocol/`（契约 fixture）+ `docs/`（现状真值）。

**先按顺序读这四份，别跳**：

1. `AGENTS.md`（项目铁律：宿主语义优先、不猜、改源码只用编辑工具、非平凡改动要决策笔记）
2. `memory.md` —— 「已知缺口」与「范围决定（别再当缺口）」两节是**本轮的全部输入**
3. `docs/mobile-surface-roadmap.md` —— 每个面的完成判据（同一份真值 / 空态 / 失败留声 / 三条测试）
4. `docs/subsystems/remote-channel.md` §5.7（方法表）与 §15（已知限制）

然后读 `.agents/notes/` 里最近这批 `implemented/*`（2026-10-24 的六篇）——**已定案的取舍不要重开**。

## 1. 铁律（违反即返工）

- **宿主语义优先**：DSH 原生怎么处理就怎么处理。新增任何超时 / 档位 / 重试 / 去重 / "谁接管"之前，先过三问：
  ① 这条规则删掉，DSH 是否已经给出答案？② 它是在补"我们这条通道没有的东西"，还是替宿主做决定？③ `docs/` 里是不是只有一处表达？
- **不猜**：引用 DSH 行为必须给 `packages/...:行号`；查不到就写「未找到」，不许用"通常如此"。
- **不改代码**：本轮只产出方案与判据。**不要动 `app/lib`、`connector/src`、`relay/src`、`mock/proto/`**。
- 允许跑只读命令：`grep`、`node app/tools/flutter-api.mjs <符号>`、`pnpm exec tsc --noEmit`（不要跑全量测试）。
- **0 真机回合、0 模型请求**。需要真机才能答的问题，写成"待真机验证 + 怎么验"。

## 2. 本轮的六个课题（按建议顺序）

每个课题都要产出：**DSH 原生事实（带行号）→ 我们要补什么（最小集）→ 代价（往返 / 状态 / 行数）→ 判据（怎么证明它对）**。

### 课题 1：`@会话` 提及（最轻，先做）

- 要回答：DSH Web 的 `@` 会话提及**线上形状**是什么（文本 token `@[label](uri)`？还是结构化字段？），
  手机端只用"把那段文本插进输入框"是否就够，还是必须让连接器认识它。
- 看哪里：DSH `packages/client/ui-composer/**`（或 composer 的 mention 源）、`packages/core/session/src/types.ts`
  的用户消息内容形状；本仓 `app/lib/ui/dsh_composer.dart`（`/` 菜单已落地，`@` 是同一套 suggestion 缝）。
- 已知：`/` 命令白名单已经随 `repo.info.commands` 过线（`implemented/2026-10-24-slash-suggestion-menu-single-source.md`），
  照同一形状加 `@` 是不是**只需要数据源 + 面板**？

### 课题 2：`@文件` 提及（要一个新窄口）

- 要回答：DSH 是否已暴露"列目录 / 搜文件"的 RPC（`workspace.*` / `files.*` / `glob` / `ripgrep` 之类）？
  如果有，连接器**直接透传**是多少工作量？如果没有，最小只读方法长什么样（入参、返回、上限、分页、路径根在哪）？
- 看哪里：DSH `packages/host/**` 的文件服务、`packages/client/**` 的搜索/提及实现；本仓 `connector/src/handlers.ts` 的方法面。
- 硬要求：**只读**、**有上限**、**失败原样报错**（不许空数组冒充"没有文件"）、路径不越出会话的工作区。
- 顺带回答：一个 1 万文件的目录，第一次 `@` 弹面板的**首屏延迟**由什么决定（枚举？索引？），能不能只搜不列。

### 课题 3：用量页的时间范围（先证明"不用改契约"）

- 已知事实：`usage.summary.byDay` 已经带**全部**保留日期的 `{date, turns, tokens}`（2026-10-24 落地，
  见契约 §5.7 规则⑤），所以"7 / 30 / 90 天切换"很可能**纯前端切片**就够。
- 要回答：① 纯前端切片是否成立（`byDay` 的覆盖范围是什么、缺失日期怎么画）？② 若确实需要服务端过滤，
  加可选 `from`/`to` 的代价（改契约 + 测试 + 老连接器兼容）值不值？
- 产出：**明确结论"改不改契约"**，并说明依据。

### 课题 4：插件页（能在手机上安全做的三件事）

- 要回答：插件清单 / 启停 / 安装日志这三件事，DSH 侧的方法是否都已经存在并已过线？
  `volatile` 字段的通用表单在手机上做到什么程度就该停（哪些字段类型必须"去电脑上改"）？
- 看哪里：`docs/plugin-and-jobs-notes.md`（已有边界结论）、DSH `packages/plugin-manager/**`、本仓 `connector/src/handlers.ts`。
- **不要重开"逐插件页面适配"**（架构上不存在通用渲染，已定案）。

### 课题 5：设置 42 项的对账

- 要回答：`docs/settings-porting-notes.md` 里标"只读 / 不做 / 必须分叉"的项，**现在还有没有该改判的**？
  尤其是那些"只读"里，DSH 其实已有写通道的（逐条给行号）。
- 产出：一张"还差几项、各是什么类型（缺 RPC / 缺界面 / 故意不做）"的表；**不要动那 42 项的分类**，只标出需要改判的。

### 课题 6：原生规则审计的尾巴

- 要读：`.agents/notes/proposed/2026-10-24-native-rules-audit.md` 的 `未实现 2` 与 `验证缺口 3`。
- 要回答：这 5 条各自**现在还成立吗**（有的可能已随本轮改动消失）、修它要动哪里、值不值得修。

## 3. 每个方案的"轻量 / 低延迟 / 优雅"判据（照这个排序选方案）

1. **能不加方法就不加方法**：先用已有数据（手机手里的、`session.list` 的、`repo.info` 的）算出来。
2. **要加就加"只读窄口"**：入参一个、返回小、有硬上限、失败原样。**不做**"顺便一起返回"的胖方法。
3. **一次往返**：面板首屏不许两次往返（先拉列表再拉详情）。
4. **不做本地索引 / 缓存**：手机侧不留第二份文件树（第二真值源）。
5. **失败留声**：走 `AppModel.lastError`，不许静默空数组。
6. **不新增后台任务 / 定时器 / 预热**：延迟靠"少要数据"，不靠预取。
7. 界面侧：**能复用 `dsh_composer` 的 suggestion 缝就复用**（`/` 已经趟过一遍）。

## 4. 产出物

写到 `.agents/notes/proposed/2026-10-25-remaining-gaps-research.md`（或当天日期），结构：

```
# 剩余缺口：调研与最轻实现
## 0. 一句话结论（哪些能做、哪些不能、哪些不做）
## 1. 课题 1 …（DSH 事实 / 我们要补什么 / 代价 / 判据 / 方案对比 + 被否方案）
## 2. 课题 2 …
…
## 7. 建议的执行顺序（按"价值 ÷ 代价"，并给出每件的预估提交数）
## 8. 明确不做（附一句理由，防止下一轮重开）
```

每篇方案必须含 **Alternatives considered**（至少一条被否的、以及否它的最强理由）与**代价**。
文档写作口径照 `docs/AGENTS.md`：只写当下事实、不写变迁史、不手抄生成物。

## 5. 明确不要做的（别浪费时间）

- **不要重研通知 / 后台送达**：MIUI 实测已定案（`docs/subsystems/notifications.md` §2.1/§2.2、契约 §15）——
  熄屏即冻结、服务被收走、亮屏不解锁不恢复；唯一路是厂商推送（需账号），已定为"以后再说"。
- **不要重开这些已否**：逐插件页面适配、桌面式右侧模型面板、FCM 直连、双进程保活、刷新令牌轮换、多中转实例。
- 不要跑全量门禁（connector 621 / flutter 1175 / boundary 369 目前全绿），本轮不改代码就跑不到它们。

## 6. 起手命令

```powershell
cd D:\sudy\myproject\dsh-mobile
Select-String -Path memory.md -Pattern '已知缺口|范围决定' -Context 0,40   # 缺口账
Get-ChildItem .agents\notes\implemented | Select-Object -Last 8             # 已定案的取舍
Select-String -Path connector\src\handlers.ts -Pattern "^  '.*': " | Select-Object -First 60  # 现有方法面
```

DSH 参考源码只读：`D:\sudy\github\deepseek-harness`。本机 Flutter SDK 查证：`node app/tools/flutter-api.mjs <符号>`。
