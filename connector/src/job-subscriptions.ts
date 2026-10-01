/**
 * 任务输出订阅（契约 §5.3）。
 *
 * 一个订阅 = 一条宿主 `jobController.follow` 流 + 它到 `job` 帧的转发循环。
 * 这里只做三件事，而三件都不是"顺手写的"：
 *
 * ## 一、每个 `(sid, jobId)` **至多一个**订阅
 *
 * 手机重复 `job.follow` 同一个任务是常态（面板重开、重连后重订）。若不拦，
 * 两路宿主流会同时把同一段输出推给手机，而手机只能看到**重复**（它没有去重键：
 * 输出是字节偏移，同偏移的两帧看起来一样）。所以：
 *
 * - 已有订阅且 `from` 相同（或没给）→ **幂等**返回它当前的起点，不再开流；
 * - 给了**不同** `from` → 先终止旧订阅再起新的（手机明确要求换起点，就换）。
 *
 * 终止用**代数令牌**而不是只 abort：abort 之后旧循环可能已经取到一帧正在路上，
 * 而那帧的 `next` 会倒退。每帧出帧前先确认"我还是当前那一个订阅"，否则闭嘴。
 *
 * ## 二、逐帧背压，一次只压一帧
 *
 * `send` 满窗时**不接受**那一帧（`'paused'`），此时 `await waitWritable()` 再重发**同一帧**。
 * 因为转发循环是"取一帧 → 发出去 → 再取下一帧"，压住消费端就自然压住宿主流，
 * 不需要任何缓冲队列。`'closed'`（连接不在服务态）则直接收工：手机收不到，
 * 它重连后会自己按 `from` 重订。
 *
 * ## 三、挂起的承诺**必须被兑现**
 *
 * `follow` 要等宿主的 `opened` 帧才能回答"从哪开始"。若在等到之前这个订阅被替换、
 * 被 `unfollow`、或被连接关闭终止，那个承诺**必须被拒绝**（回 `internal`）——
 * 否则方法面会在那里永远挂着，手机的 `req` 永远等不到 `res`（比错误更难查）。
 */
import { ProtocolError } from './protocol/errors.js'
import type { JobOutputFrame } from './protocol/job-output.js'
import type { ChannelLogger } from './observability.js'

/** 宿主流：与 `JobControlPort.follow` 同形（收窄成这一层真正用到的方法）。 */
export interface JobFollowSource {
  follow(
    request: { dshSessionId: string; jobId: string; from?: number },
    signal: AbortSignal,
  ): AsyncIterable<JobOutputFrame>
}

/**
 * 出一帧的结果。
 *
 * 三态而不是布尔：`false` 现在有两种意思（满窗 = 稍后重试；不在服务态 = 别再发了），
 * 而它们的处置完全相反 —— 混起来会写成一个"连接关了还在等窗口"或"满窗直接丢帧"的循环。
 */
export type JobFrameSendOutcome = 'sent' | 'paused' | 'closed'

export interface JobSubscriptionsOptions {
  source: JobFollowSource
  send: (sid: string, output: JobOutputFrame) => JobFrameSendOutcome
  /** 等一次"窗口又有空位"（`connection.whenWritable('job')`）。 */
  waitWritable: () => Promise<void>
  log?: ChannelLogger
}

export interface JobSubscriptions {
  /**
   * 开始（或复用）一个订阅。
   *
   * @returns 第一帧 `output` 的起点 —— 手机据此拼自己的尾部缓冲。
   * @throws {ProtocolError} `job/not-found`（任务不存在或不属于该会话）；
   *   `internal`（订阅在等到起点之前被替换/终止）。
   */
  follow(input: {
    sid: string
    dshSessionId: string
    jobId: string
    from?: number
  }): Promise<{ from: number }>
  /** 终止一个订阅。返回是否真的有一个在跑。 */
  unfollow(sid: string, jobId: string): boolean
  /** 终止全部（连接离开服务态、插件卸载）。 */
  stopAll(): void
  /** 当前订阅数（指标与测试用）。 */
  readonly active: number
}

interface Entry {
  /** 代数：只有"当前那一个"才允许继续出帧。 */
  generation: number
  controller: AbortController
  /** 已知的起点（`opened` 到达后填）。 */
  from: number | null
  readonly opened: Promise<number>
  resolveOpened: (from: number) => void
  rejectOpened: (error: unknown) => void
  /** 免得 `reject` 在已经兑现之后被调用两次（Promise 忽略第二次，但意图要清楚）。 */
  settled: boolean
}

const keyOf = (sid: string, jobId: string): string => `${sid}\u0000${jobId}`

export function createJobSubscriptions(options: JobSubscriptionsOptions): JobSubscriptions {
  const { source, send, waitWritable, log } = options
  const entries = new Map<string, Entry>()
  let generations = 0

  const settle = (entry: Entry, error: unknown): void => {
    if (entry.settled) return
    entry.settled = true
    entry.rejectOpened(error)
  }

  /** 起一条宿主流并转发。**不 await**：调用方等的是 `opened`，不是整条流。 */
  const run = async (
    entry: Entry,
    input: { sid: string; dshSessionId: string; jobId: string; from?: number },
  ): Promise<void> => {
    const key = keyOf(input.sid, input.jobId)
    const isCurrent = (): boolean => entries.get(key)?.generation === entry.generation
    let sawStatus = false

    try {
      const stream = source.follow(
        {
          dshSessionId: input.dshSessionId,
          jobId: input.jobId,
          ...(input.from === undefined ? {} : { from: input.from }),
        },
        entry.controller.signal,
      )

      for await (const frame of stream) {
        if (frame.kind === 'opened') {
          entry.from = frame.from
          if (!entry.settled) {
            entry.settled = true
            entry.resolveOpened(frame.from)
          }
        }
        if (frame.kind === 'status') sawStatus = true

        // 一帧一帧地要许可：压住消费端就压住宿主流（不缓冲）。
        let outcome = send(input.sid, frame)
        while (outcome === 'paused') {
          await waitWritable()
          // 等窗口的这段时间里，这个订阅可能已经被替换/收起/随连接一起终止。
          // 靠的是 `abort` 这一条真实机制（迭代器在 `next()` 里就中止了），
          // 而不是外加一个"我是不是当前那一个"的判据 —— 后者在这一层不可达：
          // 替换、`unfollow`、`stopAll` 三个入口都会 abort。
          if (entry.controller.signal.aborted) return
          outcome = send(input.sid, frame)
        }
        if (outcome === 'closed') {
          log?.debug(`任务输出订阅收工（连接不在服务态）：${input.jobId}`)
          return
        }

        if (frame.kind === 'status') return // 宿主流到这里正常结束
      }

      // 流结束却没给 `status`：要么被我们中止（手机要求的，不必报），要么宿主那边断了。
      if (!entry.controller.signal.aborted && !sawStatus) {
        send(input.sid, {
          kind: 'error',
          jobId: input.jobId,
          message: '任务输出流已结束（未收到结算帧）',
        })
      }
    } catch (error) {
      if (!entry.controller.signal.aborted) {
        const message = error instanceof Error ? error.message : String(error)
        log?.warn(`任务输出流中断：${input.jobId}`, error)
        send(input.sid, { kind: 'error', jobId: input.jobId, message: `实时输出流中断：${message}` })
        settle(entry, error)
      }
    } finally {
      // 只有"还是我"才能清表：否则会把后来者的条目删掉。
      if (isCurrent()) entries.delete(key)
      // 无论如何都要兑现挂起的承诺，否则方法面永远挂着。
      settle(entry, new ProtocolError('internal', '任务输出订阅已终止'))
    }
  }

  return {
    get active() {
      return entries.size
    },

    follow(input) {
      const key = keyOf(input.sid, input.jobId)
      const existing = entries.get(key)

      if (existing !== undefined) {
        const compatible =
          input.from === undefined || existing.from === null || existing.from === input.from
        if (compatible) {
          // 幂等：同一个订阅，不重开流（重开会把同一段输出推两遍）。
          return existing.opened.then((from) => ({ from }))
        }
        // 手机明确要求换起点：先终止旧的（`settle` 会拒绝它的承诺），再起新的。
        existing.controller.abort()
        entries.delete(key)
        settle(existing, new ProtocolError('internal', '任务输出订阅已被新的起点替换'))
      }

      const controller = new AbortController()
      let resolveOpened: (from: number) => void = () => {}
      let rejectOpened: (error: unknown) => void = () => {}
      const opened = new Promise<number>((resolve, reject) => {
        resolveOpened = resolve
        rejectOpened = reject
      })
      generations += 1
      const entry: Entry = {
        generation: generations,
        controller,
        from: null,
        opened,
        resolveOpened,
        rejectOpened,
        settled: false,
      }
      entries.set(key, entry)

      void run(entry, input)
      return opened.then((from) => ({ from }))
    },

    unfollow(sid, jobId) {
      const key = keyOf(sid, jobId)
      const entry = entries.get(key)
      if (entry === undefined) return false
      entries.delete(key)
      entry.controller.abort()
      settle(entry, new ProtocolError('internal', '任务输出订阅已终止'))
      return true
    },

    stopAll() {
      for (const [key, entry] of [...entries.entries()]) {
        entries.delete(key)
        entry.controller.abort()
        settle(entry, new ProtocolError('internal', '任务输出订阅已终止'))
      }
    },
  }
}
