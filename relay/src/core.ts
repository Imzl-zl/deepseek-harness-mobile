/** 一设备一数据连接。回程由连接绑定确定，不解析业务内容、不按请求 ID 解复用。
 * 决策：.agents/notes/implemented/2026-10-08-pairing-v2-and-device-connections.md。
 */
import {
  MAX_PENDING_BYTES, MAX_WIRE_BYTES, MAX_PAIRING_CANDIDATES,
  parseDeviceBinding, type DeviceBinding,
} from '../../protocol/relay-control.mjs'
import { createPairingRegistry, type PairingRegistry } from './pairing-registry.ts'
import type { ChannelLogger } from './logger.ts'

export interface RelayChannel {
  readonly channelId: string
  readonly binding: DeviceBinding
  readonly connected: boolean
}
export interface Delivery {
  channelId: string
  to: 'device' | 'data'
  raw: string
}
export interface RelayCoreOptions {
  pairing?: PairingRegistry
  log?: ChannelLogger
}
export interface RelayCore {
  attachConnector(connectorId: string): void
  detachConnector(connectorId: string): readonly string[]
  isConnectorOnline(connectorId: string): boolean
  registerPairing(connectorId: string, offerId: string): number
  lookupPairing(offerId: string): string | undefined
  openDevice(channelId: string, binding: DeviceBinding): void
  attachData(connectorId: string, deviceId: string, channelId: string): readonly Delivery[]
  closeChannel(channelId: string): RelayChannel | undefined
  channel(channelId: string): RelayChannel | undefined
  channelOf(connectorId: string, deviceId: string): string | undefined
  onLine(from: { kind: 'device' | 'data'; channelId: string }, raw: string): readonly Delivery[]
  readonly stats: { connectors: number; devices: number; channels: number; registrations: number; dropped: number }
}

export function createRelayCore(options: RelayCoreOptions = {}): RelayCore {
  const pairing = options.pairing ?? createPairingRegistry(options)
  const connectors = new Set<string>()
  const channels = new Map<string, { binding: DeviceBinding; connected: boolean; pending: string[]; bytes: number }>()
  const byDevice = new Map<string, string>()
  let dropped = 0
  const key = (connectorId: string, deviceId: string): string => JSON.stringify([connectorId, deviceId])
  const snapshot = (channelId: string): RelayChannel | undefined => {
    const channel = channels.get(channelId)
    return channel === undefined ? undefined : { channelId, binding: channel.binding, connected: channel.connected }
  }
  const closeChannel = (channelId: string): RelayChannel | undefined => {
    const current = snapshot(channelId)
    if (current === undefined) return undefined
    channels.delete(channelId)
    const deviceKey = key(current.binding.connectorId, current.binding.deviceId)
    if (byDevice.get(deviceKey) === channelId) byDevice.delete(deviceKey)
    return current
  }

  return {
    get stats() {
      return { connectors: connectors.size, devices: channels.size, channels: channels.size, registrations: pairing.stats.registrations, dropped }
    },
    attachConnector(connectorId) { connectors.add(connectorId) },
    detachConnector(connectorId) {
      connectors.delete(connectorId)
      pairing.forgetConnector(connectorId)
      const removed: string[] = []
      for (const [channelId, channel] of channels) {
        if (channel.binding.connectorId !== connectorId) continue
        closeChannel(channelId)
        removed.push(channelId)
      }
      return removed
    },
    isConnectorOnline(connectorId) { return connectors.has(connectorId) },
    registerPairing(connectorId, offerId) {
      if (!connectors.has(connectorId)) throw new Error('连接器不在线')
      return pairing.register(offerId, connectorId)
    },
    lookupPairing(offerId) {
      const owner = pairing.lookup(offerId)
      return owner !== undefined && connectors.has(owner) ? owner : undefined
    },
    openDevice(channelId, input) {
      const binding = parseDeviceBinding(input)
      if (binding === undefined || !connectors.has(binding.connectorId)) throw new Error('设备归属无效或连接器离线')
      if (channels.has(channelId)) throw new Error('连接代次已存在')
      const deviceKey = key(binding.connectorId, binding.deviceId)
      if (byDevice.has(deviceKey)) throw new Error('旧设备连接必须先关闭')
      if (binding.purpose === 'pairing') {
        const count = [...channels.values()].filter((c) => c.binding.connectorId === binding.connectorId && c.binding.purpose === 'pairing').length
        if (count >= MAX_PAIRING_CANDIDATES) throw new Error('待配对连接数量已达上限')
        if (pairing.lookup(binding.candidate.offerId) !== binding.connectorId) throw new Error('公开邀请已失效')
      }
      channels.set(channelId, { binding, connected: false, pending: [], bytes: 0 })
      byDevice.set(deviceKey, channelId)
    },
    attachData(connectorId, deviceId, channelId) {
      const channel = channels.get(channelId)
      if (channel === undefined || channel.connected || !connectors.has(connectorId)
        || channel.binding.connectorId !== connectorId || channel.binding.deviceId !== deviceId) {
        throw new Error('数据连接的归属或代次不匹配')
      }
      channel.connected = true
      const deliveries = channel.pending.map((raw): Delivery => ({ channelId, to: 'data', raw }))
      channel.pending = []
      channel.bytes = 0
      return deliveries
    },
    closeChannel,
    channel: snapshot,
    channelOf(connectorId, deviceId) { return byDevice.get(key(connectorId, deviceId)) },
    onLine(from, raw) {
      const channel = channels.get(from.channelId)
      if (channel === undefined) { dropped += 1; return [] }
      const bytes = Buffer.byteLength(raw, 'utf8')
      if (bytes > MAX_WIRE_BYTES) throw new Error('帧超过通道上限')
      if (from.kind === 'data') {
        if (!channel.connected) throw new Error('数据连接尚未绑定')
        return [{ channelId: from.channelId, to: 'device', raw }]
      }
      if (channel.connected) return [{ channelId: from.channelId, to: 'data', raw }]
      if (channel.bytes + bytes > MAX_PENDING_BYTES) throw new Error('等待数据连接的缓冲已满')
      channel.pending.push(raw)
      channel.bytes += bytes
      return []
    },
  }
}
