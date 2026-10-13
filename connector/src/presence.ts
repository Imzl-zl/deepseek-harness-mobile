/**
 * 已认证设备的**瞬时**状态：在线、前台、已订阅、最近交互（契约 §6.2 仲裁判定的输入）。
 *
 * ## 为什么它必须存在
 *
 * `protocol/takeover.ts` 的 `decideTakeover` 只根据设备状态判定 claim，而设备状态只有一个
 * 来源——本模块。在它落地之前完整因果链是：
 *
 * ```text
 * 没人写 liveRegistry → liveDevices() 返回 [] → decideTakeover 永不 claim
 * → answerer 永远 next() 交还桌面 → fail-closed 桩根本跑不到
 * ```
 *
 * 也就是说"审批转手机"不是"会拒绝"，而是**永远不触发**。本模块补的就是这一环。
 *
 * ## 三条约束
 *
 * 1. **持久部分不在这里**。身份、配对时间、吊销标记在 `devices` 表里；本模块只持瞬时状态，
 *    进程重启即清零（重连后由连接层重新上报）。混在一起会让"重启后设备还在线"这种假状态
 *    有机会出现。
 * 2. **连接层认证过不等于授权过**。`devices()` 只返回"配对行存在且未吊销"的设备——
 *    这条过滤是 `liveDevices` 的**唯一**去处，写在这里而不是每个读取点各判一遍。
 * 3. **上报全是幂等的覆盖写**。同一个设备重复上报在线/前台/订阅集，结果与上报一次相同
 *    （`sync.hello` 每次回前台都会发一次，契约 §9 的兜底）。
 *
 * 边界：本模块只做状态记账，不认识帧、不认识 DSH。四个上报时机（鉴权完成 / 断开 /
 * 订阅变化 / 收到 `sync.hello`）由 `connection-scope.ts` 回调进来。
 *
 * Note: 为什么"断开整条作废"与"迟到上报不得救活"是两条独立的不变量 ——
 * 见 `.agents/notes/implemented/2026-10-10-interaction-to-phone-chain.md`。
 */
import type { TakeoverDevice } from './protocol/takeover.js'

/** 手机声明的应用态（契约 §5.4 的 `sync.hello.app`）。 */
export type DeviceAppState = 'foreground' | 'background'

/** 一台设备的瞬时状态。`lastInteractedAt` 按会话记（仲裁排序要用它，契约 §6.2）。 */
export interface LiveDeviceRecord {
  online: boolean
  foreground: boolean
  subscribed: string[]
  lastInteractedAt?: Record<string, number>
}

/** 读取面：配对行是否存在且未吊销。返回 `undefined` = 这台设备不参与仲裁。 */
export interface PresenceDevices {
  /** 配对时间（仲裁排序的第二判据）；设备未配对 / 已吊销时返回 `undefined`。 */
  pairedAtOf(devId: string): number | undefined
}

export interface DevicePresence extends PresenceDevices {
  /** 设备完成鉴权、连接进入服务态。 */
  online(devId: string): void
  /** 连接离开服务态（断开 / 重连中 / 插件卸载）。**整条记录作废**，不只是置离线。 */
  offline(devId: string): void
  /** 手机声明前后台态（`sync.hello`）。 */
  app(devId: string, state: DeviceAppState): void
  /** 订阅集**整体**覆盖（订阅 / 退订 / `sync.hello` 声明之后调用）。 */
  subscriptions(devId: string, sids: readonly string[]): void
  /** 手机在这个会话上答了一次话（`lastInteractedAt` 由**连接器**盖时间戳）。 */
  interacted(devId: string, sid: string, at: number): void
  /** 仲裁判定的输入快照（只含已配对且未吊销的设备）。 */
  devices(): readonly TakeoverDevice[]
  /** 一台设备的瞬时记录；不在线（或从未上报）时是 `undefined`。 */
  liveOf(devId: string): LiveDeviceRecord | undefined
  /**
   * 设备下线时通知（在途审批的看护要靠它收口，契约 §6.2 的"手机断开 → unavailable"）。
   *
   * 为什么是推而不是拉：看护的语义是"断开**立刻**收束"，轮询会把最坏情况从
   * "立刻"拖成一个周期。而端口只需要一个信号，不需要知道原因。
   *
   * @returns 注销函数（claim 收束后必须调，否则监听器随每次审批累积）。
   */
  onOffline(devId: string, listener: () => void): () => void
  /** 当前记录数（指标与测试用）。 */
  readonly size: number
}

/**
 * 建一份设备瞬时状态。
 *
 * @param options.pairedAtOf - 配对行读取。**必填**：少了它，"已吊销的设备仍在仲裁里"
 *   这条就只能靠调用方各自记得判，而那是本模块存在的理由的反面。
 */
export function createDevicePresence(options: PresenceDevices): DevicePresence {
  const live = new Map<string, LiveDeviceRecord>()
  /** 下线监听器（按设备分桶）。 */
  const offlineListeners = new Map<string, Set<() => void>>()

  /** 取记录，**没有就建一条在线的**。只给 `online()` 用。 */
  const recordOf = (devId: string): LiveDeviceRecord => {
    const existing = live.get(devId)
    if (existing !== undefined) return existing
    // **新记录默认不在前台、没有订阅**：一个刚连上、还没发 `sync.hello` 的设备
    // 不该被当成"用户正看着手机"。fail-closed 的方向是"不 claim"，不是"先 claim 再说"。
    const created: LiveDeviceRecord = { online: true, foreground: false, subscribed: [] }
    live.set(devId, created)
    return created
  }

  /**
   * 取记录，**没有就什么也不做**。
   *
   * 前台态 / 订阅集 / 最近交互三个上报都走它而不是 {@link recordOf}：它们可能来自一条
   * **正在死去**的连接（`sync.hello` 或一次答话与断开竞速）。用会建记录的版本，
   * 一个迟到的上报就能把一台已断线的设备重新变成"在线"—— 而 `foreground` 档的 claim
   * 判据正是"前台且已订阅"，那条幽灵记录会让审批继续推给一台已经不存在的手机。
   */
  const updateOf = (devId: string): LiveDeviceRecord | undefined => live.get(devId)

  return {
    pairedAtOf: options.pairedAtOf,

    online(devId) {
      recordOf(devId).online = true
    },

    offline(devId) {
      // **整条作废而不是只置 `online: false`**：订阅集属于那条连接，连接没了订阅就没了。
      // 留着旧订阅集会让"设备已断但 decideTakeover 仍认为它订阅着这个会话"——
      // 而 `foreground` 档的 claim 判据正是"前台且已订阅"。
      live.delete(devId)
      // 先清状态再通知：监听器（在途审批的看护）收到的必须是"已经下线"这个事实。
      const listeners = offlineListeners.get(devId)
      if (listeners !== undefined) {
        offlineListeners.delete(devId)
        for (const listener of [...listeners]) listener()
      }
    },

    app(devId, state) {
      const record = updateOf(devId)
      if (record === undefined) return
      record.foreground = state === 'foreground'
    },

    subscriptions(devId, sids) {
      const record = updateOf(devId)
      if (record === undefined) return
      record.subscribed = [...sids]
    },

    interacted(devId, sid, at) {
      const record = updateOf(devId)
      if (record === undefined) return
      record.lastInteractedAt = { ...record.lastInteractedAt, [sid]: at }
    },

    devices() {
      const rows: TakeoverDevice[] = []
      for (const [id, record] of live) {
        // **连接层认证过不等于授权过**：没配过对、或已吊销的设备一律不参与仲裁。
        const pairedAt = options.pairedAtOf(id)
        if (pairedAt === undefined) continue
        rows.push({
          id,
          pairedAt,
          online: record.online,
          foreground: record.foreground,
          subscribed: record.subscribed,
          ...(record.lastInteractedAt === undefined ? {} : { lastInteractedAt: record.lastInteractedAt }),
        })
      }
      return rows
    },

    liveOf(devId) {
      return live.get(devId)
    },

    onOffline(devId, listener) {
      const listeners = offlineListeners.get(devId) ?? new Set<() => void>()
      listeners.add(listener)
      offlineListeners.set(devId, listeners)
      return () => {
        const current = offlineListeners.get(devId)
        if (current === undefined) return
        current.delete(listener)
        // 桶空了就撤掉：否则"每次审批加一个监听器"会随进程寿命无界增长。
        if (current.size === 0) offlineListeners.delete(devId)
      }
    },

    get size() {
      return live.size
    },
  }
}
