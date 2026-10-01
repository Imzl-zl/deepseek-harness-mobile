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

/** 任务行。字段取自 `JobView`（`packages/jobs/jobs/src/view.ts:65-100`）。 */
export interface JobRow {
  id: string
  kind: string
  label: string
  status: JobView['status']
  progress?: string
  detail?: string
  startedAt: number
  finishedAt?: number
  /** 已产出的总字节数；正文要另走 `readOutput`（`view.ts:99`）。 */
  outputTotal: number
}

function toRow(view: JobView): JobRow {
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
  /**
   * 请求停止。返回 `'requested'`（已受理）或 `'already-finished'`（已是终态）。
   *
   * **对处于 `stopping` 的任务会再次调用 producer 的 `cancel`**
   * （`jobs-local/src/index.ts:458-468`），别把它当「只发一次」。
   * 落终态要等 `settled` 事件，不做乐观更新。
   */
  kill(id: string, dshSessionId: string): 'requested' | 'already-finished'
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

    kill(id, dshSessionId) {
      // `kill(id, caller?, reason?)`（`packages/jobs/jobs/src/index.ts:160`）。
      return jobs.kill(id as never, dshSessionId as never)
    },

    readOutput(id, from, dshSessionId) {
      // `readAt(id, from, caller)` —— caller 是**第三个**参数（`jobs/src/index.ts:148`）。
      const read = jobs.readAt(id as never, from, dshSessionId as never)
      return { chunks: read.chunks, next: read.next, lossy: read.lossy }
    },

    subscribe(dshSessionId, listener) {
      // `subscribe(filter, listener): () => void`（`jobs/src/types.ts:243-253`）。
      return jobs.events.subscribe({ owner: dshSessionId as never }, (event) => {
        // `owner` 无主时是**键整个缺失**，不是 undefined 值（`jobs-local/src/index.ts:420`）。
        if (event.type !== 'output' && 'job' in event && event.job.owner === undefined) return
        listener(event)
      })
    },
  }
}
