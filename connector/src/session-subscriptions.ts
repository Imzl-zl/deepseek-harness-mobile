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
import { resolveSessionAddress, type SessionFrame } from './dsh/sessions.js'
import type { SessionAddress } from '@deepseek-ai/dsh-api-session-controller/types'
import type { ChannelLogger } from './observability.js'
import type { SessionBuffer } from './session-buffer.js'
import { createSubscriptions, type SendOutcome, type Subscriptions } from './subscriptions.js'

/**
 * 出站帧：`ev` 带会话序号，`live` 带流 id 与修订号（两者都是通道自己的编号体系）。
 *
 * `body` 是**已经序列化好的载荷**，出帧与增量缓冲共用同一个串：
 * 各序列化一次的话，每个事件都要多走一遍 `JSON.stringify`（而事件是高频的）。
 */
export type SessionOutbound =
  | { sid: string; t: 'ev'; seq: number; body: string }
  | { sid: string; t: 'live'; stream: number; rev: number; body: string }

/** 会话流：与 `SessionsPort.follow` 同形（收窄成这一层真正用到的方法）。 */
export interface SessionFollowSource {
  follow(
    request: { address: SessionAddress; assistantStream?: true },
    signal: AbortSignal,
  ): AsyncIterable<SessionFrame>
}

export interface SessionSubscriptionsOptions {
  source: SessionFollowSource
  /**
   * 一个 DSH 会话的地址。
   *
   * **子会话必须带父会话 id**（宿主对 `kind:'session'` 的子会话直接拒：
   * `session-controller/src/history.ts:347-352`）。判据在清单行里，
   * 所以这一层不自己算 —— 生产装配传 `resolveSessionAddress(port, id)`
   * （`dsh/sessions.ts`），替身按需给一个普通地址。
   */
  addressOf: (dshSessionId: string) => Promise<SessionAddress>
  send: (frame: SessionOutbound) => SendOutcome
  waitWritable: () => Promise<void>
  /**
   * 增量缓冲（契约 §5.5）。给了它，重订就能走**增量**而不是每次灌一份快照。
   *
   * 每条出站的 `ev` 都会记进去（**发之前**记：宁可重发，不可丢），
   * 而裁剪只发生在全部配对设备 `persisted` 覆盖过之后（那是缓冲自己的规矩）。
   */
  buffer?: SessionBuffer
  /**
   * 订阅集**变化之后**调用（带当前全部 `sid`）。
   *
   * 它是 presence 的输入（契约 §6.2：`foreground` 档的 claim 判据是"前台且已订阅该 sid"）。
   * 挂在这是而不是读取点轮询：订阅集只有三个变更点（`subscribe` / `unsubscribe` / `stopAll`），
   * 三处各通报一次比让读取方猜"什么时候变了"可靠。
   */
  onChange?: (sids: readonly string[]) => void
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
  /**
   * 该会话**最后一次**开启帧给出的基线水位（契约 §5.3：`session.page` 的 `throughSeq` 必须来自它）。
   *
   * **退订之后仍然记着**：手机收起会话面板、或断线重连之前想翻历史时，
   * 手里没有活跃订阅但水位还是知道的 —— 用一个稍旧的切点翻更早的历史是安全的
   * （它只会少算新事件，不会算错旧事件）。进程重启后自然为空，那时回 `undefined`。
   */
  cursorOf(sid: string): number | undefined
  /** 当前订阅的会话集（presence 的输入，契约 §6.2 的"已订阅该 sid"判据）。 */
  sids(): readonly string[]
  /** 终止全部（连接离开服务态、插件卸载）。 */
  stopAll(): void
  readonly active: number
}

/** 出站帧的展开结果：一条上游帧可以展开成多条（开启快照的补课事件）。 */
interface Expanded {
  out: readonly SessionOutbound[]
  anchor?: SessionSubscriptionReply
}

/**
 * 内部流的一帧：上游帧，或**缓冲里补发的那一段**。
 *
 * 补发帧只有序列化好的 `body`（缓冲就是这么存的，省一次解析）——
 * 于是"重订走增量"不需要把 JSON 再解析回对象。
 */
type SessionStreamFrame = SessionFrame | { kind: 'buffered'; seq: number; body: string }

export function createSessionSubscriptions(
  options: SessionSubscriptionsOptions,
): SessionSubscriptions {
  /**
   * `attemptId → stream`。**全程单调**，且跨订阅保留：
   * 手机只看"号有没有变大"来判断换流，回收旧号会让它把新尝试接进旧累加器。
   */
  const streams = new Map<string, number>()
  let nextStream = 1
  const buffer = options.buffer
  /** `sid → 最后一次开启帧的水位`（`session.page` 的 `throughSeq` 来源）。 */
  const cursors = new Map<string, number>()

  /** 订阅集变了就通报（presence 的唯一输入）。 */
  const announce = (): void => {
    options.onChange?.(core.keys())
  }

  const streamIdOf = (attemptId: string): number => {
    const existing = streams.get(attemptId)
    if (existing !== undefined) return existing
    const id = nextStream
    nextStream += 1
    streams.set(attemptId, id)
    return id
  }

  const core: Subscriptions<SessionStreamFrame, SessionSubscriptionReply, SessionOutbound> =
    createSubscriptions({
      send: (out) => {
        // **发之前**记进缓冲：崩在"发了没记"之间会少一段，而崩在"记了没发"之间
        // 只是重订时多补发一条（手机按 seq 幂等）—— 两害相权取前者。
        if (out.t === 'ev') buffer?.record(out.sid, { seq: out.seq, body: out.body })
        return options.send(out)
      },
      waitWritable: options.waitWritable,
      ...(options.log === undefined ? {} : { log: options.log }),
    })

  /** 把一条上游帧展开成若干出站帧（纯函数，便于单测）。 */
  function expand(sid: string, frame: SessionStreamFrame): Expanded {
    if (frame.kind === 'buffered') {
      // 缓冲里补发的一段：`body` 已经是最终载荷，直接用。
      return { out: [{ sid, t: 'ev', seq: frame.seq, body: frame.body }] }
    }
    switch (frame.kind) {
      case 'opening':
        return {
          anchor: { since: frame.cursor, hasMore: frame.hasMore },
          // 补课事件逐条发：少发一条，手机从旧水位恢复时就**丢一条事件**。
          out: frame.records.map((record) => ({
            sid,
            t: 'ev' as const,
            seq: record.event.seq,
            body: JSON.stringify(record.event),
          })),
        }
      case 'event':
        return {
          out: [{ sid, t: 'ev', seq: frame.event.seq, body: JSON.stringify(frame.event) }],
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
                  body: JSON.stringify({ type: 'start', turn: frame.frame.turn, step: frame.frame.step }),
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
                  body: JSON.stringify({ type: 'chunk', time: frame.frame.time, chunk: frame.frame.chunk }),
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
                  body: JSON.stringify({ type: 'end', outcome: frame.frame.outcome }),
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
      const ready = core.start({
        key: input.sid,
        open: async function* (signal) {
          // **地址按清单行决定**：子会话必须带父会话 id，否则宿主直接拒
          // （`session-controller/src/history.ts:347-352`）—— 真机表现就是
          // "进子会话一片空白"，而单测里替身从不拒绝，所以一直是绿的。
          const address = await options.addressOf(input.dshSessionId)
          // **增量优先**：缓冲里覆盖得到 `since` 时，先补发那一段，
          // 不必让手机重新吃一份完整快照（快照只在覆盖不到时才出现）。
          let lastSeq = input.since ?? 0
          const replay = input.since === undefined ? undefined : buffer?.tailFrom(input.sid, input.since)
          if (replay !== undefined) {
            for (const event of replay) {
              lastSeq = event.seq
              yield { kind: 'buffered', seq: event.seq, body: event.body }
            }
          }

          for await (const frame of options.source.follow(
            { address, assistantStream: true },
            signal,
          )) {
            // 快照里的补课事件可能与刚补发的那段重叠（宿主不知道我们手里有什么）：
            // 按 seq 去重，**同一个 seq 绝不发两遍**。
            if (frame.kind === 'opening') {
              const records = frame.records.filter((record) => record.event.seq > lastSeq)
              const highest = records.at(-1)
              if (highest !== undefined) lastSeq = highest.event.seq
              yield { ...frame, records }
              continue
            }
            if (frame.kind === 'event') {
              if (frame.event.seq <= lastSeq) continue
              lastSeq = frame.event.seq
            }
            yield frame
          }
        },
        outOf: (frame) => expand(input.sid, frame).out,
        anchorOf: (frame) => {
          const expanded = expand(input.sid, frame)
          // 顺手记住水位：`session.page` 要用它当 `throughSeq`（退订后也留着）。
          if (expanded.anchor !== undefined) cursors.set(input.sid, expanded.anchor.since)
          return expanded.anchor
        },
        // 会话流没有终止帧：它一直推到手机退订或连接断开。
        isTerminal: () => false,
        // 中断**不补** error 帧（会话内容有持久副本，重订即自愈）——见文件头第四条。
        // 幂等：`since` 没给或就是当前水位 → 复用；给了不同的 → 换流（手机明确要求从别处恢复）。
        reuse: (anchor) => input.since === undefined || input.since === anchor.since,
      })
      // **订阅集变了就通报**。放在 `core.start` 之后而不是开启帧到达之后：
      // 判据是"手机声明了要订这个会话"，而"开启帧什么时候到"是上游的节奏。
      // 反过来的话，一段"已声明但还没 anchor"的窗口里 foreground 档会判它没订阅。
      announce()
      return ready
    },

    unsubscribe(sid) {
      const stopped = core.stop(sid)
      announce()
      return stopped
    },

    cursorOf(sid) {
      return cursors.get(sid)
    },

    /** 当前订阅的会话集（presence 与测试用）。 */
    sids() {
      return core.keys()
    },

    stopAll() {
      core.stopAll()
      announce()
    },
  }
}
