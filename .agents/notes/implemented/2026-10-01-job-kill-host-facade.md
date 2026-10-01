# Agent Note: `job.kill` 走宿主的人类发起门面，不在插件里复述它的语义

Status: implemented

## Problem

`job.kill` 看着是最简单的一个方法：拿着 `sid` 与 `jobId`，调一下"停任务"就完了。
但接之前有两个实现路径，而它们的差别不在代码量上：

- `ctx.jobs.kill(id, caller)` —— 注册表本身的方法，**也有**归属围栏
  （`jobs-local/src/index.ts:328-330` 的 `kill(id, caller?, reason?)` → `expect(id, caller)`）；
- `jobController.kill({ sessionId, jobId })` —— 宿主为"人发起的停止"准备的门面
  （`packages/api/job-controller/src/index.ts:43` 注册为 `jobController`、`:109-124` 的 `kill`）。

两条路都能停任务、都会拒绝别人会话的任务。差别是另外两件事：

1. **取消原因**：门面写的是 `'cancelled by the user'`（`:123`），而这个字符串会进**模型看到的工具结果**。
2. **错误码映射**：门面把「未知任务」与「不属于这个会话」**都**归成 `job/not-found`
   （`:114-119`，注释原文 "the client renders one story"），并明确要求
   "a producer-cancel throw propagates … instead of masquerading as job-not-found"（`:120-122`）。

## Decision

**`job.kill` 走 `jobController.kill`**，并把它的两件事原样转达；插件只做三件自己的事：
`sid` 反解（`session/not-found`）、`jobId` 形状校验（`protocol/bad-frame`）、
把门面的 `job/not-found` 转成本插件的 `ProtocolError`（其余错误照原样上抛）。

于是 `JobsPort` 上那个直接包 `jobs.kill` 的 `kill` **删掉**：留着它就是同一操作的第二个入口，
而两个入口的差别（原因字符串、错误映射）会随时间漂移。

准入门槛（可机械判定）：

1. 门面收到的是 **DSH 会话 id**（不是 `sid`），参数形状是 `{ sessionId, jobId }`。
2. `job/not-found` 转成协议码；**其他错误（例如 producer 的取消抛错）不得伪装成它**。
3. `jobId` 缺失 / 空串 / 非字符串 → `protocol/bad-frame`；`sid` 未知 → `session/not-found`。
4. 两种能力**可以独立缺失**：没有 `jobController` 的部署只列不停（`job.kill` 不在表里），
   没有 `jobs` 的部署两个都没有 —— 而 `repo.info.methods` 自动跟着变。

## Alternatives considered

1. 直接调 `ctx.jobs.kill(id, caller)`，自己补一个原因
   - 最强的理由：少一个服务依赖（`jobs` 我们已经接了），而且注册表本来就是权威；
     围栏也在它手里，安全性不打折。
   - 为何被否：那就得在**我们的代码里复述宿主的字符串** `'cancelled by the user'`。
     这个字符串不是装饰：它进模型看到的工具结果，会影响模型怎么解释"任务为什么没了"。
     DSH 改词的那天，桌面点停止与手机点停止会**静默分叉**，而没有任何测试会红
     （它两边的行为都"正常"）。同理还要自己复述"未知与外来都归 not-found"这条映射。
2. 两条路都保留（门面用于方法面，注册表那条留给将来的内部用途）
   - 最强的理由：将来也许有"非人发起"的停止（比如看护超时自动停），那时该走注册表。
   - 为何被否：那个用途还没有。留着一个没有调用方的第二个入口，等于给下一个人两个看起来
     都对的选项 —— 而它们的语义不同。真需要时再加，届时它的 caller 语义会更明确
     （自动停止该写什么 reason 是个新问题，不该由今天顺手留下的一条路径来暗示）。
3. 在插件里自己判归属（先 `listOwnedBy` 看这个 id 在不在，再决定要不要停）
   - 最强的理由：手机侧的错误更早、更可控；也能顺带覆盖"任务存在但不属于我"的情况。
   - 为何被否：那是**对注册表围栏的二手近似** —— `listOwnedBy` 读的是可见集合的快照，
     而围栏判的是注册表里的实时归属；两者在结算/移除的瞬间会不一致（`remove` 会把它从可见集合里拿掉）。
     多一条会漂移的判据，换来一个已经由权威给出的结论。

## Consequences

- 收益：手机点停止与桌面点停止在模型眼里是同一件事（同一原因、同一围栏、同一错误码）；
  插件侧不需要维护任何宿主语义的副本；`dsh/jobs.ts` 里两个端口职责清晰
  （`JobsPort` = 读投影与输出，`JobControlPort` = 人发起的控制）。
- 代价：新增一个可选服务依赖 `jobController`，而它由 `dsh-web-app` 提供、**base 里没有**
  （`packages/bundle/web-app/cordis.patch.yml:126-127`）—— 于是"只列不停"成为一种真实存在的部署形态，
  并有测试钉住它（`job.kill` 在那种部署里根本不在 `repo.info.methods` 里）。
- **仍未做**：`job.follow` / `job.unfollow`（任务输出订阅）。它们的成熟实现同样在宿主里
  （`jobController.follow` 是 `@Remote({mode:'stream'})`，`observeJobOutput` 已做 100 ms 合并与
  64 KiB 单帧上限，`packages/api/job-controller/src/index.ts:29,32,90-96`），
  所以下一轮的方向是**复用它**而不是自己写观察循环 —— 但要把它的 `opened` / `output` / `status`
  三帧映射到通道的帧上，那是另一处需要先定形状的决策。
