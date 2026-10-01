/**
 * 中转的"大脑"：把**路由**（`routing.ts`）与**配对登记**（`pairing-registry.ts`）
 * 合成一个可以脱离网络测的东西。
 *
 * 网络层随后只做两件事：把 socket 上的一行交给 `onLine`，把 `onLine` 给出的
 * （目标连接, 原始行）写回对应 socket。也就是说**这个文件定义了中转与传输之间的接口** ——
 * 它不认识 WebSocket，也不知道 ticket 是怎么发的。
 *
 * ## 三条路由规则（都来自契约，不是发明）
 *
 * 1. **带 `sid` 的帧**按路由核心的归属表走（§2/§5.5；设备侧的未知 `sid` 丢弃并计数）。
 * 2. **`pair`（没有 `sid`）**按**配对登记**走：设备换 ticket 时用 `codeHash` 认领到一台连接器，
 *    中转记住"这台设备此刻属于哪台连接器"，`pair` 就转给它（§12.1）。
 * 3. **`pair-ack`（没有 `sid`）**按**帧头 `id`** 回到发起的那条设备连接 ——
 *    这就是 I10 把 `id` 也列进可见字段的原因：它是关联标记，不是内容。
 *
 * ## 断开时的三处清理
 *
 * 连接器断开：清它**未认领**的配对登记（否则设备会拿到指向已消失连接的 ticket）、
 * 让它的 `sid` 归属失效（下一台连接器发同一个 `sid` 时重新学）。
 * 设备断开：清它的重放窗口与订阅关系（重连是一次新的订阅），并忘掉它的配对归属。
 */
import { createPairingRegistry, type PairingRegistry } from './pairing-registry.ts'
import { createRouting, type Routing, type RoutedFrame } from './routing.ts'
import { routingViewOf } from './protocol-view.ts'
import type { ChannelLogger } from './logger.ts'

export interface RelayCoreOptions {
  routing?: Routing
  pairing?: PairingRegistry
  log?: ChannelLogger
}

/** 一条要发出去的帧：给哪个连接 + 原始行（中转不解析它）。 */
export interface Delivery {
  to: string
  raw: string
}

export interface RelayCore {
  attachConnector(connectorId: string): void
  detachConnector(connectorId: string): void
  /** 设备连上来（此时还没换 ticket，所以可能还没有配对归属）。 */
  attachDevice(deviceId: string): void
  detachDevice(deviceId: string): void
  /**
   * 设备换 ticket：用 `codeHash` 认领一台连接器，并把这台设备绑给它（§12.1）。
   *
   * @returns 绑到的连接器；没有登记（或已过期/已被认领）返回 `undefined`（中转据此拒绝升级）。
   */
  claimTicket(deviceId: string, codeHash: string): string | undefined
  /** 电脑侧出码时登记（把 `codeHash` 指向自己）。 */
  registerPairing(connectorId: string, codeHash: string): number
  /**
   * 收到一行。
   *
   * @returns 要投递的目标（可能为空：丢弃，已计数）；**从不抛**。
   */
  onLine(from: { kind: 'connector' | 'device'; id: string }, raw: string): readonly Delivery[]
  /** 观测：连接数、路由规模、配对登记数、丢弃计数。 */
  readonly stats: {
    connectors: number
    devices: number
    sessions: number
    windows: number
    frames: number
    registrations: number
    dropped: number
  }
}

export function createRelayCore(options: RelayCoreOptions = {}): RelayCore {
  const log = options.log
  const routing = options.routing ?? createRouting({ ...(log === undefined ? {} : { log: log.debug.bind(log) }) })
  const pairing = options.pairing ?? createPairingRegistry({ ...(log === undefined ? {} : { log }) })

  const connectors = new Set<string>()
  const devices = new Set<string>()
  /** 设备此刻绑给哪台连接器（来自 ticket 认领）。 */
  const binding = new Map<string, string>()
  /** `id` → 发起它的设备。**所有没有 `sid` 的帧**都靠它找回程（配对与握手都在其中）。 */
  const noSidByRequestId = new Map<string, string>()
  /** 设备侧帧的丢弃计数（未知 `sid`、坏行、没有归属）。 */
  let dropped = 0

  const drop = (why: string, detail: unknown): readonly Delivery[] => {
    dropped += 1
    log?.debug(`中转丢弃一帧：${why}`, detail)
    return []
  }

  return {
    get stats() {
      return {
        connectors: connectors.size,
        devices: devices.size,
        sessions: routing.stats.sessions,
        windows: routing.stats.windows,
        frames: routing.stats.frames,
        registrations: pairing.stats.registrations,
        dropped,
      }
    },

    attachConnector(connectorId) {
      connectors.add(connectorId)
    },

    detachConnector(connectorId) {
      connectors.delete(connectorId)
      // 未认领的登记立即失效：否则设备会拿到指向一条已消失连接的 ticket。
      pairing.forgetConnector(connectorId)
      // 绑给它的设备失去归属（它们要么重连，要么等下一次 ticket）。
      for (const [deviceId, bound] of binding) {
        if (bound === connectorId) binding.delete(deviceId)
      }
    },

    attachDevice(deviceId) {
      devices.add(deviceId)
    },

    detachDevice(deviceId) {
      devices.delete(deviceId)
      binding.delete(deviceId)
      routing.forgetDevice(deviceId)
      for (const [requestId, owner] of noSidByRequestId) {
        if (owner === deviceId) noSidByRequestId.delete(requestId)
      }
    },

    claimTicket(deviceId, codeHash) {
      const connectorId = pairing.claim(codeHash)
      if (connectorId === undefined) return undefined
      // 认领成功但连接器已经走了：不能把设备绑到一条不存在的连接上。
      if (!connectors.has(connectorId)) {
        log?.warn(`配对登记指向的连接器不在线：${connectorId}（设备 ${deviceId} 无法升级）`)
        return undefined
      }
      binding.set(deviceId, connectorId)
      return connectorId
    },

    registerPairing(connectorId, codeHash) {
      return pairing.register(codeHash, connectorId)
    },

    onLine(from, raw) {
      const view = routingViewOf(raw)
      if (view === undefined) return drop('解析不出路由视图', { from: from.id })
      const frame: RoutedFrame = { view, raw }

      if (from.kind === 'connector') {
        if (!connectors.has(from.id)) return drop('来源连接器不在线', { id: from.id })
        if (view.sid === '') {
          // **电脑侧没有 `sid` 的回帧**（`pair-ack` / `hello-ack` / `confirm`…）靠 `id` 回到发起方。
          // 与设备侧对称：两边都没有 `sid` 可言时，`id` 是唯一的关联凭据（I10 把它列为可见字段）。
          const requestId = view.id ?? ''
          const deviceId = noSidByRequestId.get(requestId)
          if (deviceId === undefined) return drop(`${view.t} 找不到对应设备`, { requestId })
          noSidByRequestId.delete(requestId)
          return devices.has(deviceId) ? [{ to: deviceId, raw }] : drop('目标设备已断开', { deviceId })
        }
        const targets = routing.fromConnector(from.id, frame)
        return targets.filter((deviceId) => devices.has(deviceId)).map((deviceId) => ({ to: deviceId, raw }))
      }

      if (!devices.has(from.id)) return drop('来源设备不在线', { id: from.id })
      if (view.sid === '') {
        // **没有 `sid` 的帧一律按 ticket 绑定路由**（配对请求、握手三帧、保活…）：
        // 它们在会话存在**之前**就要能到电脑侧，而归属于 `sid` 的那张表是按会话学的 ——
        // 帮不上它们。少了这条，设备的第一帧 `hello` 会被丢弃，表现是"配好了却永远握不上手"。
        const connectorId = binding.get(from.id)
        if (connectorId === undefined) return drop('设备还没有配对归属（未换 ticket）', { id: from.id })
        // 记住是**哪台设备**发的这个 `id`：电脑侧的回执（`pair-ack` / `hello-ack` / `confirm`）
        // 同样没有 `sid`，只能靠 `id` 找回发起方 —— 这正是 I10 把 `id` 列为可见字段的原因。
        const requestId = view.id ?? ''
        if (requestId !== '') noSidByRequestId.set(requestId, from.id)
        return connectors.has(connectorId)
          ? [{ to: connectorId, raw }]
          : drop('绑定到的连接器已断开', { connectorId })
      }
      const connectorId = routing.fromDevice(from.id, frame)
      if (connectorId === undefined) return drop('这个 sid 还没有归属', { sid: view.sid })
      return connectors.has(connectorId) ? [{ to: connectorId, raw }] : drop('归属的连接器已断开', { connectorId })
    },
  }
}
