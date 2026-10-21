/**
 * 会话历史翻页与单条目补取（契约 §5.3、§5.7 的 `session.page` / `session.refetch`）。
 *
 * 两件事为什么在同一个文件里：**它们是一对**。§5.3 规定"单个条目封箱后 > 1 MiB 就不推内容、
 * 推一个 `refetch` 标记，由手机按需拉取" —— 没有翻页就没有标记，没有补取标记就是死信。
 * 只做一半的表现很具体:手机翻到一条大消息（图片内联在 `assistant/message` 里，见
 * `packages/api/session-controller/src/types.ts:89-97`），要么收到一个点不动的标记，
 * 要么收到一帧超过硬上限的东西（发送侧**不得发出**，§3）。
 *
 * ## 三个数字，三个来源（都不许自己编）
 *
 * | 用到的量 | 来源 |
 * |---|---|
 * | `throughSeq`（包含式日志切点） | **开启帧的 `cursor`**，由订阅面缓存（`cursorOf`） |
 * | 单条目阈值 1 MiB | 契约 §5.3（生态中间值，§10 的同一张表） |
 * | 单帧硬上限 8 MiB | 契约 §3（收到即 `protocol/bad-frame` 并关闭连接） |
 *
 * 水位拿不到时**不能猜一个**：回 `session/window-missed`（§3.1 给它的客户端行为是
 * 「走快照刷新」）——手机据此重新订阅，拿到快照与新的水位，再翻页就正常了。
 */
import { resolveSessionAddress, type SessionsPort } from './dsh/sessions.js'
import type { SessionHistoryRecord } from '@deepseek-ai/dsh-api-session-controller/types'
import { ProtocolError } from './protocol/errors.js'
import type { ChannelLogger } from './observability.js'

/** 单条目超过它就换成 `refetch` 标记（契约 §5.3）。 */
export const DEFAULT_REFETCH_THRESHOLD_BYTES = 1024 * 1024
/** 单帧硬上限（契约 §3）：超过它**绝不发出**。 */
export const DEFAULT_MAX_FRAME_BYTES = 8 * 1024 * 1024

/** 翻页返回的一项：内容，或"这条太大，按需来取"的标记。 */
export type PageItem =
  | { kind: 'record'; record: SessionHistoryRecord }
  | { kind: 'refetch'; seq: number; bytes: number }

export interface SessionPagerOptions {
  sessions: SessionsPort
  /** 该会话的基线水位（来自订阅面的开启帧缓存）。拿不到就返回 `undefined`。 */
  cursorOf: (sid: string) => number | undefined
  refetchThresholdBytes?: number
  maxFrameBytes?: number
  log?: ChannelLogger
}

export interface SessionPager {
  /**
   * 往前翻一页历史。
   *
   * @throws {ProtocolError} `session/window-missed`：这个会话没有可用水位（从未订阅过 / 进程重启过）
   *   —— 手机据此走快照刷新；`session/not-found`：会话不存在。
   */
  page(input: {
    sid: string
    dshSessionId: string
    beforeSeq?: number
    maxMessages?: number
  }): Promise<{ items: readonly PageItem[]; hasMore: boolean; throughSeq: number }>
  /**
   * 取一条被 `refetch` 标记替代的大条目。
   *
   * @throws {ProtocolError} 取回来的条目仍然超过单帧硬上限（`internal`，留着声）；
   *   或水位拿不到（`session/window-missed`）。
   */
  refetch(input: {
    sid: string
    dshSessionId: string
    seq: number
  }): Promise<{ record: SessionHistoryRecord }>
}

const bytesOf = (record: SessionHistoryRecord): number =>
  Buffer.byteLength(JSON.stringify(record), 'utf8')

export function createSessionPager(options: SessionPagerOptions): SessionPager {
  const threshold = options.refetchThresholdBytes ?? DEFAULT_REFETCH_THRESHOLD_BYTES
  const maxFrame = options.maxFrameBytes ?? DEFAULT_MAX_FRAME_BYTES

  const requireCursor = (sid: string): number => {
    const cursor = options.cursorOf(sid)
    if (cursor === undefined) {
      // 水位只能来自开启帧（§5.3 的注释原文："Inclusive log cut obtained from the
      // corresponding follow opening frame"）。没有它就别猜一个 —— 猜出来的切点
      // 会让手机拿到"看起来对、其实少了一段"的历史。
      throw new ProtocolError('session/window-missed', `会话 ${sid} 没有可用水位：请先订阅（走快照刷新）`)
    }
    return cursor
  }

  return {
    async page(input) {
      const throughSeq = requireCursor(input.sid)
      const result = await options.sessions.page(
        {
          // 子会话要带父会话 id（否则宿主按 `session/agent-busy` 拒）。
          address: await resolveSessionAddress(options.sessions, input.dshSessionId),
          throughSeq,
          ...(input.beforeSeq === undefined ? {} : { beforeSeq: input.beforeSeq }),
          ...(input.maxMessages === undefined ? {} : { maxMessages: input.maxMessages }),
        },
        new AbortController().signal,
      )

      const items: PageItem[] = result.records.map((record) => {
        const bytes = bytesOf(record)
        if (bytes > threshold) {
          options.log?.debug(`条目超过 refetch 阈值（${bytes} B）：改推标记，seq=${record.event.seq}`)
          return { kind: 'refetch', seq: record.event.seq, bytes }
        }
        return { kind: 'record', record }
      })

      return { items, hasMore: result.hasMore, throughSeq }
    },

    async refetch(input) {
      const throughSeq = requireCursor(input.sid)
      // "按消息对齐"意味着一条消息可能跨多个 seq：取"到这条 seq 为止的一条消息"，
      // 也就是把 `beforeSeq` 放到它后面、只取一条。
      const result = await options.sessions.page(
        {
          address: await resolveSessionAddress(options.sessions, input.dshSessionId),
          throughSeq: Math.max(throughSeq, input.seq),
          beforeSeq: input.seq + 1,
          maxMessages: 1,
        },
        new AbortController().signal,
      )
      const record = result.records.at(-1)
      if (record === undefined) {
        throw new ProtocolError('session/not-found', `取不到条目 seq=${input.seq}`)
      }
      const bytes = bytesOf(record)
      if (bytes > maxFrame) {
        // 手机**明确要**这条，但它超过硬上限：发出去会被对端按 `protocol/bad-frame` 关连接。
        // 所以宁可回一个错误，也不制造一次必然的断连。
        throw new ProtocolError('internal', `条目 seq=${input.seq} 有 ${bytes} B，超过单帧上限`)
      }
      return { record }
    },
  }
}
