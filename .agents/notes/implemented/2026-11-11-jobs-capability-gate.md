# Agent Note: `caps.jobs` 决定发不发 `job.list` —— 缺服务不能画成故障

Status: implemented

## Problem

连接器把 `jobs` 列为**可选服务**（`OPTIONAL_SERVICES`，`connector/src/dsh/caps.ts:43-48`），
缺它时 `repo.info` 如实报 `caps.jobs: false`，并且**根本不挂 `job.*`**
（`connector/src/handlers.ts:1582` 的 `if (deps.jobs !== undefined)`）。

手机侧解析 `repo.info` 时只读了四个能力位（`references` / `files` / `changes` / `plugins`），
`caps.jobs` **被丢掉了**。而 `refreshJobs` 是 `openSession` 的登记表触发项之一 ——
于是每次开会话都向一个**不存在的方法**发一次 `job.list`，拿回 `connector/unsupported`，
`_recordError('任务读取失败')`。

症状：在一个没装 jobs 的部署上，手机**每开一个会话就报一次"任务读取失败"**，
而那不是故障 —— 是这台电脑没有这个面。（任务面板本身是空表，看起来像"没有任务"。）

## Decision

补上这个能力位，**并且把它与另外四个区别对待**：

| 能力位 | 缺了怎么办 | 默认（键缺席时） |
|---|---|---|
| `references` / `files` / `changes` / `plugins` | **不画那一屏** | `false`（没有就不显示） |
| `jobs` | **不发 `job.list`** | **`true`**（老连接器照样能拉） |

两个方向都是刻意的：

- 前四个决定 **UI 显不显示**，猜错成"显示"就是一块永远读不到的空面 —— 所以默认假。
- `jobs` 决定 **要不要发一次调用**，猜错成"不发"就是整块能力凭空消失；
  猜错成"发"只是一次多余但成功的调用 —— 所以默认真。
  这也是唯一一个"不发"比"发了失败"更好的时机：**方法不存在** vs **方法存在但空表**。

实现：`RepoInfo.jobsAvailable`（`caps['jobs'] != false`）→ `AppModel._jobsAvailable`
（默认 `true`）→ `refreshJobs` 开头 `if (!_jobsAvailable) return;`。

## 准入判据

`app/test/jobs_capability_test.dart` 三条：

1. `caps.jobs: false` ⇒ 不发 `job.list`；
2. `caps.jobs: true` ⇒ 照常发；
3. **caps 里没有这个键**（老连接器）⇒ 按"有"处理，照常发。

变异校验：删掉 `if (!_jobsAvailable) return;` ⇒ 第 1 条红
（`Expected: empty / Actual: ['job.list']`）。

## Alternatives considered

1. **与另外四个一致：`== true` 且默认 `false`**
   - 最强的理由：五个能力位同一套写法，读起来规整。
   - 为何被否：老连接器（或不报这个键的版本）会**整块任务面消失**，而它本来能用。
     规整换一个真实回归，不划算 —— 所以这个"不一致"写在两处注释里说明理由。
2. **在 UI 层把任务面板整个藏掉**
   - 最强的理由：没有这个面就不该有入口。
   - 为何被否：面板是侧栏第三个 tab，藏掉它等于让 tab 集合随能力位变化 ——
     用户看到的界面结构会因电脑而异，而 tab 结构是信息架构，不该是能力位的函数。
     这一批只解决"别报假故障"；面板显示空表是如实降级（见下条的遗留）。
3. **让连接器在缺 jobs 时也挂一个恒回空表的 `job.list`**
   - 最强的理由：手机侧零改动。
   - 为何被否：那是在**替宿主造一个它没有的面**——`listOwnedBy` 需要 JobRegistry，
     而缺的正是它。造一个恒空的实现，等于把"没有任务"与"没有这个能力"混成同一句话。

## Consequences

- 收益：没装 jobs 的部署上，手机不再每开一个会话报一次假故障。
- 代价：多一个 `RepoInfo` 字段；`caps` 的五个能力位从此有**两种默认方向**，
  而这种不对称必须靠注释维持（两处都写了理由：`repo_info.dart` 与 `wire/rpc/repo.dart`）。
- 遗留：`caps.subagents` / `caps.approval` / `caps.questions` **仍未解析**。
  前两者的缺省症状不同（子智能体是投影读空、审批是事件根本不产生），没有"发一个不存在的方法"
  这一层，所以**没有在这一批处理**。真要收口，判据应该是"missing caps 会不会引发一次注定失败的调用"，
  而不是"caps 里还有几个键没读"。
