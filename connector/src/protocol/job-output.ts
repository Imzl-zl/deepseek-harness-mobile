/**
 * 任务输出帧的载荷（契约 §3 的 `job` 帧、§5.3 的订阅规则）。
 *
 * ## 为什么是独立帧类型而不是复用 `live`
 *
 * `live` 的两个数字字段已经被 assistant 流占满：契约术语表把 `stream` 定义成
 * 「一次 assistant 尝试的流 id」，而手机侧对 `rev` 的读法是硬性的 ——
 * `rev == last + 1` 追加、`rev` 跳跃即**丢弃整条流**（`docs/subsystems/app-channel-client.md` §2.2）。
 * 任务输出的"推进量"是**输出字节偏移**（会跳号），塞进 `rev` 会让手机把 assistant 的文本丢掉。
 * 给同一个字段第二个含义，正是 `credit` 那一处已经否掉的做法（§4.3）。
 *
 * 于是 `job` 与 `live` **共享易变流的语义**（不占 `seq`、不进重放窗口、不参与 ack、
 * 恢复时不回带、满窗时可暂停），但形状各归各的。
 *
 * ## 三帧照宿主一对一
 *
 * `dsh-api-job-controller` 的 `jobController.follow` 已经是成熟的观察流
 * （`packages/api/job-controller/src/index.ts:90-96` 的 `observeJobOutput`：
 * 100 ms 合并、64 KiB 单帧上限、结算 drain 完给 `status` 后正常关闭，`:29,32`）。
 * 本文件**照它一对一**，只做两件事：把 `JobView` 换成不下发 `owner` 的投影、给错误一条通道
 * （宿主没给，而 `docs/plugin-and-jobs-notes.md` §B.4 要求手机显式渲染"实时输出流中断"）。
 *
 * 形状定案与被否方案：`.agents/notes/implemented/2026-10-01-job-output-transport-shape.md`
 */

/**
 * 输出通道标签。与 DSH 的 `JobChannel` 同义（`stdout` / `stderr` / `log`，其中 `log` 只给观察者）。
 *
 * **自带一份而不是 import DSH 的类型**：`protocol/` 不许依赖 `@deepseek-ai/*`（分层规则，
 * `tests/layering.test.ts` 会拦）—— 那正是"协议层能在纯 Node 下跑 fixtures"的前提。
 * 映射发生在 `dsh/jobs.ts`（适配器），那里 import DSH 是正确的方向。
 */
export type JobChannelOut = 'stdout' | 'stderr' | 'log'

/** 输出块：偏移**永不移动**，`gapBefore` 表示前面有字节丢了（可能来自 producer，也可能来自保留策略）。 */
export interface JobChunkOut {
  at: number
  text: string
  channel?: JobChannelOut
  gapBefore?: true
}

/**
 * 给手机看的任务行投影。
 *
 * 与 `job.list` 的**同一形状**（同一个投影函数产出），并且**不含 `owner`**：
 * 那是 DSH 的会话 id，中继与手机只见 `sid`（§5.1）。
 *
 * **但带 `sid`**：`job` 帧（`opened` / `status`）本身不带会话，手机只能猜"这个任务
 * 归哪个会话"—— 2026-10-15 真机上猜错的那次：用户先开 A 再开 B，B 里新起的任务被
 * 归到 A，于是**正在看的 B 不显示后台任务 chip**，A 反而凭空多一个。
 * 连接器本来就握着别名表（`owner` → `sid`），所以这件事由它做，手机不猜。
 */
export interface JobRowView {
  id: string
  kind: string
  label: string
  status: 'running' | 'stopping' | 'completed' | 'killed' | 'failed'
  progress?: string
  detail?: string
  startedAt: number
  finishedAt?: number
  /** 已产出的总字节数；正文走 `output` 帧。 */
  outputTotal: number
  /** 这个任务属于哪个会话（**手机见的 sid**）。帧路径上靠它归桶。 */
  sid?: string
}

/** 一条任务输出订阅上会出现的四种载荷（job 帧的 ox）。 */
export type JobOutputFrame =
  | {
      kind: 'opened'
      jobId: string
      job: JobRowView
      /** 第一帧 `output` 从这里继续（手机据此拼自己的尾部缓冲）。 */
      from: number
    }
  | {
      kind: 'output'
      jobId: string
      chunks: readonly JobChunkOut[]
      /** 读完这一帧后应从哪个偏移继续。 */
      next: number
      /** 请求的偏移与 `chunks` 之间已有字节被淘汰 —— 手机必须显式提示。 */
      lossy?: true
    }
  | { kind: 'status'; jobId: string; job: JobRowView }
  | {
      /**
       * 订阅中断（宿主流出错，或出帧失败）。
       *
       * **宿主没有这一帧**：它的 `follow` 出错就是抛。而设计要求手机把中断**显式渲染**出来
       * （`docs/plugin-and-jobs-notes.md` §B.4 的「实时输出流中断」），所以通道补一条。
       * 收到它只表示这段订阅结束了，任务本身可能还在跑 —— 手机按 `status` 是否来过判断。
       */
      kind: 'error'
      jobId: string
      message: string
    }
