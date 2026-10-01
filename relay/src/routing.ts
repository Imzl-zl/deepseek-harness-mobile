/**
 * 中转的路由核心（契约 §2 拓扑、§5.5 重放窗口、**I10**）。
 *
 * 中转只做两件事：**转发**与**记账**。而"只读路由元数据"这条不变量（I10）决定了本文件的形状：
 * 它只认识 `RoutingView`（`{ t, sid, seq }`），**拿不到也存不下**载荷、方法名、事件类型 ——
 * 这是类型层面上的约束，不是纪律层面上的自律。
 *
 * ## 一、转发靠"谁发过这个 sid"
 *
 * 设备发来的帧要转给"服务这个会话的电脑侧连接"。而中转**不预先知道** sid 属于谁 ——
 * 它是从**电脑侧发来的帧**里学到的（谁发过某个 sid，那个 sid 就归谁）。
 * 这与不变量一致：学到的也只是路由元数据。
 *
 * 设备发来的帧若指向一个**没学到过的 sid**：本层**丢弃并计数**，不自己造一个错误帧 ——
 * 契约 §9 只授权中继合成 `presence`，没有授权它合成业务错误；自己造一个
 * 会让"电脑侧离线"与"这个会话不存在"在设备侧变成同一件事。
 *
 * ## 二、重放窗口按设备分，裁剪要**全部设备**确认
 *
 * 断线重连的设备要能按 `since` 补齐。窗口按 `(设备, sid)` 分（每台设备各自缺哪一段不一样），
 * 而裁剪要等**这台设备自己的** `persisted` 覆盖过 —— 桥接侧的增量缓冲同理（§5.5）。
 * 窗口有上限，超限时**先停推再要求快照**（丢弃最旧的一段，并记 `snapshotRequired`），
 * 而不是无限增长。
 */
import type { FrameType } from './protocol-view.ts'

/** 中转能看到的全部字段（I10）。`seq` 只有 `ev` / `persisted` 这类有序帧才有。 */
export interface RoutingView {
  t: FrameType
  sid: string
  seq: number
  /** 帧头里的**不透明关联标记**（配对帧靠它回程；I10 把它也列进可见字段）。 */
  id?: string
}

/** 一帧 + 它从哪来（中转自己的记账，不下发给对端）。 */
export interface RoutedFrame {
  view: RoutingView
  /** 原始线上行（**不透明**：中转只搬它，不解它）。 */
  raw: string
}

export interface RoutingOptions {
  /** 每 `(设备, sid)` 最多留多少帧。 */
  windowFrames?: number
  log?: (message: string, detail?: unknown) => void
}

export const DEFAULT_WINDOW_FRAMES = 1000

export interface Routing {
  /**
   * 电脑侧发来一帧：学到 sid 归属，转给订阅了它的设备，并记进各设备的窗口。
   *
   * @returns 该投递的设备 id（**调用方负责按"这些设备还在不在"过滤** —— 本层不认识连接）。
   */
  fromConnector(connectorId: string, frame: RoutedFrame): readonly string[]
  /**
   * 设备发来一帧。
   *
   * @returns 该交给哪条电脑侧连接（`undefined` = 丢弃：这个 sid 还没有归属）。
   */
  fromDevice(deviceId: string, frame: RoutedFrame): string | undefined
  /** 某设备确认落盘到 `seq`：裁掉它窗口里更旧的部分。返回裁掉几条。 */
  ack(deviceId: string, sid: string, seq: number): number
  /** 某设备重连后要补的那一段（`since` 之后仍在窗口里的）。覆盖不到返回 `undefined`（要求快照）。 */
  replayFor(deviceId: string, sid: string, since: number): readonly string[] | undefined
  /** 设备断开：它的窗口与订阅关系随之失效（重连是一次新的订阅）。 */
  forgetDevice(deviceId: string): void
  /** 观测：会话归属表与窗口规模。 */
  readonly stats: { sessions: number; windows: number; frames: number }
}

const keyOf = (deviceId: string, sid: string): string => `${deviceId}\u0000${sid}`

export function createRouting(options: RoutingOptions = {}): Routing {
  const windowFrames = options.windowFrames ?? DEFAULT_WINDOW_FRAMES
  const log = options.log

  /** `sid → connectorId`：**只从电脑侧发来的帧里学**（设备侧说了不算）。 */
  const owner = new Map<string, string>()
  /** 哪些设备订阅了哪个 sid（电脑侧推过 = 认为它在听）。 */
  const watchers = new Map<string, Set<string>>()
  /** `(deviceId, sid) → 已发出的有序帧（原始行）`。 */
  const windows = new Map<string, { seq: number; raw: string }[]>()
  /** `(deviceId, sid) → 该设备已确认到的 seq`。 */
  const acks = new Map<string, number>()

  return {
    get stats() {
      let frames = 0
      for (const window of windows.values()) frames += window.length
      return { sessions: owner.size, windows: windows.size, frames }
    },

    fromConnector(connectorId, frame) {
      const { sid } = frame.view
      owner.set(sid, connectorId)
      const listeners = watchers.get(sid)
      if (listeners === undefined) {
        // 没有设备在听：**仍然记归属**（设备稍后连上来要按 since 补），但不记窗口 ——
        // 没人缺这一段，记了只是白占内存。
        return []
      }
      // 有序帧才进窗口（`ev` / `persisted`）：无序帧没有"补齐"的语义。
      const ordered = frame.view.t === 'ev' || frame.view.t === 'persisted'
      for (const deviceId of listeners) {
        if (!ordered) continue
        const key = keyOf(deviceId, sid)
        const window = windows.get(key) ?? []
        window.push({ seq: frame.view.seq, raw: frame.raw })
        if (window.length > windowFrames) {
          // 超限：丢最旧的（缓冲区必须封顶），设备侧会因此看出缺口 —— 那正是要它走快照的信号。
          const dropped = window.splice(0, window.length - windowFrames).length
          log?.(`重放窗口超限：${key} 丢掉 ${dropped} 条最旧的（设备将需要快照）`, { sid })
        }
        windows.set(key, window)
      }
      // 把"该投给谁"交给调用方：本层不认识连接，只知道谁在听。
      return [...listeners]
    },

    fromDevice(deviceId, frame) {
      const { sid } = frame.view
      // **先登记"它在听"**，再看能不能转发。设备为某个 sid 说话本身就说明它关心这个会话，
      // 而归属可能只是还没学到（电脑侧还没推过东西）—— 这时不登记，就会漏掉随后的帧，
      // 症状是"重连上来先说话的那台设备收不到事件"。
      //
      // 这不会让设备偷看别人的内容：帧是按**每台设备的密钥**端到端加密的，
      // 中转只是搬密文；登记错 sid 的设备拿到也解不开（它没有那把钥匙）。
      const listeners = watchers.get(sid) ?? new Set<string>()
      listeners.add(deviceId)
      watchers.set(sid, listeners)

      const connectorId = owner.get(sid)
      if (connectorId === undefined) {
        log?.(`丢弃设备侧帧：这个 sid 还没有归属（${sid}）`, { deviceId, t: frame.view.t })
        return undefined
      }
      return connectorId
    },

    ack(deviceId, sid, seq) {
      const key = keyOf(deviceId, sid)
      const previous = acks.get(key) ?? 0
      if (seq > previous) acks.set(key, seq)
      const window = windows.get(key)
      if (window === undefined) return 0
      const point = acks.get(key) ?? 0
      // 窗口按 seq 升序（有序帧才进窗口），所以从头部裁到 point 为止。
      let removed = 0
      while (window.length > 0 && (window[0]?.seq ?? Number.POSITIVE_INFINITY) <= point) {
        window.shift()
        removed += 1
      }
      return removed
    },

    replayFor(deviceId, sid, since) {
      const window = windows.get(keyOf(deviceId, sid))
      if (window === undefined) return undefined
      const first = window[0]
      if (first === undefined) {
        // 空窗口：只有"裁到的位置正好接着 since"才算覆盖。
        return (acks.get(keyOf(deviceId, sid)) ?? 0) === since ? [] : undefined
      }
      // 连续性：头部必须正好接在 since 后面，否则中间有洞 —— 要求快照。
      if (first.seq > since + 1) return undefined
      const tail = window.filter((entry) => entry.seq > since)
      // 尾部也要连续（中间有洞就给快照，别给残缺增量）。
      for (let index = 1; index < tail.length; index += 1) {
        if ((tail[index]?.seq ?? 0) !== (tail[index - 1]?.seq ?? 0) + 1) return undefined
      }
      return tail.map((entry) => entry.raw)
    },

    forgetDevice(deviceId) {
      const suffix = `\u0000`
      for (const key of [...windows.keys()]) {
        if (key.startsWith(`${deviceId}${suffix}`)) windows.delete(key)
      }
      for (const key of [...acks.keys()]) {
        if (key.startsWith(`${deviceId}${suffix}`)) acks.delete(key)
      }
      for (const [sid, listeners] of watchers) {
        listeners.delete(deviceId)
        if (listeners.size === 0) watchers.delete(sid)
      }
    },
  }
}
