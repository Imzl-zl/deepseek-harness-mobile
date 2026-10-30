/**
 * 已认证设备的**瞬时**状态：在线、前台、已订阅、最近交互。
 *
 * ## 它为什么存在
 *
 * 三个读者：管理面的设备列表（在线 / 前台 / 最近交互的排序）、
 * `connection-scope.ts` 的订阅集上报、以及"手机答过一次话"的时间戳。它们都要的是
 * **同一个事实**（这台设备此刻是什么样），所以只能有一个记账处。
 *
 * 注意：**没有"谁接管"这种判定了**。连接器是 gateway 的一个 client，和浏览器并列 ——
 * 手机连着就参与，不连着就没有投递，不存在需要"档位"来仲裁的场景（见契约 §6.2）。
 *
 * ## 三条约束
 *
 * 1. **持久部分不在这里**。身份、配对时间、吊销标记在 `devices` 表里；本模块只持瞬时状态，
 *    进程重启即清零（重连后由连接层重新上报）。混在一起会让"重启后设备还在线"这种假状态
 *    有机会出现。
 * 2. **连接层认证过不等于授权过**。`devices()` 只返回"配对行存在且未吊销"的设备——
 *    这条过滤只写在这一个地方，而不是每个读取点各判一遍。
 * 3. **上报全是幂等的覆盖写**。同一个设备重复上报在线/前台/订阅集，结果与上报一次相同
 *    （`sync.hello` 每次回前台都会发一次，契约 §9 的兜底）。
 *
 * 边界：本模块只做状态记账，不认识帧、不认识 DSH。四个上报时机（鉴权完成 / 断开 /
 * 订阅变化 / 收到 `sync.hello`）由 `connection-scope.ts` 回调进来。
 *
 * Note: 为什么"断开整条作废"与"迟到上报不得救活"是两条独立的不变量 ——
 * 见 `.agents/notes/implemented/2026-10-10-interaction-to-phone-chain.md`。
 */

/** 一台设备的状态快照（管理面与 presence 的读取面共用这一个形状）。 */
export interface DeviceState {
  id: string
  online: boolean
  foreground: boolean
  subscribed: readonly string[]
  pairedAt: number
  /** 按会话记的"最近答话时间"（管理面排序用）。 */
  lastInteractedAt?: Record<string, number>
}

/** 手机声明的应用态（契约 §5.4 的 `sync.hello.app`）。 */
export type DeviceAppState = 'foreground' | 'background'

/** 一台设备的瞬时状态。`lastInteractedAt` 按会话记。 */
export interface LiveDeviceRecord {
  online: boolean
  foreground: boolean
  subscribed: string[]
  lastInteractedAt?: Record<string, number>
  /**
   * 占着这条记录的那一条连接（不透明令牌，由连接层给）。
   *
   * 存在的理由：同一台设备**换网重连**时旧连接与新连接会重叠一小段 ——
   * 旧连接迟到的 `offline` 若照直删记录，会把**新连接**刚占上的服务位抹掉
   * （面板显示离线，下一台设备因此被放进来）。所以 `offline` 只在令牌相同时才删。
   */
  holder?: object
}

/** 读取面：配对行是否存在且未吊销。返回 `undefined` = 这台设备不参与仲裁。 */
export interface PresenceDevices {
  /** 配对时间（仲裁排序的第二判据）；设备未配对 / 已吊销时返回 `undefined`。 */
  pairedAtOf(devId: string): number | undefined
}

export interface DevicePresence extends PresenceDevices {
  /**
   * 设备完成鉴权、连接进入服务态。
   *
   * @param holder - 这条连接的令牌（连接层给）。同一台设备重连时新令牌覆盖旧令牌，
   *   之后旧连接的 `offline` 不会误删新连接占上的服务位。
   */
  online(devId: string, holder?: object): void
  /**
   * 连接离开服务态（断开 / 重连中 / 插件卸载）。**整条记录作废**，不只是置离线。
   *
   * @param holder - 这条连接的令牌；与记录上的**不同**则什么都不做（见 `online`）。
   */
  offline(devId: string, holder?: object): void
  /** 手机声明前后台态（`sync.hello`）。 */
  app(devId: string, state: DeviceAppState): void
  /** 订阅集**整体**覆盖（订阅 / 退订 / `sync.hello` 声明之后调用）。 */
  subscriptions(devId: string, sids: readonly string[]): void
  /** 手机在这个会话上答了一次话（`lastInteractedAt` 由**连接器**盖时间戳）。 */
  interacted(devId: string, sid: string, at: number): void
  /** 状态快照（只含已配对且未吊销的设备）。 */
  devices(): readonly DeviceState[];
  /**
   * **占用位（独占 1:1）**：此刻在服务的那台有效设备。没有就 `undefined`。
   *
   * 它就是 {@link devices} 里 `online` 的那一条 —— **不另立第二份状态**：
   * 停用（`revokedAt`）/ 已删除的行被 `devices()` 滤掉，自然不占位；
   * 幽灵占用靠 keepalive 的半开判定收口（`transport/keepalive.ts`）。
   * 握手准入拿它判 `device/busy`（`exclusive.ts`），面板拿它显示"此刻在服务"。
   */
  serving(): DeviceState | undefined;
  /** 一台设备的瞬时记录；不在线（或从未上报）时是 `undefined`。 */
  liveOf(devId: string): LiveDeviceRecord | undefined
  /** 当前记录数（指标与测试用）。 */
  readonly size: number
}

/**
 * 建一份设备瞬时状态。
 *
 * @param options.pairedAtOf - 配对行读取。**必填**：少了它，"已吊销的设备仍出现在列表里"
 *   这条就只能靠调用方各自记得判，而那是本模块存在的理由的反面。
 */
export function createDevicePresence(options: PresenceDevices): DevicePresence {
  const live = new Map<string, LiveDeviceRecord>()

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

  /** 状态快照。`devices()` 与 `serving()` 共用它 —— 两条读取面不许各判一遍"有效"。 */
  const snapshot = (): readonly DeviceState[] => {
    const rows: DeviceState[] = []
    for (const [id, record] of live) {
      // **连接层认证过不等于授权过**：没配过对、或已吊销的设备一律不列出。
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
  }

  return {
    pairedAtOf: options.pairedAtOf,

    online(devId, holder) {
      const record = recordOf(devId)
      record.online = true
      // **新连接接管记录**：同一台设备换网重连时，旧连接之后迟到的 offline
      // 会因为这个令牌不同而**什么都不做**（见 `offline`）。
      if (holder !== undefined) record.holder = holder
    },

    offline(devId, holder) {
      // **整条作废而不是只置 `online: false`**：订阅集属于那条连接，连接没了订阅就没了。
      // 留着旧订阅集会让管理面显示"这台设备还订阅着这个会话"。
      //
      // **令牌不同就不删**：那是"旧连接迟到的断开"——记录现在属于新连接。
      // 少了这一条，换网重连之后面板显示离线、服务位丢失，下一台设备会被放进来。
      const record = live.get(devId)
      if (record === undefined) return
      if (holder !== undefined && record.holder !== undefined && record.holder !== holder) return
      // **这里不通知任何人**：断线不是任何交互的终态（DSH 的 gateway 断线只撤投递、
      // 不结算，`packages/api/gateway/src/index.ts:717-721`），在途 claim 挂在 Host 上、
      // 等手机回来还能答（契约 §6.2）。
      live.delete(devId)
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

    devices: snapshot,

    serving() {
      // 遍历的就是 `devices()` 的同一份事实（同一个过滤），所以"有效"的判据只有一处。
      for (const row of snapshot()) {
        if (row.online) return row
      }
      return undefined
    },

    liveOf(devId) {
      return live.get(devId)
    },

    get size() {
      return live.size
    },
  }
}
