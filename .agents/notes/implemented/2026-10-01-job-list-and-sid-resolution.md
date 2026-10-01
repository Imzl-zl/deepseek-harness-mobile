# Agent Note: `job.list` —— 别名反解的两个回答，与"可选服务的方法该不该挂"

Status: implemented

## Problem

`job.list` 是第一个**需要从 `sid` 反解回 DSH 会话 id** 的方法（此前 `session.list` 只做正向分配），
于是两个问题第一次必须给出答案，而两个都不能靠猜：

1. **别名不认识时回什么？** 回空列表？还是错误？回哪个码？
2. **服务可能不存在的方法（`jobs` 是可选服务）该不该出现在 handler 表里？**
   出现的话，`repo.info` 报的 `methods` 里就会有它，而手机点了会拿到 `connector/unsupported`；
   不出现的话，表会随环境变化。

顺带发现一条真实门槛：**别名没分配过就反解不出来** —— 手机跳过 `session.list` 直接问
`job.list` 会得到 not-found。这不是缺陷（sid 只能从清单里拿到），但它意味着这条路径必须被测试覆盖，
否则第一次真机联调会以为"任务列表坏了"。

## Decision

- **未知别名 → `session/not-found`，绝不回空列表**；`sid` 缺失或形状不对 → `protocol/bad-frame`。
  两条规则写进契约 §5.7 末尾（跨方法规则，不只属于 `job.list`）。
- **可选服务的方法按需挂**：`deps.jobs` 存在才把 `job.*` 放进表里。
  于是 `repo.info` 报的 `methods`（表的键）**自动**反映本机能力 —— 手机侧看到的是"没有这个方法"，
  而不是一个点开才报错的按钮。

准入门槛（可机械判定）：

1. `sid` 未知 → 抛 `session/not-found`（单测 + e2e 都断言码，且 e2e 断言连接仍 `serving`）。
2. `sid` 缺失 / 空串 / 非字符串 / params 不是对象 → `protocol/bad-frame`（**与 not-found 分开**：
   请求不合法 ≠ 数据不存在）。
3. `job.list` 调适配器时拿到的是 **DSH 会话 id**（断言适配器收到的是什么，而不只是"有结果"）。
4. 没有 `jobs` 端口时 `job.list` 不在表里，且 `repo.info.methods` 里也没有它。

## Alternatives considered

1. 未知别名回空列表
   - 最强的理由：手机侧少一个错误分支 —— 空列表就是空列表，渲染出来是"没有任务"。
   - 为何被否：**那是在撒谎**。"这个会话没有任务"与"我不认识这个会话"对手机是两件事：
     前者该显示空态，后者该把这个会话从列表里删掉（§3.1 给 `session/not-found` 的客户端行为）。
     用一个看起来更省事的结果抹掉这个区别，代价是手机永远修不掉一条僵尸会话。
2. 未知别名回 `session/window-missed` 或 `session/revision-newer` 之类
   - 最强的理由：都是"会话相关"的码，手机已有分支，不必新增语义。
   - 为何被否：那两个码的客户端行为是「走快照」/「刷新后重试」——它们说的是"数据在，但你手里的旧了"，
     而这里根本没有这个会话。用错码会把手机引向一次注定失败的重试。
3. 缺服务也挂方法，调用时回 `connector/unsupported`
   - 最强的理由：handler 表**恒定**，`repo.info` 的清单不随环境变化，手机侧解析与缓存更简单。
   - 为何被否：它会留下一条实际走不到的分支（缺服务时清单里却有这个方法名），
     而 `caps`（服务在不在）与 `methods`（我们接没接上）两个信号会开始漂移 ——
     手机拿到 `unsupported` 时也无法判断"永久置灰"还是"稍后重试"。
     按需挂表则让两者同源：**表里没有 = 能力不存在**。
4. 把 `jobs` 升成必需服务（这样 `job.list` 总是存在）
   - 最强的理由：装配更简单，方法面不必有条件分支。
   - 为何被否：`jobs` 是可选的（`caps.ts` 的 OPTIONAL_SERVICES 有它、契约 §7 也是这么划的）。
     把它升成必需，会让不带 jobs 的部署**整个插件都不挂载** —— 用"少一个方法"换"整个通道没了"。

## Consequences

- 收益：方法面带 `sid` 的调用第一次有了统一的两条规则（未知 → not-found、形状坏 → bad-frame），
  后续 `job.follow`/`kill`、`session.page`/`subscribe` 都能复用；
  可选能力在方法面上有了单一表达（表里有没有），不必再写"缺服务时回 unsupported"这种分支。
- 代价：`createHandlers` 多一处条件挂载；`repo.info.methods` 会随部署环境变化
  （这是**有意的**：它就是本机能力清单）。
- **仍未做**：`job.list` 之外的任务方法（`job.follow`/`job.unfollow`/`job.kill`）、
  会话订阅与翻页（`session.subscribe`/`page`/`unsubscribe`）、`interactions.ts` 的测试缺口。
