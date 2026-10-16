/**
 * 任务输出订阅（契约 §5.3）—— 骨架之上的一层。
 *
 * 机制（背压、终止、承诺兑现、收尾只清自己那一格）全在 `subscriptions.ts`；
 * 本文件只说任务输出**特有**的四件事：
 *
 * 1. **每个 `(sid, jobId)` 至多一条宿主流**：输出帧没有去重键（它的"修订号"是字节偏移，
 *    同一段输出推两遍时两帧看起来一模一样），所以重复订阅必须复用，而不是各推一遍。
 * 2. **换起点就换流**：手机明确给了不同的 `from`，先终止旧的再起新的。
 * 3. **终止帧是 `status`**（宿主在结算并 drain 完之后给）。
 * 4. **没有终止帧就补一帧 `error`**：任务输出的 ring 会淘汰（`gapBefore` 就是这么来的），
 *    沉默地结束会让手机以为任务还在跑 —— 这里必须让对端知道断了。
 *
 * 取舍与被否方案：`.agents/notes/implemented/2026-10-01-job-output-subscription.md`
 */
import type { JobOutputFrame } from './protocol/job-output.js'
import type { ChannelLogger } from './observability.js'
import { createSubscriptions, type SendOutcome, type Subscriptions } from './subscriptions.js'

/** 宿主流：与 `JobControlPort.follow` 同形（收窄成这一层真正用到的方法）。 */
export interface JobFollowSource {
  follow(
    request: { dshSessionId: string; jobId: string; from?: number },
    signal: AbortSignal,
  ): AsyncIterable<JobOutputFrame>
}

/** 出站帧：载荷 + 它属于哪个会话（连接层要 `sid` 当帧头）。 */
export interface JobOutbound {
  sid: string
  output: JobOutputFrame
}

export interface JobSubscriptionsOptions {
  source: JobFollowSource
  send: (sid: string, output: JobOutputFrame) => SendOutcome
  /** 等一次"窗口又有空位"（`connection.whenWritable('job')`）。 */
  waitWritable: () => Promise<void>
  log?: ChannelLogger
}

export interface JobSubscriptions {
  /**
   * 开始（或复用）一个订阅，等宿主的 `opened` 帧。
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

const keyOf = (sid: string, jobId: string): string => `${sid}\u0000${jobId}`

export function createJobSubscriptions(
  options: JobSubscriptionsOptions,
): JobSubscriptions {
  const core: Subscriptions<JobOutputFrame, number, JobOutbound> = createSubscriptions({
    send: (out) => options.send(out.sid, out.output),
    waitWritable: options.waitWritable,
    ...(options.log === undefined ? {} : { log: options.log }),
  })

  return {
    get active() {
      return core.active
    },

    follow(input) {
      return core
        .start({
          key: keyOf(input.sid, input.jobId),
          open: (signal) =>
            options.source.follow(
              {
                dshSessionId: input.dshSessionId,
                jobId: input.jobId,
                ...(input.from === undefined ? {} : { from: input.from }),
              },
              signal,
            ),
          outOf: (frame) => [{ sid: input.sid, output: frame }],
          // **给行盖上 sid**：`job` 帧本身不带会话，手机只能猜"这个任务归哪个桶"，
          // 而猜错的后果是"正在看的会话不显示后台任务 chip、别的会话凭空多一个"
          // （2026-10-15 真机：先开 A 再开 B，B 里新起的任务被归到 A）。
          // 订阅本来就按 (sid, jobId) 建，所以这里盖的 sid 不可能错。
          transform: (frame) =>
            frame.kind === 'opened' || frame.kind === 'status'
              ? { ...frame, job: { ...frame.job, sid: input.sid } }
              : frame,
          anchorOf: (frame) => (frame.kind === 'opened' ? frame.from : undefined),
          isTerminal: (frame) => frame.kind === 'status',
          onEndWithoutTerminal: () => ({
            sid: input.sid,
            output: { kind: 'error', jobId: input.jobId, message: '任务输出流已结束（未收到结算帧）' },
          }),
          onError: (error) => ({
            sid: input.sid,
            output: {
              kind: 'error',
              jobId: input.jobId,
              message: `实时输出流中断：${error instanceof Error ? error.message : String(error)}`,
            },
          }),
          // 幂等：`from` 没给或与当前起点一致 → 复用；给了不同的 → 换流。
          reuse: (anchor) => input.from === undefined || input.from === anchor,
        })
        .then((from) => ({ from }))
    },

    unfollow(sid, jobId) {
      return core.stop(keyOf(sid, jobId))
    },

    stopAll() {
      core.stopAll()
    },
  }
}
