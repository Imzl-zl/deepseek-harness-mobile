/**
 * 订阅骨架（任务输出与会话订阅共用）。
 *
 * 两条订阅流（`job.follow` 的宿主流、`session.subscribe` 的会话流）在**机制上完全一样**，
 * 而机制里最难的几处都属于"写错不会报错、只在真机上偶发"那一类，所以只能有一份实现：
 *
 * 1. **逐帧背压**：满窗时压住**同一帧**、等窗口、再发；一次只压一帧，
 *    于是"取一帧 → 发出去 → 再取下一帧"的拉式循环天然把背压传回上游，不需要缓冲队列。
 * 2. **终止只有 `abort` 一条机制**：替换、`stop`、`stopAll`、连接离开服务态四个入口都走它。
 *    转发循环靠"迭代器在 `next()` 里就中止"收工 —— 不额外加"我还是不是当前那一个"的判据
 *    （那一版被变异校验证明不可达，见 `.agents/notes/implemented/2026-10-01-job-output-subscription.md`）。
 * 3. **挂起的承诺必被兑现**：调用方在等开启帧（起点/水位）时若订阅被终止，
 *    那个承诺**被拒绝**而不是永远挂着 —— 否则一个 `req` 永远等不到 `res`。
 * 4. **收尾只清自己那一格**：`finally` 里必须确认"entries 里还是我"，
 *    否则旧循环会把新订阅的条目删掉（订阅静悄悄地没了）。
 *
 * 各流自己的语义（键怎么取、开启帧怎么展开成出站帧、什么算终止、重复订阅算不算幂等）
 * 由调用方通过 `SubscriptionSpec` 提供 —— 骨架不认识 `job` 也不认识 `sid`。
 */
import { ProtocolError } from './protocol/errors.js'
import type { ChannelLogger } from './observability.js'

/**
 * 出一帧的结果。
 *
 * 三态而不是布尔：`false` 有两种意思（满窗 = 稍后重试；不在服务态 = 别再发了），
 * 而它们的处置完全相反 —— 混起来会写成一个"连接关了还在等窗口"或"满窗直接丢帧"的循环。
 */
export type SendOutcome = 'sent' | 'paused' | 'closed'

export interface SubscriptionSpec<Frame, Anchor, Out> {
  /** 通道层面的唯一键（骨架用它去重与替换）。 */
  key: string
  /** 开一条流；**调用方持有 `signal` 的生命周期**（中止即终止上游）。 */
  open(signal: AbortSignal): AsyncIterable<Frame>
  /**
   * 一帧上游数据 → 若干出站帧。
   *
   * 之所以是"若干"：会话订阅的开启快照会带一串补课事件，一条上游帧要展开成多条 `ev`。
   * 任务输出是一对一。
   */
  outOf(frame: Frame): readonly Out[]
  /** 从开启帧里取"起点"（它会成为这次调用的应答）。取不到就返回 `undefined`。 */
  anchorOf(frame: Frame): Anchor | undefined
  /** 这一帧是不是终止帧（到了就正常收口，不再等上游关闭）。 */
  isTerminal(frame: Frame): boolean
  /**
   * 上游结束却没有终止帧时要补发的那一帧。
   *
   * 有就是"必须让对端知道它断了"（任务输出的 ring 会淘汰，沉默等于骗人）；
   * 没有就是"沉默即可自愈"（会话内容一定还有持久副本，重订一次就补回来了）。
   */
  onEndWithoutTerminal?(): Out | undefined
  /**
   * 上游**抛错**时要补发的那一帧。
   *
   * 与 `onEndWithoutTerminal` 分开是因为对端要显示的东西不一样：
   * "流断了（带原因）"与"流有序结束但没给终止帧"是两种处境。缺席时退回
   * `onEndWithoutTerminal`。
   */
  onError?(error: unknown): Out | undefined
  /**
   * 已有订阅时的复用判据：返回 `true` 表示这次调用**复用**现有订阅（幂等），
   * 返回 `false` 表示先终止旧的再起新的。
   */
  reuse?(anchor: Anchor): boolean
}

export interface SubscriptionsOptions<Out> {
  send(frame: Out): SendOutcome
  /** 等一次"窗口又有空位"（`connection.whenWritable(...)`）。 */
  waitWritable: () => Promise<void>
  log?: ChannelLogger
}

export interface Subscriptions<Frame, Anchor, Out> {
  /**
   * 开始（或复用）一个订阅，等它的开启帧。
   *
   * @throws {ProtocolError} `internal`：订阅在等到起点之前被替换/终止。
   */
  start(spec: SubscriptionSpec<Frame, Anchor, Out>): Promise<Anchor>
  /** 终止一个订阅。返回是否真的有一个在跑。 */
  stop(key: string): boolean
  /** 终止全部（连接离开服务态、插件卸载）。 */
  stopAll(): void
  /** 当前订阅数（指标与测试用）。 */
  readonly active: number
}

interface Entry<Anchor> {
  controller: AbortController
  anchor: Anchor | null
  readonly ready: Promise<Anchor>
  resolveReady: (anchor: Anchor) => void
  rejectReady: (error: unknown) => void
  settled: boolean
}

/** 兜底：调用方不给 `reuse` 时，重复订阅视为**复用**（幂等），这是更安全的默认。 */
const alwaysReuse = (): boolean => true

export function createSubscriptions<Frame, Anchor, Out>(
  options: SubscriptionsOptions<Out>,
): Subscriptions<Frame, Anchor, Out> {
  const { send, waitWritable, log } = options
  const entries = new Map<string, Entry<Anchor>>()

  const settle = (entry: Entry<Anchor>, error: unknown): void => {
    if (entry.settled) return
    entry.settled = true
    entry.rejectReady(error)
  }

  /** 起一条上游流并转发。**不 await**：调用方等的是开启帧，不是整条流。 */
  const run = async (entry: Entry<Anchor>, spec: SubscriptionSpec<Frame, Anchor, Out>): Promise<void> => {
    const isCurrent = (): boolean => entries.get(spec.key) === entry
    let sawTerminal = false

    try {
      for await (const frame of spec.open(entry.controller.signal)) {
        const anchor = spec.anchorOf(frame)
        if (anchor !== undefined && !entry.settled) {
          entry.anchor = anchor
          entry.settled = true
          entry.resolveReady(anchor)
        }
        if (spec.isTerminal(frame)) sawTerminal = true

        for (const out of spec.outOf(frame)) {
          // 一帧一帧地要许可：压住消费端就压住上游（不缓冲）。
          let outcome = send(out)
          while (outcome === 'paused') {
            await waitWritable()
            if (entry.controller.signal.aborted) return
            outcome = send(out)
          }
          if (outcome === 'closed') {
            log?.debug(`订阅收工（连接不在服务态）：${spec.key}`)
            return
          }
        }

        if (sawTerminal) return // 终止帧已发，上游不必再等
      }

      if (!entry.controller.signal.aborted && !sawTerminal) {
        const tail = spec.onEndWithoutTerminal?.()
        if (tail !== undefined) send(tail)
      }
    } catch (error) {
      if (!entry.controller.signal.aborted) {
        log?.warn(`订阅流中断：${spec.key}`, error)
        // 抛错与"有序结束但没终止帧"是两种处境，对端显示的话不一样。
        const tail = spec.onError?.(error) ?? spec.onEndWithoutTerminal?.()
        if (tail !== undefined) send(tail)
        settle(entry, error)
      }
    } finally {
      // 只有"还是我"才能清表：否则会把后来者的条目删掉。
      if (isCurrent()) entries.delete(spec.key)
      // 无论如何都要兑现挂起的承诺，否则调用方永远挂着。
      settle(entry, new ProtocolError('internal', '订阅已终止'))
    }
  }

  return {
    get active() {
      return entries.size
    },

    start(spec) {
      const existing = entries.get(spec.key)
      if (existing !== undefined) {
        const reuse = spec.reuse ?? alwaysReuse
        if (existing.anchor !== null && reuse(existing.anchor)) {
          // 幂等：同一个订阅，不重开流（重开会把同一段内容推两遍）。
          return Promise.resolve(existing.anchor)
        }
        if (existing.anchor === null) {
          // 还没等到开启帧：这次调用与在飞的那次等价，等它就好。
          return existing.ready
        }
        // 明确要求换起点：先终止旧的（`settle` 会拒绝它的承诺），再起新的。
        existing.controller.abort()
        entries.delete(spec.key)
        settle(existing, new ProtocolError('internal', '订阅已被新的起点替换'))
      }

      const controller = new AbortController()
      let resolveReady: (anchor: Anchor) => void = () => {}
      let rejectReady: (error: unknown) => void = () => {}
      const ready = new Promise<Anchor>((resolve, reject) => {
        resolveReady = resolve
        rejectReady = reject
      })
      const entry: Entry<Anchor> = {
        controller,
        anchor: null,
        ready,
        resolveReady,
        rejectReady,
        settled: false,
      }
      entries.set(spec.key, entry)

      void run(entry, spec)
      return ready
    },

    stop(key) {
      const entry = entries.get(key)
      if (entry === undefined) return false
      entries.delete(key)
      entry.controller.abort()
      settle(entry, new ProtocolError('internal', '订阅已终止'))
      return true
    },

    stopAll() {
      for (const [key, entry] of [...entries.entries()]) {
        entries.delete(key)
        entry.controller.abort()
        settle(entry, new ProtocolError('internal', '订阅已终止'))
      }
    },
  }
}
