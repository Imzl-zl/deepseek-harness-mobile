/** 真中转子进程 + 产品 RelayLink/DeviceConnection + 独立手机侧密码实现。 */
import { createHash, randomBytes } from 'node:crypto'
import { WebSocket } from 'ws'
import { deriveIdentity, type SessionKeys } from '../../src/protocol/crypto.js'
import { createPairing, pairingCodeHash, pairingIdOf, pairingHandshakeContext, PAIRING_KEY_INFO, type PairingOffer, type PairingCandidate } from '../../src/pairing.js'
import { createPairingEndpoint, type PairedDeviceRow, type PairingReply } from '../../src/pairing-endpoint.js'
import { createPairingRegistrar } from '../../src/pairing-register.js'
import { createDevicePublisher } from '../../src/device-publish.js'
import { createRelayLink, type RelayLink } from '../../src/transport/relay-link.js'
import { createDeviceConnection } from '../../src/device-connection.js'
import { createSessionBuffer } from '../../src/session-buffer.js'
import { createMetrics, silentLogger } from '../../src/observability.js'
import type { Connection } from '../../src/transport/connection.js'
import type { ConnectionScopeDeps } from '../../src/connection-scope.js'
import { createPhone, phoneOpenBox, phoneSealBox } from './phone.js'
import { startRelayProcess, waitFor, type RelayProcess } from './relay-process.js'

export const CONNECTOR_ID = 'conn-1'
export const CONNECTOR_TOKEN = 'connector-token-1'
export const PC_SEED = 'a1'.repeat(32)
export type Cleanup = { after(fn: () => void | Promise<void>): void }
export const deviceIdOf = (dhPub: string): string => createHash('sha256').update(dhPub, 'utf8').digest().subarray(0, 16).toString('base64url')
export interface Chain {
  relay: RelayProcess
  httpBase: string
  wsBase: string
  link: RelayLink
  devices: Map<string, PairedDeviceRow>
  connections: Map<string, Connection>
  diagnostics: string[]
  issueCode(): Promise<PairingOffer>
  published(): number
  restartRelay(): Promise<void>
}

export async function startChain(t: Cleanup): Promise<Chain> {
  const relay = await startRelayProcess(t, [{ kind: 'connector', id: CONNECTOR_ID, token: CONNECTOR_TOKEN }])
  const httpBase = `http://127.0.0.1:${relay.port}`
  const wsBase = `ws://127.0.0.1:${relay.port}`
  const pc = deriveIdentity(PC_SEED)
  const devices = new Map<string, PairedDeviceRow>()
  const connections = new Map<string, Connection>()
  const diagnostics: string[] = []
  const logger = {
    ...silentLogger,
    warn: (message: string, detail?: unknown) => diagnostics.push(`${message}: ${detail instanceof Error ? detail.stack : String(detail ?? '')}`),
    info: (message: string) => diagnostics.push(message),
  }
  const pairing = createPairing({ pcId: CONNECTOR_ID, relayUrl: wsBase, pcPubEd: pc.sign.publicKeyHex, pcPubDh: pc.dh.publicKeyHex })
  let published = 0
  const publisher = createDevicePublisher({ relayUrl: wsBase, allowInsecureLocal: true, tokenSource: async () => CONNECTOR_TOKEN })
  const publish = async (): Promise<void> => {
    await publisher([...devices].map(([id, row]) => ({
      id, name: row.name, pairingId: row.pairingId, devPubEd: row.edPubHex, devPubDh: row.dhPubHex,
      tokenHash: row.tokenHash!,
    })))
    published += 1
  }
  const enrollment = createPairingEndpoint({
    pairing, pcId: CONNECTOR_ID, announce: publish,
    putDevice: async (id, row) => { devices.set(id, row) },
    findPreviousPairing: (pairingId) => {
      for (const [id, row] of devices) {
        if (row.pairingId === pairingId) return { devId: id, pairedAt: row.pairedAt }
      }
      return null
    },
    removeDevice: async (id) => { devices.delete(id) },
  })
  const sessions = {
    list: async () => [], page: async () => ({ records: [], hasMore: false }),
    prompt: async () => ({ accepted: true as const }), cancel: () => ({ accepted: true as const }),
    updateQueue: async () => ({ accepted: true as const }),
    selectModel: async () => ({ selected: { provider: 'test', model: 'test' } }),
    create: async () => ({ sessionId: 'dsh-new' }),
    follow: (): never => { throw new Error('本用例不应建立 DSH 订阅') },
  }
  const scope: ConnectionScopeDeps = {
    logger, metrics: createMetrics(), sessions,
    buffer: createSessionBuffer({ pairedDevices: () => [...devices.keys()] }), jobControl: null, idempotency: null,
    handlers: {
      caps: () => ({ sessions: true, storage: true, approval: false, questions: false, jobs: false, subagents: false, settings: false, credentials: true, direct: false }),
      aliasVersion: () => 1, sessions, aliases: { ensure: async () => 's1', sessionOf: () => undefined },
      devices: () => [...devices].map(([id, row]) => ({ id, name: row.name, pairedAt: row.pairedAt, revoked: false })),
    },
  }
  const link = createRelayLink({
    url: wsBase, token: CONNECTOR_TOKEN, allowInsecureLocal: true, log: logger,
    onConnected: publish,
    allows: (binding) => binding.purpose === 'pairing' ? pairing.allows(binding.candidate) : devices.has(binding.deviceId),
    createData: (binding) => {
      const connection = createDeviceConnection({
        identity: pc, pcId: CONNECTOR_ID, pairing, enrollment, binding, scope,
        peerOf: (id) => {
          const row = devices.get(id)
          return row === undefined ? undefined : { edPubHex: row.edPubHex, dhPubHex: row.dhPubHex, pairingId: row.pairingId }
        },
      })
      connections.set(binding.deviceId, connection)
      return connection
    },
  })
  t.after(() => { link.stop(); enrollment.dispose() })
  link.start()
  await waitFor('控制面连接并发布名册', () => published > 0)
  const register = createPairingRegistrar({ relayUrl: wsBase, allowInsecureLocal: true, tokenSource: async () => CONNECTOR_TOKEN })
  return {
    relay, httpBase, wsBase, link, devices, connections, diagnostics,
    published: () => published,
    issueCode: async () => { const offer = pairing.offer(); await register(offer.offerId); return offer },
    restartRelay: async () => {
      const before = published
      await relay.restart()
      await waitFor('控制面恢复并重建名册', () => published > before, 15_000)
    },
  }
}

export async function ticketByCandidate(chain: Chain, candidate: PairingCandidate): Promise<string> {
  const response = await fetch(`${chain.httpBase}/ws-ticket`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ v: 2, ...candidate }),
  })
  if (response.status !== 201) throw new Error(`候选换票 ${response.status}: ${await response.text()}`)
  return ((await response.json()) as { ticket: string }).ticket
}
export async function ticketByToken(chain: Chain, token: string): Promise<string> {
  const response = await fetch(`${chain.httpBase}/ws-ticket`, {
    method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: '{}',
  })
  if (response.status !== 201) throw new Error(`设备换票 ${response.status}: ${await response.text()}`)
  return ((await response.json()) as { ticket: string }).ticket
}

export interface ConnectedPhone {
  socket: WebSocket
  raw: string[]
  deviceId: string
  commit(code?: string): Promise<PairingReply>
  request(method: string): Promise<Record<string, unknown>>
}
export async function connectPhone(
  t: Cleanup,
  chain: Chain,
  options: { seed: string; offer: PairingOffer; token?: string; advertised?: PairingCandidate },
): Promise<ConnectedPhone> {
  const identity = deriveIdentity(options.seed)
  const pc = deriveIdentity(PC_SEED)
  const candidate: PairingCandidate = { offerId: options.offer.offerId, devPubEd: identity.sign.publicKeyHex, devPubDh: identity.dh.publicKeyHex, name: '测试手机' }
  const deviceId = deviceIdOf(candidate.devPubDh)
  const pairing = options.token === undefined
  const ticket = pairing ? await ticketByCandidate(chain, options.advertised ?? candidate) : await ticketByToken(chain, options.token!)
  const phone = createPhone({
    devId: deviceId, staticSeedHex: identity.dhSeedHex, signSeedHex: identity.signSeedHex,
    ephSeedHex: randomBytes(32).toString('hex'), nonceA: randomBytes(32).toString('hex'),
    pairingId: pairing ? options.offer.offerId : pairingIdOf(pairingCodeHash(options.offer.code)),
    pcSignPubHex: pc.sign.publicKeyHex, pcDhPubHex: pc.dh.publicKeyHex,
    ...(pairing ? {
      info: PAIRING_KEY_INFO,
      transcriptContext: pairingHandshakeContext({ pcId: CONNECTOR_ID, pcPubEd: pc.sign.publicKeyHex, pcPubDh: pc.dh.publicKeyHex }, candidate),
    } : {}),
  })
  const socket = new WebSocket(`${chain.wsBase}/ws/device?ticket=${encodeURIComponent(ticket)}`)
  t.after(() => socket.terminate())
  const raw: string[] = []
  let keys: SessionKeys | undefined
  let fc = 0
  const pending = new Map<string, { resolve(value: Record<string, unknown>): void; reject(error: Error): void }>()
  let resolveReady: () => void
  let rejectReady: (error: unknown) => void
  const ready = new Promise<void>((resolve, reject) => { resolveReady = resolve; rejectReady = reject })
  const timer = setTimeout(() => rejectReady(new Error('手机握手超时')), 10_000)
  socket.on('open', () => socket.send(`${JSON.stringify({ v: 1, t: 'hello', id: 'hello', box: phone.helloBox() })}\n`))
  socket.on('error', (error) => rejectReady(error))
  socket.on('close', (code, reason) => {
    rejectReady(new Error(`连接在握手完成前关闭（${code} ${reason.toString()}）\n${chain.diagnostics.join('\n')}\n${chain.relay.output()}`))
    for (const entry of pending.values()) entry.reject(new Error('连接已关闭'))
  })
  socket.on('message', (data) => {
    raw.push(data.toString())
    try {
      for (const line of data.toString().split('\n').filter((value) => value.trim() !== '')) {
        const frame = JSON.parse(line) as Record<string, unknown>
        if (frame['t'] === 'hello-ack') {
          const ack = phone.acceptAck(String(frame['box']))
          keys = ack.keys
          socket.send(`${JSON.stringify({ v: 1, t: 'confirm', id: 'confirm', box: ack.confirmBox })}\n`)
          resolveReady()
        } else if (keys !== undefined && (frame['t'] === 'res' || frame['t'] === 'pair-result')) {
          const opened = phoneOpenBox({ keys, header: { t: String(frame['t']), id: String(frame['id']), fc: Number(frame['fc']) }, box: String(frame['box']) })
          pending.get(String(frame['id']))?.resolve(JSON.parse(opened) as Record<string, unknown>)
        }
      }
    } catch (error) { rejectReady(error); socket.close() }
  })
  try { await ready } finally { clearTimeout(timer) }
  const send = (type: string, body: unknown): Promise<Record<string, unknown>> => {
    const id = `${type}-${fc}`
    const header = { t: type, id, fc: fc++ }
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { pending.delete(id); reject(new Error('应答超时')) }, 10_000)
      pending.set(id, {
        resolve: (value) => { clearTimeout(timeout); pending.delete(id); resolve(value) },
        reject: (error) => { clearTimeout(timeout); pending.delete(id); reject(error) },
      })
      socket.send(`${JSON.stringify({ v: 1, ...header, box: phoneSealBox({ keys: keys!, header, plaintext: JSON.stringify(body) }) })}\n`)
    })
  }
  return {
    socket, raw, deviceId,
    commit: async (code = options.offer.code) => await send('pair-commit', { v: 2, offerId: options.offer.offerId, code }) as unknown as PairingReply,
    request: (method) => send('req', { method }),
  }
}
export { waitFor }
