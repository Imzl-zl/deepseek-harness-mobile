/**
 * 会话订阅（契约 §5.3、`session.subscribe` / `session.unsubscribe`）—— 骨架之上的一层。
 *
 * 骨架负责机制（背压、终止、承诺兑现）；本文件说会话面**特有**的四件事：
 *
 * ## 一、开启帧是"快照 + 水位"，它要展开成多条 `ev`
 *
 * 宿主的 `follow` 第一帧是 `snapshot`：`{ cursor, header, records, hasMore }`
 * （`packages/api/session-controller/src/types.ts:445-450` 一带；适配器 `dsh/sessions.ts` 的 `mapFrame` 忠实带着
 * `records` 与 `hasMore`）。`cursor` 是**包含式日志切点**，也就是手机恢复的基线水位；
 * `records` 是补课事件 —— 它们必须**逐条展开成 `ev` 帧**发出去，否则手机从旧水位恢复时会**丢事件**。
 * `hasMore` 说明还有更早的历史，手机据此决定要不要 `session.page`。
 *
 * ## 二、assistant 流要用电脑侧分配的数字 `stream`
 *
 * 契约术语表：`stream` 是「一次 assistant 尝试对应的实时输出流 id（**电脑侧分配**，会话内单调）」，
 * 而宿主的帧里带的是 `attemptId`（不透明字符串）。所以这里做一张 `attemptId → number` 的映射，
 * 并且**只增不减**：手机侧的判据是"`stream` 变大 ⇒ 换流"，复用旧号会让它把新尝试接到旧累加器上。
 *
 * ## 三、`rev` 用宿主的 `index`
 *
 * 手机上 `live` 的读法是 `rev == last + 1` 追加、跳跃即丢流（`docs/subsystems/app-channel-client.md` §2.2）。
 * 宿主的 `chunk` 帧自带 `index`（尝试内递增）—— 拿它当 `rev` 正好满足"+1"，
 * 不需要我们另造一个修订号（契约 §5.1：修订号是 DSH 的，插件不分配）。
 *
 * ## 四、中断**不补** `error` 帧（与任务输出不同）
 *
 * 任务输出的 ring 会淘汰（`gapBefore` 就是这么来的），沉默地断掉等于骗人，所以那边补一帧。
 * 会话内容一定还有**持久副本**：手机重连后按 `since` 重订一次就补回来了（§5.1 的恢复语义），
 * 所以这里不发明新帧 —— 让沉默保持沉默，靠重订自愈。
 *
 * 取舍与被否方案：`.agents/notes/implemented/2026-10-01-session-subscriptions.md`
 */
import { sessionAddress, type SessionFrame } from './dsh/sessions.js'
import type { SessionAddress } from '@deepseek-ai/dsh-api-session-controller/types'
import type { ChannelLogger } from './observability.js'
import { createSubscriptions, type SendOutcome, type Subscriptions } from './subscriptions.js'

/** 出站帧：`ev` 带会话序号，`live` 带流 id 与修订号（两者都是通道自己的编号体系）。 */
export type SessionOutbound =
  | { sid: string; t: 'ev'; seq: number; payload: unknown }
  | { sid: string; t: 'live'; stream: number; rev: number; payload: unknown }

/** 会话流：与 `SessionsPort.follow` 同形（收窄成这一层真正用到的方法）。 */
export interface SessionFollowSource {
  follow(
    request: { address: SessionAddress; assistantStream?: true },
    signal: AbortSignal,
  ): AsyncIterable<SessionFrame>
}

export interface SessionSubscriptionsOptions {
  source: SessionFollowSource
  send: (frame: SessionOutbound) => SendOutcome
  waitWritable: () => Promise<void>
  log?: ChannelLogger
}

export interface SessionSubscriptionReply {
  /** 基线水位（开启帧的 `cursor`）：手机据此重订与翻页。 */
  since: number
  /** 还有更早的历史（手机据此决定是否 `session.page`）。 */
  hasMore: boolean
}

export interface SessionSubscriptions {
  /**
   * 开始（或复用）一个会话订阅。
   *
   * @throws {ProtocolError} `session/not-found`（会话不存在）；
   *   `internal`（订阅在等到开启帧之前被替换/终止）。
   */
  subscribe(input: {
    sid: string
    dshSessionId: string
    /** 手机手里的水位；不给就从头开始（宿主会决定给增量还是快照）。 */
    since?: number
  }): Promise<SessionSubscriptionReply>
  /** 终止一个会话订阅。返回是否真的有一个在跑。 */
  unsubscribe(sid: string): boolean
  /** 终止全部（连接离开服务态、插件卸载）。 */
  stopAll(): void
  readonly active: number
}

/** 出站帧的展开结果：一条上游帧可以展开成多条（开启快照的补课事件）。 */
interface Expanded {
  out: readonly SessionOutbound[]
  anchor?: SessionSubscriptionReply
}

export function createSessionSubscriptions(
  options: SessionSubscriptionsOptions,
): SessionSubscriptions {
  /**
   * `attemptId → stream`。**全程单调**，且跨订阅保留：
   * 手机只看"号有没有变大"来判断换流，回收旧号会让它把新尝试接进旧累加器。
   */
  const streams = new Map<string, number>()
  let nextStream = 1

  const streamIdOf = (attemptId: string): number => {
    const existing = streams.get(attemptId)
    if (existing !== undefined) return existing
    const id = nextStream
    nextStream += 1
    streams.set(attemptId, id)
    return id
  }

  const core: Subscriptions<SessionFrame, SessionSubscriptionReply, SessionOutbound> =
    createSubscriptions({
      send: options.send,
      waitWritable: options.waitWritable,
      ...(options.log === undefined ? {} : { log: options.log }),
    })

  /** 把一条上游帧展开成若干出站帧（纯函数，便于单测）。 */
  function expand(sid: string, frame: SessionFrame): Expanded {
    switch (frame.kind) {
      case 'opening':
        return {
          anchor: { since: frame.cursor, hasMore: frame.hasMore },
          // 补课事件逐条发：少发一条，手机从旧水位恢复时就**丢一条事件**。
          out: frame.records.map((record) => ({
            sid,
            t: 'ev' as const,
            seq: record.event.seq,
            payload: record.event,
          })),
        }
      case 'event':
        return {
          out: [{ sid, t: 'ev', seq: frame.event.seq, payload: frame.event }],
        }
      case 'live': {
        const stream = streamIdOf(frame.frame.attemptId)
        switch (frame.frame.type) {
          case 'start':
            return {
              out: [
                {
                  sid,
                  t: 'live',
                  stream,
                  rev: 0,
                  payload: { type: 'start', turn: frame.frame.turn, step: frame.frame.step },
                },
              ],
            }
          case 'chunk':
            return {
              out: [
                {
                  sid,
                  t: 'live',
                  stream,
                  // `index` 是尝试内递增的块号：正好满足手机侧 `rev == last + 1` 的追加判据。
                  rev: frame.frame.index,
                  payload: { type: 'chunk', time: frame.frame.time, chunk: frame.frame.chunk },
                },
              ],
            }
          case 'end':
            return {
              out: [
                {
                  sid,
                  t: 'live',
                  stream,
                  rev: frame.frame.index,
                  payload: { type: 'end', outcome: frame.frame.outcome },
                },
              ],
            }
        }
      }
    }
  }

  return {
    get active() {
      return core.active
    },

    subscribe(input) {
      return core.start({
        key: input.sid,
        open: (signal) =>
          options.source.follow(
            { address: sessionAddress(input.dshSessionId), assistantStream: true },
            signal,
          ),
        outOf: (frame) => expand(input.sid, frame).out,
        anchorOf: (frame) => (frame.kind === 'opening' ? expand(input.sid, frame).anchor : undefined),
        // 会话流没有终止帧：它一直推到手机退订或连接断开。
        isTerminal: () => false,
        // 中断**不补** error 帧（会话内容有持久副本，重订即自愈）——见文件头第四条。
        // 幂等：`since` 没给或就是当前水位 → 复用；给了不同的 → 换流（手机明确要求从别处恢复）。
        reuse: (anchor) => input.since === undefined || input.since === anchor.since,
      })
    },

    unsubscribe(sid) {
      return core.stop(sid)
    },

    stopAll() {
      core.stopAll()
    },
  }
}
