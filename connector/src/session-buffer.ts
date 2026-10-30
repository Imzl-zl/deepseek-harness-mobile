/**
 * 会话增量缓冲（契约 §5.5）。
 *
 * 手机断线重连后要"从上次的水位接着收"，而不是每次都被灌一份完整快照。为此电脑侧给
 * **每个被订阅的会话**留一段增量缓冲，并把裁剪权交给手机：
 *
 * - **只有这一轮真正在服务的设备都 `persisted` 覆盖过的区间**才允许裁掉头部（§5.5）。
 *   未确认的部分**永不裁剪** —— 宁可内存吃紧（先停推、再要求快照），也不丢事件。
 *   "在服务" = 此刻在线 ∪ 本轮确认过（有 ack）且未吊销。**从没连过的已配对设备不参与**：
 *   否则"配 3 台只连 1 台"是常态，缓冲永远裁不动，切回就是一次全量快照。
 * - 上限 **16 MiB 或 10000 条**（取先到者，§5.5 与 §10 的同一组数）。
 * - 一个设备都没确认过时，一行都不裁：这是"未被确认"的最小例子，
 *   而它恰好是最常见的初始状态（刚连上、还没写盘）。
 *
 * 裁剪的判据是**逐设备的落盘水位**，不是"发出去多久了" —— 发出去不等于对方写下去了。
 *
 * Note: 为什么裁剪点是"在服务的设备"而不是"全部配对设备" —— 见
 * `.agents/notes/implemented/2026-10-30-dial-racing-and-buffer-trim.md`。
 *
 * ## 为什么要按 `devId` 分开记
 *
 * 契约说的是"**全部配对设备**都确认"。两台手机时，快的那台确认到 500 并不代表慢的那台
 * 也收到了 —— 按单一水位裁剪会把慢的那台丢掉 200..500 这段。所以水位是 `devId → seq`，
 * 裁剪点是它们的最小值。
 */
import type { ChannelLogger } from './observability.js'

/** 缓冲里的一条：`seq` 是 DSH 的会话序号，`body` 就是将要封箱的那段 JSON 文本。 */
export interface BufferedEvent {
  seq: number
  /** 已序列化的载荷（与出帧时同一个串，避免二次序列化）。 */
  body: string
}

export interface SessionBufferOptions {
  /** 条数上限（契约 §5.5 / §10：10000）。 */
  maxFrames?: number
  /** 字节上限（契约 §5.5 / §10：16 MiB）。 */
  maxBytes?: number
  /** **配对且未吊销**的设备（用来判"这个 ack 是否还有效"；撤销后不再占坑）。 */
  pairedDevices: () => readonly string[]
  /**
   * 此刻**在线**的设备（正在收事件，可能还没写盘 ⇒ 按水位 0 保护）。
   *
   * 不给 = 没有在线信息（单测的默认）：此时只按"本轮确认过且未吊销"的设备裁。
   */
  onlineDevices?: () => readonly string[]
  log?: ChannelLogger
}

/** 契约 §5.5 / §10 的同一组上限。 */
export const BUFFER_MAX_FRAMES = 10_000
export const BUFFER_MAX_BYTES = 16 * 1024 * 1024

export interface SessionBufferStats {
  sessions: number
  frames: number
  bytes: number
}

export interface SessionBuffer {
  /**
   * 记一条**已经发给设备**的 `ev`。
   *
   * 只接受严格递增的 `seq`（同一个 seq 记两次会让重订时重放两条）：非递增时**不记**并留声。
   */
  record(sid: string, event: BufferedEvent): void
  /**
   * 某设备确认已落盘到 `seq`（入站 `persisted`）。返回这次裁掉了几条。
   *
   * 裁剪点 = 全部配对设备水位的最小值；有设备还没确认过就是 0（一行都不裁）。
   */
  ack(sid: string, devId: string, seq: number): number
  /**
   * 取 `since` 之后、仍在缓冲里的增量。
   *
   * 覆盖不到就返回 `undefined`：**那是"要求快照"的信号**，不是"没有新事件"
   * （两者混起来的表现是"手机永远停在旧内容上"，最难查）。覆盖不到有两种：
   * 缓冲已裁过 `since`（头部 seq 已经大于 `since + 1`），或这段内容超限被放弃过。
   */
  tailFrom(sid: string, since: number): readonly BufferedEvent[] | undefined
  /** 会话不再被订阅（`session.unsubscribe` / 订阅流结束）时释放它的缓冲与水印。 */
  forget(sid: string): void
  readonly stats: SessionBufferStats
}

interface Entry {
  events: BufferedEvent[]
  /** 头部被裁到哪（最后一条被裁掉的 seq）；没裁过是 0。 */
  trimmedTo: number
  bytes: number
  /** 逐设备的落盘水位（`devId → seq`）。没确认过的设备不在表里，等价于 0。 */
  acks: Map<string, number>
  /** 超限且裁不动（未确认）时置位：此后只允许快照，不再假装能增量。 */
  overflowed: boolean
}

export function createSessionBuffer(options: SessionBufferOptions): SessionBuffer {
  const maxFrames = options.maxFrames ?? BUFFER_MAX_FRAMES
  const maxBytes = options.maxBytes ?? BUFFER_MAX_BYTES
  const entries = new Map<string, Entry>()

  const entryOf = (sid: string): Entry => {
    const existing = entries.get(sid)
    if (existing !== undefined) return existing
    const created: Entry = { events: [], trimmedTo: 0, bytes: 0, acks: new Map(), overflowed: false }
    entries.set(sid, created)
    return created
  }

  /**
   * 裁剪点：**在服务的设备**水位最小值。
   *
   * 在服务 = 此刻在线 ∪ 本轮确认过；两者都要**配对且未吊销**才参与。
   * 在线但没确认过 ⇒ 按 0（它刚连上，还没写盘）；没在服务的一律不看。
   */
  const trimPointOf = (entry: Entry): number => {
    const valid = new Set(options.pairedDevices())
    let point = Number.POSITIVE_INFINITY
    for (const [devId, ack] of entry.acks) {
      if (!valid.has(devId)) continue
      if (ack < point) point = ack
    }
    for (const devId of options.onlineDevices?.() ?? []) {
      if (!valid.has(devId)) continue
      const ack = entry.acks.get(devId) ?? 0
      if (ack < point) point = ack
    }
    // 没有在服务的设备：按 0 处理（一行都不裁）——
    // 宁可留着等下一次重连，也不因为"名册里有设备但都不在线"就丢事件。
    return Number.isFinite(point) ? point : 0
  }

  const trim = (entry: Entry): number => {
    const point = trimPointOf(entry)
    let removed = 0
    while (entry.events.length > 0) {
      const head = entry.events[0]
      if (head === undefined || head.seq > point) break
      entry.events.shift()
      entry.bytes -= Buffer.byteLength(head.body, 'utf8')
      entry.trimmedTo = head.seq
      removed += 1
    }
    return removed
  }

  return {
    get stats() {
      let frames = 0
      let bytes = 0
      for (const entry of entries.values()) {
        frames += entry.events.length
        bytes += entry.bytes
      }
      return { sessions: entries.size, frames, bytes }
    },

    record(sid, event) {
      const entry = entryOf(sid)
      const last = entry.events.at(-1)
      const lastSeq = last === undefined ? entry.trimmedTo : last.seq
      if (event.seq <= lastSeq) {
        // **幂等无操作，不是错误。** 缓冲只留一份，而同一批 `seq` 会被多条连接各记一次 ——
        // 那是正常形态，不是异常：监听面下每台设备各自从自己的水位订阅同一会话，
        // 各自都会把同一段事件推过来（第一台记下，后面的都是这一支）。
        // 缓冲只留一份是对的（重订时不能重放两条）；**但这里不能 `warn`** ——
        // 每台设备每来一批事件刷一行，会把真正的告警淹掉。
        // 倒退的 seq（`event.seq < lastSeq`）走同一支：缓冲是追加式的，插不进更旧的那段，
        // 覆盖不到时 `tailFrom` 会要求快照 —— 那是安全的退化。
        // 为什么这里刻意**不是** `warn`：见 `.agents/notes/implemented/2026-10-02-listener-face.md`。
        options.log?.debug(
          `增量缓冲跳过重复的 seq：${sid} 收到 ${event.seq}（上一条 ${lastSeq}）`,
        )
        return
      }
      entry.events.push(event)
      entry.bytes += Buffer.byteLength(event.body, 'utf8')

      // 超限：先尽量按已确认的部分裁；裁不动就置位"只允许快照"（§5.5：先停推、再要求快照，而不是丢）。
      if (entry.events.length > maxFrames || entry.bytes > maxBytes) {
        trim(entry)
        if (entry.events.length > maxFrames || entry.bytes > maxBytes) {
          entry.overflowed = true
          options.log?.warn(
            `增量缓冲已超限且未获全部设备确认：${sid}（${entry.events.length} 条 / ${entry.bytes} B）—— 之后只走快照`,
          )
        }
      }
    },

    ack(sid, devId, seq) {
      const entry = entries.get(sid)
      if (entry === undefined) return 0
      const previous = entry.acks.get(devId) ?? 0
      // 水位只前进（乱序到达的旧 ack 不该把裁剪点拉回去）。
      if (seq > previous) entry.acks.set(devId, seq)
      const removed = trim(entry)
      // 裁掉一些之后可能又回到上限以内，此时"只允许快照"的判定该撤销。
      if (entry.overflowed && entry.events.length <= maxFrames && entry.bytes <= maxBytes) {
        entry.overflowed = false
      }
      return removed
    },

    tailFrom(sid, since) {
      const entry = entries.get(sid)
      if (entry === undefined) return undefined
      // 超限放弃过：这段内容已经不完整，只能要求快照。
      if (entry.overflowed) return undefined

      const last = entry.events.at(-1)
      if (last === undefined) {
        // 空缓冲：只有"裁到的位置正好接着 since"才算覆盖（否则我们什么都不知道）。
        return entry.trimmedTo === since ? [] : undefined
      }
      // 手机手里的水位比我们还新（§5.3：`since` 大于当前 seq → 要求快照）。
      if (since > last.seq) return undefined
      if (since === last.seq) return [] // 已经对齐，没有增量

      const start = entry.events.findIndex((event) => event.seq === since + 1)
      // 找不到"接着的那一条"：这一段已经被裁掉，或从来没记过。
      if (start < 0) return undefined

      // **整段都要连续**，不只是头部：中间有洞时宁可要求快照，
      // 也绝不返回残缺增量 —— 那会让手机以为"就这些"，从此停在旧内容上。
      for (let index = start; index < entry.events.length; index += 1) {
        const expected = since + 1 + (index - start)
        if (entry.events[index]?.seq !== expected) return undefined
      }
      return entry.events.slice(start)
    },

    forget(sid) {
      entries.delete(sid)
    },
  }
}
