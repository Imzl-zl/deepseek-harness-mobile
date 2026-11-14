/**
 * **没有中转的配对**：手机拨连接器的监听面，走完配对帧，拿到设备凭据。
 *
 * 这一组是"关掉中转也能配对"的连接器侧证据，所以它**刻意不启中转**：
 *
 * - `relayUrl` 是一个解析不了的域名 —— 任何一处偷偷去拨它都会让用例红；
 * - `announce`（名册上报）**必然抛** —— 纯局域网就是这样，配对不该因此失败；
 * - 手机侧用 `support/phone.ts` 那份**独立实现**，不 import 产品握手代码。
 *
 * 覆盖四件事：
 *
 * 1. `?pair=<offerId>&cand=<候选>` 被认成配对连接，握手与 `pair-commit` 走通，落一行设备；
 * 2. 秘密与令牌**不出现在明文帧里**（与中转那条路同一条不变量）；
 * 3. 过期/被新码顶掉的邀请**连不上** —— 判据是 `pairing.allows`，不是"URL 里有没有 pair"；
 * 4. 配对之后**同一条监听面**能认出这台设备（普通直连，无 `?pair=`）—— 即"之后纯局域网可用"。
 */
import assert from 'node:assert/strict'
import { randomBytes } from 'node:crypto'
import { test } from 'node:test'

import { WebSocket } from 'ws'

import { createDeviceConnection } from '../src/device-connection.js'
import { createConnectionScope, type ConnectionScopeDeps } from '../src/connection-scope.js'
import { createPairingEndpoint, type PairedDeviceRow } from '../src/pairing-endpoint.js'
import {
  PAIRING_KEY_INFO,
  createPairing,
  deviceIdOf,
  pairingCodeHash,
  pairingHandshakeContext,
  pairingIdOf,
  type PairingCandidate,
  type PairingOffer,
} from '../src/pairing.js'
import { pairingDialUrl, readPairingRequest } from '../src/pairing-lan.js'
import { createSessionBuffer } from '../src/session-buffer.js'
import { deriveIdentity, type SessionKeys } from '../src/protocol/crypto.js'
import { createMetrics, silentLogger } from '../src/observability.js'
import { startListener, type Listener } from '../src/transport/listener.js'
import type { Connection, DialSocket } from '../src/transport/connection.js'
import { createPhone, phoneOpenBox, phoneSealBox, type Phone } from './support/phone.js'
import { waitFor } from './support/peer.js'

const CONNECTOR_ID = 'conn-lan'
const PC_SEED = 'a1'.repeat(32)
const PHONE_SEED = 'c3'.repeat(32)
/** 故意拨不通：本用例证明配对全程没用到中转。 */
const DEAD_RELAY = 'wss://relay.invalid/ws/connector'

type Cleanup = { after(fn: () => void | Promise<void>): void }

interface LanChain {
  listener: Listener
  /** 监听面的可拨地址（`ws://127.0.0.1:<port>`）。 */
  lanBase: string
  devices: Map<string, PairedDeviceRow>
  /** 走普通直连（已配对设备）建立成功时收到的 devId。 */
  established: string[]
  /** 监听面按 `?pair=` 建出来的连接（按 accept 顺序）。 */
  accepted: { pairing: boolean }[]
  offer(): PairingOffer
  dispose(): Promise<void>
}

async function startLanChain(t: Cleanup): Promise<LanChain> {
  const pc = deriveIdentity(PC_SEED)
  const devices = new Map<string, PairedDeviceRow>()
  const established: string[] = []
  const accepted: { pairing: boolean }[] = []
  let lanBase = ''

  const pairing = createPairing({
    pcId: CONNECTOR_ID,
    relayUrl: DEAD_RELAY,
    // 出码时求值：监听面的端口要起来之后才知道。
    lanUrls: () => [lanBase],
    pcPubEd: pc.sign.publicKeyHex,
    pcPubDh: pc.dh.publicKeyHex,
  })
  const enrollment = createPairingEndpoint({
    pairing,
    pcId: CONNECTOR_ID,
    putDevice: async (id, row) => { devices.set(id, row) },
    findPreviousPairing: () => null,
    // **纯局域网：名册上报必然失败**（没有中转可报）。配对不该因此失败。
    announce: async () => { throw new Error('这台机器没有中转') },
    log: silentLogger,
  })

  const sessions = {
    list: async () => [], page: async () => ({ records: [], hasMore: false }),
    prompt: async () => ({ accepted: true as const }), cancel: () => ({ accepted: true as const }),
    updateQueue: async () => ({ accepted: true as const }),
    selectModel: async () => ({ selected: { provider: 'test', model: 'test' } }),
    create: async () => ({ sessionId: 'dsh-new' }),
    fork: async () => ({ childSessionId: 'dsh-child' }),
    rename: async () => ({ title: 't', seq: 1 }),
    follow: (): never => { throw new Error('本用例不应建立 DSH 订阅') },
  }
  const scope: ConnectionScopeDeps = {
    logger: silentLogger, metrics: createMetrics(), sessions,
    buffer: createSessionBuffer({ pairedDevices: () => [...devices.keys()] }),
    jobControl: null, idempotency: null,
    handlers: {
      caps: () => ({
        sessions: true, storage: true, approval: false, questions: false, jobs: false,
        subagents: false, references: false, plugins: false, files: false, changes: false,
        settings: false, credentials: true, direct: true, team: false,
      }),
      aliasVersion: () => 1, sessions,
      aliases: { ensure: async () => 's1', sessionOf: () => undefined },
      devices: () => [...devices].map(([id, row]) => ({ id, name: row.name, pairedAt: row.pairedAt, revoked: false })),
    },
    onDeviceEstablished: (devId) => { established.push(devId) },
  }

  /** 与 `index.ts` 的 `makeConnection(binding)` 同形：候选身份决定这条连接的用途。 */
  const makeConnection = (binding?: Parameters<typeof createDeviceConnection>[0]['binding']): Connection =>
    createDeviceConnection({
      identity: pc, pcId: CONNECTOR_ID, pairing, enrollment, scope,
      ...(binding === undefined ? {} : { binding }),
      peerOf: (id) => {
        const row = devices.get(id)
        return row === undefined ? undefined : { edPubHex: row.edPubHex, dhPubHex: row.dhPubHex, pairingId: row.pairingId }
      },
    })

  const listener = await startListener({
    port: 0,
    host: '127.0.0.1',
    log: silentLogger,
    accept: (request) => {
      // 与 `index.ts` 的 `bindingOfUpgrade` 同一条判据（这里是它的最小复述）。
      const query = readPairingRequest(request.url)
      const candidate = query.candidate
      accepted.push({ pairing: candidate !== undefined })
      const binding = candidate === undefined
        ? undefined
        : { connectorId: CONNECTOR_ID, deviceId: deviceIdOf(candidate), purpose: 'pairing' as const, candidate }
      const connection = makeConnection(binding)
      return {
        port: connection,
        attach: (socket) => connection.attach(socket as DialSocket),
        stop: () => connection.stop(),
      }
    },
  })
  lanBase = `ws://127.0.0.1:${listener.port}`

  const chain: LanChain = {
    listener, lanBase, devices, established, accepted,
    offer: () => pairing.offer(),
    dispose: async () => { enrollment.dispose(); await listener.close() },
  }
  t.after(() => chain.dispose())
  return chain
}

/** 一次配对用的手机侧身份（主种子 → 两把公钥）。 */
function phoneFor(offer: PairingOffer, overrides: Partial<PairingCandidate> = {}): { candidate: PairingCandidate; phone: Phone; devId: string } {
  const identity = deriveIdentity(PHONE_SEED)
  const pc = deriveIdentity(PC_SEED)
  const candidate: PairingCandidate = {
    offerId: offer.offerId,
    devPubEd: identity.sign.publicKeyHex,
    devPubDh: identity.dh.publicKeyHex,
    name: '测试手机',
    ...overrides,
  }
  const phone = createPhone({
    devId: deviceIdOf(candidate),
    staticSeedHex: identity.dhSeedHex,
    signSeedHex: identity.signSeedHex,
    ephSeedHex: randomBytes(32).toString('hex'),
    nonceA: randomBytes(32).toString('hex'),
    pairingId: offer.offerId,
    pcSignPubHex: pc.sign.publicKeyHex,
    pcDhPubHex: pc.dh.publicKeyHex,
    info: PAIRING_KEY_INFO,
    transcriptContext: pairingHandshakeContext(
      { pcId: CONNECTOR_ID, pcPubEd: pc.sign.publicKeyHex, pcPubDh: pc.dh.publicKeyHex },
      candidate,
    ),
  })
  return { candidate, phone, devId: deviceIdOf(candidate) }
}

interface PhoneSession {
  socket: WebSocket
  lines: string[]
  keys: SessionKeys
}

/** 连上去、走完三帧握手，返回已解出会话密钥的那条连接。 */
async function handshake(t: Cleanup, url: string, phone: Phone, options: { pairing: boolean }): Promise<PhoneSession> {
  const socket = new WebSocket(url)
  t.after(() => socket.terminate())
  const lines: string[] = []
  const closed = new Promise<number>((resolve) => { socket.on('close', (code) => resolve(code)) })
  const opened = new Promise<void>((resolve, reject) => {
    socket.on('open', () => resolve())
    socket.on('error', () => reject(new Error(`连不上 ${url}`)))
  })
  socket.on('message', (data) => { lines.push(data.toString()) })
  await opened
  socket.send(`${JSON.stringify({ v: 1, t: 'hello', id: 'h1', box: phone.helloBox() })}\n`)
  const acked = await Promise.race([
    waitFor('收到 hello-ack', () => lines.some((line) => line.includes('"t":"hello-ack"')), 5_000)
      .then(() => 'ack' as const),
    closed.then((code) => `closed:${code}` as const),
  ])
  if (acked !== 'ack') {
    throw new Error(`握手被拒（${acked}）${options.pairing ? '：候选没被认成配对连接' : ''}`)
  }
  const ackLine = lines.find((line) => line.includes('"t":"hello-ack"'))!
  const ack = JSON.parse(ackLine) as { box: string }
  const accepted = phone.acceptAck(ack.box)
  socket.send(`${JSON.stringify({ v: 1, t: 'confirm', id: 'c1', box: accepted.confirmBox })}\n`)
  return { socket, lines, keys: accepted.keys }
}

test('无中转配对：?pair= 被认成候选 → 握手 → pair-commit → 拿到设备凭据', async (t) => {
  const chain = await startLanChain(t)
  const offer = chain.offer()
  assert.deepEqual(offer.lanUrls, [chain.lanBase], '二维码里必须有局域网地址（否则这条用例本身不成立）')

  const { candidate, phone, devId } = phoneFor(offer)
  const session = await handshake(t, pairingDialUrl(chain.lanBase, candidate), phone, { pairing: true })
  assert.deepEqual(chain.accepted, [{ pairing: true }], '监听面要把这条连接按配对候选建')
  assert.equal(chain.devices.size, 0, '握手结束仍是候选：没提交秘密就不能登记')

  const body = JSON.stringify({ v: 2, offerId: offer.offerId, code: offer.code })
  session.socket.send(`${JSON.stringify({
    v: 1, t: 'pair-commit', id: 'k1', fc: 0,
    box: phoneSealBox({ keys: session.keys, header: { t: 'pair-commit', id: 'k1', fc: 0 }, plaintext: body }),
  })}\n`)

  await waitFor('收到 pair-result', () => session.lines.some((line) => line.includes('"t":"pair-result"')), 5_000)
  const resultLine = session.lines.find((line) => line.includes('"t":"pair-result"'))!
  const frame = JSON.parse(resultLine) as { id: string; fc: number; box: string }
  assert.equal(frame.id, 'k1', '回帧要回显提交那一跳的 id')
  const ack = JSON.parse(phoneOpenBox({
    keys: session.keys,
    header: { t: 'pair-result', id: frame.id, fc: frame.fc },
    box: frame.box,
  })) as Record<string, unknown>

  assert.equal(ack['ok'], true, `配对应当成功（实际：${JSON.stringify(ack)}）`)
  assert.match(String(ack['deviceToken']), /^[A-Za-z0-9_-]{22}$/)
  assert.match(String(ack['refreshToken']), /^[A-Za-z0-9_-]{22}$/)
  assert.equal(ack['devId'], devId)
  assert.equal(ack['pcId'], CONNECTOR_ID)

  const row = chain.devices.get(devId)
  assert.ok(row, '提交成功要落一行设备（否则之后握手认不出它）')
  assert.equal(row.edPubHex, candidate.devPubEd)
  assert.equal(row.dhPubHex, candidate.devPubDh)
  assert.equal(row.pairingId, pairingIdOf(pairingCodeHash(offer.code)))

  // 秘密与长期令牌**不许出现在明文帧里**（中转那条路的不变量在这里同样成立）。
  const raw = session.lines.join('')
  assert.equal(raw.includes(offer.code), false)
  assert.equal(raw.includes(String(ack['deviceToken'])), false)
  assert.equal(raw.includes(String(ack['refreshToken'])), false)
})

test('无中转配对之后：同一条监听面认出这台设备（普通直连，不再带 ?pair=）', async (t) => {
  const chain = await startLanChain(t)
  const offer = chain.offer()
  const { candidate, phone, devId } = phoneFor(offer)

  const pairing = await handshake(t, pairingDialUrl(chain.lanBase, candidate), phone, { pairing: true })
  pairing.socket.send(`${JSON.stringify({
    v: 1, t: 'pair-commit', id: 'k1', fc: 0,
    box: phoneSealBox({ keys: pairing.keys, header: { t: 'pair-commit', id: 'k1', fc: 0 }, plaintext: JSON.stringify({ v: 2, offerId: offer.offerId, code: offer.code }) }),
  })}\n`)
  await waitFor('配对成功', () => chain.devices.size === 1, 5_000)

  // 正式设备：同样的地址，但**没有** `?pair=`，配对标识换成正式的那一个。
  const pc = deriveIdentity(PC_SEED)
  const identity = deriveIdentity(PHONE_SEED)
  const device = createPhone({
    devId,
    staticSeedHex: identity.dhSeedHex,
    signSeedHex: identity.signSeedHex,
    ephSeedHex: randomBytes(32).toString('hex'),
    nonceA: randomBytes(32).toString('hex'),
    pairingId: pairingIdOf(pairingCodeHash(offer.code)),
    pcSignPubHex: pc.sign.publicKeyHex,
    pcDhPubHex: pc.dh.publicKeyHex,
  })
  const business = await handshake(t, chain.lanBase, device, { pairing: false })
  await waitFor('电脑侧认出这台设备', () => chain.established.includes(devId), 5_000)
  assert.equal(chain.accepted.at(-1)?.pairing, false, '没有 ?pair= 的连接按普通直连建')
  assert.ok(business.lines.length > 0)
})

test('判据是 offer 本身：被新码顶掉的邀请连不上（不是"URL 里有 pair 就放行"）', async (t) => {
  const chain = await startLanChain(t)
  const stale = chain.offer()
  const { candidate, phone } = phoneFor(stale)
  // 重新出码：电脑侧只剩新的一份，旧邀请失效（5 分钟窗口内也一样）。
  chain.offer()

  const socket = new WebSocket(pairingDialUrl(chain.lanBase, candidate))
  t.after(() => socket.terminate())
  const code = await new Promise<number>((resolve, reject) => {
    socket.on('close', (closeCode) => resolve(closeCode))
    socket.on('error', () => reject(new Error('连不上监听面')))
    socket.on('open', () => {
      socket.send(`${JSON.stringify({ v: 1, t: 'hello', id: 'h1', box: phone.helloBox() })}\n`)
    })
  })
  assert.equal(code, 4003, '过期邀请 → protocol/not-paired → 关闭码 4003')
  assert.equal(chain.devices.size, 0, '认不出的候选不能落任何设备行')
})

test('形状不对的候选：不按配对建（留给握手给出 not-paired，而不是悄悄拼一个候选）', async (t) => {
  const chain = await startLanChain(t)
  chain.offer()
  const identity = deriveIdentity(PHONE_SEED)
  const pc = deriveIdentity(PC_SEED)
  const stranger = createPhone({
    devId: 'dev-unknown',
    staticSeedHex: identity.dhSeedHex,
    signSeedHex: identity.signSeedHex,
    ephSeedHex: randomBytes(32).toString('hex'),
    nonceA: randomBytes(32).toString('hex'),
    pairingId: 'AAAAAAAAAAAAAAAAAAAAAA',
    pcSignPubHex: pc.sign.publicKeyHex,
    pcDhPubHex: pc.dh.publicKeyHex,
  })
  const socket = new WebSocket(`${chain.lanBase}/?pair=AAAAAAAAAAAAAAAAAAAAAA&cand=not-a-candidate`)
  t.after(() => socket.terminate())
  const code = await new Promise<number>((resolve, reject) => {
    socket.on('close', (closeCode) => resolve(closeCode))
    socket.on('error', () => reject(new Error('连不上监听面')))
    socket.on('open', () => {
      socket.send(`${JSON.stringify({ v: 1, t: 'hello', id: 'h1', box: stranger.helloBox() })}\n`)
    })
  })
  assert.equal(code, 4003)
  assert.deepEqual(chain.accepted, [{ pairing: false }], '解不出的候选不能当成配对连接')
  assert.equal(chain.devices.size, 0)
})

