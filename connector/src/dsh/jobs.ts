/**
 * 后台任务适配（契约 §7）。
 *
 * 服务：`ctx.jobs` = `JobRegistry`，服务键 `jobs`
 * （`packages/jobs/jobs/src/index.ts:41-45` 声明、`:93` 注册）。
 * 它是**抽象 seam**：直接加载 `@deepseek-ai/dsh-jobs` 会在构造时抛错（`:90-92`），
 * 必须由实现包 `dsh-jobs-local` 注册 —— 所以能力位要真的探，不能假设它在。
 *
 * 本文件把三个反直觉点固化成端口契约，让调用方无从写错：
 *
 * 1. **`list(caller)` 会把无主任务并进每个会话**：过滤式是
 *    `job.owner === undefined || job.owner.id === caller`
 *    （`packages/jobs/jobs-local/src/index.ts:308`）。所以要「严格属于本会话」的行必须自己再排掉无主。
 *    而**不传 caller 只返回无主任务**（`packages/jobs/jobs/src/index.ts:113-114`），不是全集。
 *    → 端口只提供 `listOwnedBy()`，不暴露原始的 `list`。
 * 2. **`read` 会吃掉模型的游标**：它把 `modelCursor` 推到 `total`
 *    （`packages/jobs/jobs-local/src/index.ts:444-456`），等于把模型本该看到的输出吞掉；
 *    终态首读还会把环形缓冲裁到 settled cap（`:449`）。→ 端口只提供 `readOutput`（走 `readAt`）。
 * 3. **`ctx.jobs.events` 没有任何合并窗口**：append 一次发一次
 *    （`jobs-local/src/index.ts:523-524`）。`flushMs`（100 ms）与「输出追加不刷新列表」
 *    都是 `dsh-api-job-controller` 的行为（`packages/api/job-controller/src/index.ts:29`、
 *    `src/rows.ts:36-40`），不在这一层。→ 调用方必须自己节流。
 */
import type { JobChunk, JobEvent, JobRegistry, JobView } from '@deepseek-ai/dsh-jobs'

import { ProtocolError } from '../protocol/errors.js'
import type { JobChunkOut, JobOutputFrame, JobRowView } from '../protocol/job-output.js'

/**
 * 任务行。字段取自 `JobView`（`packages/jobs/jobs/src/view.ts:65-100`）。
 *
 * 形状定义在协议层（`protocol/job-output.ts` 的 `JobRowView`）而不是这里：
 * 它与 `job.list` 的响应、以及 `job` 帧里 `opened` / `status` 两帧带的任务投影**是同一个形状**，
 * 三处各写一份必然会漂移。适配器只负责把 DSH 的 `JobView` 映射成它（**逐字段**，绝不 spread）。
 */
export type JobRow = JobRowView

function toChunkOut(chunk: JobChunk): JobChunkOut {
  return {
    at: chunk.at,
    text: chunk.text,
    ...(chunk.channel === undefined ? {} : { channel: chunk.channel }),
    ...(chunk.gapBefore === undefined ? {} : { gapBefore: chunk.gapBefore }),
  }
}

function toRow(view: JobView): JobRowView {
  return {
    id: view.id,
    kind: view.kind,
    label: view.label,
    status: view.status,
    startedAt: view.startedAt,
    outputTotal: view.output.total,
    ...(view.progress === undefined ? {} : { progress: view.progress }),
    ...(view.detail === undefined ? {} : { detail: view.detail }),
    ...(view.finishedAt === undefined ? {} : { finishedAt: view.finishedAt }),
  }
}

export interface JobOutput {
  chunks: readonly JobChunk[]
  /** 续读偏移，**恒为 chunk 边界**（`packages/jobs/jobs/src/types.ts:176-181`）。 */
  next: number
  /** `from` 掉到最早保留字节之前，前面有缺口 —— 必须显式上报，不许静默拼接。 */
  lossy: boolean
}

export interface JobsPort {
  /** 只列**严格属于该会话**的任务（无主任务不算）。 */
  listOwnedBy(dshSessionId: string): JobRow[]
  /** 按偏移**非消耗式**读输出；`caller` 必须给，否则有主任务读不到。 */
  readOutput(id: string, from: number, dshSessionId: string): JobOutput
  /**
   * 订阅该会话的任务事件。
   *
   * 内部再用 owner 过滤一次：`{ owner: S }` 的过滤器同样会收到**无主任务**的事件
   * （`jobs-local/src/events.ts:85` 的 `ownerId !== undefined` 短路），
   * 不过滤的话无主任务会同时出现在所有会话里。
   */
  subscribe(dshSessionId: string, listener: (event: JobEvent) => void): () => void
}

export function createJobsPort(jobs: JobRegistry): JobsPort {
  return {
    listOwnedBy(dshSessionId) {
      // 传 caller 拿到「本会话 + 无主」，再排掉无主才是「严格属于本会话」。
      return jobs
        .list(dshSessionId as never)
        .filter((view) => view.owner !== undefined)
        .map(toRow)
    },

    readOutput(id, from, dshSessionId) {
      // `readAt(id, from, caller)` —— caller 是**第三个**参数（`jobs/src/index.ts:148`）。
      const read = jobs.readAt(id as never, from, dshSessionId as never)
      return { chunks: read.chunks, next: read.next, lossy: read.lossy }
    },

    subscribe(dshSessionId, listener) {
      // `subscribe(filter, listener): () => void`（`jobs/src/types.ts:243-253`）。
      return jobs.events.subscribe({ owner: dshSessionId as never }, (event) => {
        // **无主要有两种形状**：`registered` / `progress` / `stopping` / `removed` / `settled`
        // 把任务放在 `event.job` 里，而 `output` 把 `owner` 放在**事件自己**身上
        // （`jobs/src/types.ts:200-226`）。`owner` 无主时是**键整个缺失**，不是 undefined 值
        // （`jobs-local/src/index.ts:420`），所以两条路都按"缺键即无主"判。
        //
        // 漏掉 `output` 那一路的后果：无主任务的输出会插进**每一个**会话的订阅流，
        // 而手机侧在清单里看不到那个任务（`listOwnedBy` 已经把它排掉了）——
        // 表现是"收到一段没有出处、也不属于任何会话的输出"。
        const unowned =
          event.type === 'output' ? event.owner === undefined : event.job.owner === undefined
        if (unowned) return
        listener(event)
      })
    },
  }
}

// ---------------------------------------------------------------------------
// 任务控制：走**宿主的人类发起门面**，不直接调注册表
// ---------------------------------------------------------------------------

/**
 * `jobController` 是宿主已经做好的"人发起"任务门面：
 * `packages/api/job-controller/src/index.ts:43`（`super(ctx, 'jobController', …)`）、
 * `:109-124` 的 `kill`。
 *
 * **为什么不让 `JobsPort` 自己调 `jobs.kill`**（它也有围栏：`jobs-local/src/index.ts:328-330`
 * 的 `expect(id, caller)`）——差别在另外两件事，而两件都不是我们能自己复述的：
 *
 * 1. **取消原因**：门面写的是 `'cancelled by the user'`（`:123`），这个字符串会进模型看到的
 *    工具结果。我们若在自己代码里抄一遍，DSH 改词时两边会**静默分叉**：桌面点停止与手机点停止
 *    在模型眼里变成两件事。
 * 2. **错误码映射**：门面把「未知任务」与「不属于这个会话的任务」**都**归成 `job/not-found`
 *    （`:114-119` 的注释原文 "the client renders one story"）——这正是 §3.1 那个码的语义。
 *    自己做就得再判一次，而多判一次就多一处会漂移的判据。
 *
 * 它由 `@deepseek-ai/dsh-web-app` 提供（`packages/bundle/web-app/cordis.patch.yml:126-127`），
 * **base 里没有** —— 所以它是可选能力：缺了就不挂 `job.kill`（见 `handlers.ts` 的按需挂表）。
 */
export interface JobControlPort {
  /**
   * 请人（手机）之意停掉一个任务。
   *
   * @returns 注册表是否受理（`already-finished` = 已是终态）。**落终态要等 `settled` 事件**，
   *   不做乐观更新。
   * @throws {ProtocolError} `job/not-found`：未知任务，或该任务不属于这个会话。
   *   其余错误（例如 producer 的取消抛错）照原样上抛 —— 门面的注释明说它**不得**
   *   伪装成 job-not-found（`:120-122`）。
   */
  kill(dshSessionId: string, jobId: string): 'requested' | 'already-finished'

  /**
   * 打开一个任务的输出订阅（契约 §5.3）。
   *
   * **不自己写观察循环**：`jobController.follow` 已经做好了合并与限帧
   * （`packages/api/job-controller/src/index.ts:29,32` 的 100 ms / 64 KiB，
   * 观察循环在 `src/observe.ts`），本方法只把它的三帧映射成通道的载荷。
   * **调用方持有 `signal` 的生命周期**：中止即终止宿主流。
   *
   * @throws {ProtocolError} `job/not-found`：任务不存在，或不属于这个会话。
   */
  follow(
    request: { dshSessionId: string; jobId: string; from?: number },
    signal: AbortSignal,
  ): AsyncIterable<JobOutputFrame>
}

/** `JobController` 里我们真正用到的那一面（收窄成端口，便于脱离 DSH 测试）。 */
export interface JobControlService {
  kill(request: { sessionId: unknown; jobId: unknown }): { outcome: 'requested' | 'already-finished' }
  follow(request: { sessionId?: unknown; jobId: unknown; from?: number }, signal: AbortSignal): AsyncIterable<JobFollowFrameLike>
}

/** 宿主 follow 流的三帧（`packages/api/job-controller/src/types.ts:62-92`）。 */
export type JobFollowFrameLike =
  | { type: 'opened'; job: JobView; from: number }
  | { type: 'output'; chunks: readonly JobChunk[]; next: number; lossy?: true }
  | { type: 'status'; job: JobView }

/** 宿主错误对象上的 `code`（`RemoteError` 带它；这里只结构化地读，不依赖它的类型）。 */
function errorCodeOf(error: unknown): string | undefined {
  const code = (error as { code?: unknown } | null)?.code
  return typeof code === 'string' ? code : undefined
}

/** 宿主把「未知任务」与「不属于这个会话」都归成这一个码（`:114-119`）。 */
function asNotFound<T>(work: () => T): T {
  try {
    return work()
  } catch (error) {
    if (errorCodeOf(error) === 'job/not-found') {
      throw new ProtocolError('job/not-found', '任务不存在，或不属于这个会话')
    }
    throw error
  }
}

export function createJobControlPort(controller: JobControlService): JobControlPort {
  return {
    kill(dshSessionId, jobId) {
      return asNotFound(() => controller.kill({ sessionId: dshSessionId, jobId }).outcome)
    },

    async *follow(request, signal) {
      const frames = asNotFound(() =>
        controller.follow(
          {
            sessionId: request.dshSessionId,
            jobId: request.jobId,
            ...(request.from === undefined ? {} : { from: request.from }),
          },
          signal,
        ),
      )
      // 逐帧映射，**不 spread 宿主的帧**：`JobView` 带着 `owner`（DSH 会话 id），
      // 而它绝不能过线（§5.1 的别名纪律）。
      for await (const frame of frames) {
        switch (frame.type) {
          case 'opened':
            yield { kind: 'opened', jobId: request.jobId, job: toRow(frame.job), from: frame.from }
            break
          case 'output':
            yield {
              kind: 'output',
              jobId: request.jobId,
              chunks: frame.chunks.map(toChunkOut),
              next: frame.next,
              ...(frame.lossy === undefined ? {} : { lossy: frame.lossy }),
            }
            break
          case 'status':
            yield { kind: 'status', jobId: request.jobId, job: toRow(frame.job) }
            break
        }
      }
    },
  }
}
