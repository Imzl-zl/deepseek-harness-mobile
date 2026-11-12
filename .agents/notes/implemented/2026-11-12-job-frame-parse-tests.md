# Agent Note: `parseJobFrame` 的直接用例 —— 顺带抓到帧上的 `sid` 被吞掉

Status: implemented

## Problem

`core/job.dart` 是 job 面的 **wire 边界**：连接器 → 手机的任务帧只在
`sync_client_impl._emitJobFrame` 一处解析（`app/lib/core/sync_client_impl.dart:1877`），
下游（`AppModel._applyJobFrame` → `JobBook` → 任务面板）拿到的都是 `JobFrame` 类型。
而这个解析函数**没有任何直接用例**。

上一轮改的是这一层的**消费方**（重开流替换而非追加，见
`implemented/2026-11-11-job-output-buffer.md`）；边界本身只有间接覆盖，
`app/test/job_panel_test.dart` **直接构造 `JobRow`** 交给 `JobBook`，根本不经过解析。
于是"线上帧的某个字段有没有落到 `JobRow`"这件事，组件用例全绿也证明不了。

**本轮就靠这一层抓到一个真缺陷**：

| 事实 | 位置 |
|---|---|
| 连接器给 `opened` / `status` 帧的行**盖上 `sid`** | `connector/src/job-subscriptions.ts:98-101` |
| `JobRow.sid` 的注释写明"帧路径上靠它归桶" | `app/lib/core/job.dart` 的 `JobRow` 文档 |
| `JobBook._applyRow` 按 `row.sid ?? fallbackSid` 归桶 | `app/lib/data/job_book.dart:222` |
| `job.list` 那条路解析了 `sid` | `app/lib/wire/rpc/job.dart` 的 `_jobRowOf` |
| **帧路径的 `_parseRow` 从来没读 `sid`** | `app/lib/core/job.dart` 的 `_parseRow` |

后果：`row.sid` 恒 `null` ⇒ 永远退回归"当前会话"。
`JobBook._applyRow` 的退路是"只在当前会话的桶已存在时归"，而实际看会话时那个桶**一定存在**
⇒ 一个属于 B 的任务帧在用户看 A 时会**塞进 A 的桶**（`_put(A, row)`），
正是 2026-10-15 真机反馈"正在看的会话不显示 chip、别的会话凭空多一个"
（`job_panel_test.dart` 的回归用例叫「帧带 sid 就按 sid 归桶」）—— 回归用例绿着，
因为它喂的是手工构造的 `JobRow`，绕过了被吞掉的那一层。

> 覆盖率基数（实测，不是抄的）：把本批用例拿掉后跑 `flutter test --coverage`，
> `core/job.dart` = **49/97 ≈ 50.5%**（与上一轮记的 51% 一致 —— 那个数字是对的）；
> 补完这一批 = **97/97**。读取顺序注意：lcov 先写 `LF` 再写 `LH`，按 `LH` 先赋值
> 会把每个文件的命中数读成**上一个文件**的（我第一次就这么读出了 40.6% 的假数）。
> 教训与 `tools.md` 的变异校验小节同一条：**测量脚本的输出必须先被质疑，再被引用**。

## Decision

1. 新增 `app/test/job_frame_parse_test.dart`（18 条），照 `parseJobFrame` 的四支逐项钉：

   | 组 | 钉什么 |
   |---|---|
   | 四种 kind 正样本 | `opened` / `output` / `status` / `error` 的**每个字段**（含 `from` / `next` / `lossy` / `chunks.at` / `channel` / `gapBefore`） |
   | 坏载荷必须抛 | 载荷不是对象、`jobId` 缺失/空串/非串、`kind` 不认识/缺失、`chunks` 不是数组（含"缺键"与"空数组"两件事）、`at`/`next`/`startedAt`/`outputTotal`/`from` 不是整数、`job` 不是对象 |
   | 展示字段兜底 | `status`/`kind`/`label` 非 String ⇒ `running`/`''`/`''`；可选四键缺省即 `null`；`finishedAt` 只认 `int`；`error` 缺 `message` ⇒ `'未知原因'` |
   | `output` 的可选取值 | `channel` 三种线上词 + 缺席 + 非法值、`gapBefore` / `lossy` 只有 `true` 算真、认不出的 chunk 条目跳过 |

2. **`_parseRow` 补读 `sid`**（一行）：连接器已经在帧上盖了它，`JobRow` 与 `JobBook` 都按它
   归桶，只有解析层没读。修法不是"改语义"，而是把**已经存在于线上的字段**接到它唯一的读者上。

3. **`status` / `kind` / `label` 的兜底保持原样**，并把兜底写成断言。理由写在用例注释里：
   它们兜的是**展示字段**（画成什么样），不是**身份字段**（是谁、接着从哪读）。
   身份与游标（`jobId` / `kind`(帧) / `chunks` / `at` / `next` / `startedAt` / `outputTotal`）
   认不出就抛，由调用方转成 `JobError` 让面板说"这一帧没解出来"。

## 准入判据

`app/test/job_frame_parse_test.dart` 18 条，全绿即通过。`core/job.dart` 覆盖率
**97/97 = 100%**（`flutter test --coverage` 后按 `LF`/`LH` 读，注意 lcov 里 `LF` 在 `LH` 之前）。

变异校验（**先 grep 确认变异落地，再看红**）：

| 变异 | 结果 |
|---|---|
| 删掉 `jobId.isEmpty`（变成只查类型） | 恰好 1 条红：`缺 jobId / jobId 是空串 / 不是字符串`（`Expected: throws FormatException / Actual: <Closure>`） |
| 删掉 `_parseRow` 里的 `sid:`（本次修复的前后对照） | 恰好 1 条红：`opened：行 + from`（`Expected: 's1' / Actual: <null>`）—— 这是**红先绿后**，不是事后补的变异 |

## Alternatives considered

1. **只钉"当前行为"（`sid` 恒 `null`），把发现写进报告**
   - 最强的理由：这一批的任务是"补用例"，不是"改语义"。
   - 为何被否：`null` 不是"当前语义"，是**漏读**。把漏读写成断言等于用测试给它背书，
     而线上字段、`JobRow` 的文档、`JobBook` 的判据、`job.list` 那条路四者都指向"该读"。
     `app/test/` 里最贵的一条纪律是"用例要通过的必须是那条机制"
     （`proposed/2026-11-11-open-findings.md` 第四节）——给它钉一个假的终态正好违背它。
2. **顺手把 `_parseRow` 收紧成 `job.list` 那样（`status` 缺了就抛）**
   - 最强的理由：`wire/rpc/job.dart` 的注释明写 "`status ?? 'running'` 正是「任务永远转」的形态"，
     两条路对同一个键给了两种纪律。
   - 为何暂时不改：那是**语义变更**（一帧解不开会从"画一行 running"变成"整帧报错"），
     影响面是 `mergeJobRow` 的终态规则与通知判定。本批的约定是"发现方案不成立就停下来回报"，
     所以只把矛盾写进 `Consequences`，等下一批单独定。
3. **让 `sync_client_impl` 那条 try/catch 顺便补齐 sid（从帧头拿）**
   - 最强的理由：不改 `core/` 的解析。
   - 为何被否：帧头的 `sid` 是**连接层**的路由信息，而 `body` 里的 `sid` 是**连接器盖的行归属**
     （两者在 `job` 帧上恰好同源，但这属于巧合，不是契约）。在边界上补，语义才只有一处。

## Consequences

- 收益：`core/job.dart` 从"解析函数零直接用例"变成 18 条边界用例；`sid` 不再是黑洞 ——
  帧路径与 `job.list` 路径对同一个键给出同一个读法。
- 收益：`app/test/` 的 job 面第一次有"解析 → 类型"的判据，与 `job_panel_test.dart` 的
  "`JobRow` → 桶"判据拼成完整一格（这正是 `open-findings.md` §4.2 要求的分层）。
- 代价：`parseJobFrame` 的形状改动从此会红在 `job_frame_parse_test.dart` 上（这是想要的）。
- **遗留（需要产品判断，未动）**：`_parseRow` 对 `status` 的兜底仍是 `'running'`，
  而 `job.list` 那条路要求它是必填且**不许兜**（同一份 `JobRow`，两种纪律）。
  两条路的输入不同（`job.list` 是应答，帧是推送），所以"是否统一"要单独判一次；
  本批只把它写成断言，没有改。
- 顺带记：`tools.md` 里 `flutter test` 的项数此前已漂移 33 条（写 1805，实测 1838），
  本批改成 **1856**。数字只有一处来源这一点没变，但"只在改测试时顺便对一次"显然不够 ——
  下次动 `app/test/` 时先跑一遍对数字。
