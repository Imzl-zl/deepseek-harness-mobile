/**
 * 直连监听面的端到端回归（契约 §14.6 的第一跳；设计见 `docs/subsystems/connector-and-relay.md` §1.7）。
 *
 * 这一组用**真 socket**跑，且手机侧走 `support/phone.ts` 那份**独立实现**（不 import 产品代码）——
 * 因为"监听面能接受连接"这件事的全部意义就是"真机能直连"，而桩测不出这一点。
 *
 * 覆盖四件事：
 *
 * 1. **接受来的连接能走完真握手** —— 三帧、真签名、真 transcript、两侧密钥同一把。
 * 2. **两条连接各走各的** —— 每 accept 一条就装配一次；串台的表现是"第二台手机收不到事件"。
 * 3. **卸载时收口** —— 停止接受并关掉已接受的连接（否则插件卸载后还挂着 socket）。
 * 4. **接受来的连接不自愈** —— 它没有拨号目标（`dial` 在这里做成抛错，走了就直接红）。
 *
 * "要不要监听"由装配层按配置判断（`listenPort === 0` 时不调 `startListener`），
 * 所以本文件不测那条分支 —— 它由 `config.ts` 的默认值与 `index.ts` 的 `if` 表达。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createBoxCodec } from '../src/protocol/box.js'
import { deriveIdentity } from '../src/protocol/crypto.js'
import { createHandshakeDriver } from '../src/protocol/handshake-driver.js'
import { createSessionBuffer } from '../src/session-buffer.js'
import { createConnectionScope, type ConnectionScopeDeps } from '../src/connection-scope.js'
import { createConnection, type DialSocket } from '../src/transport/connection.js'
import { startListener } from '../src/transport/listener.js'
import { createMetrics, silentLogger } from '../src/observability.js'
import type { Caps } from '../src/dsh/caps.js'
import { createPhone, phoneOpenBox, phoneSealBox, type Phone } from './support/phone.js'
import { waitFor } from './support/peer.js'
import { DEV_ID, PAIRING, PC_ID, PC_SEED, PHONE_SEED, seed } from './support/secure-connection.js'

const CAPS: Caps = {
  sessions: true,
  storage: true,
  approval: false,
  questions: false,
  jobs: false,
  subagents: false,
  settings: false,
  credentials: true,
}

/** 本套用例不建立订阅；被调到就是装配写错了。 */
const NO_FOLLOW = (): never => {
  throw new Error('本用例不该建立订阅')
}

function makeScopeDeps(): ConnectionScopeDeps {
  return {
    logger: silentLogger,
    metrics: createMetrics(),
    handlers: {
      caps: () => CAPS,
      aliasVersion: () => 0,
      sessions: { list: async () => [], prompt: async () => ({ accepted: true as const }) },
      aliases: { ensure: async () => 's1', sessionOf: () => undefined },
      devices: () => [],
    },
    sessions: {
      list: async () => [],
      follow: NO_FOLLOW,
      page: async () => ({ records: [], hasMore: false }),
      prompt: async () => ({ accepted: true as const }),
      cancel: () => ({ accepted: true as const }),
    },
    buffer: createSessionBuffer({ pairedDevices: () => [] }),
    jobControl: null,
    idempotency: null,
  }
}

interface Accepted {
  connection: ReturnType<typeof createConnection>
  established: { devId: string }[]
  /** 电脑侧真正交给上层（已解箱）的明文载荷。 */
  plaintexts: string[]
}

/**
 * 按 `index.ts` 的装配形状建一条**接受用**的连接。
 *
 * 与产品装配共用同一批零件（握手驱动器 / 箱密码器 / 每连接装配），差别只有 `dial`：
 * 接受来的连接没有拨号目标 —— 这里做成**抛错**，于是"监听模式下桥接莫名其妙连去中转"
 * 会让用例直接红，而不是悄悄发生。
 */
function makeAccepted(deps: ConnectionScopeDeps, pc: ReturnType<typeof deriveIdentity>): Accepted {
  const established: { devId: string }[] = []
  const plaintexts: string[] = []
  let scope: ReturnType<typeof createConnectionScope> | null = null

  const connection = createConnection({
    url: 'ws://127.0.0.1:1/never-dial',
    dial: () => {
      throw new Error('接受来的连接没有拨号目标：不该走到 dial')
    },
    log: silentLogger,
    secure: {
      handshake: createHandshakeDriver({
        identity: { dh: pc.dh, signSeedHex: pc.signSeedHex },
        pcId: PC_ID,
        peerOf: (devId) => {
          if (devId !== DEV_ID) return undefined
          const phone = deriveIdentity(PHONE_SEED)
          return {
            edPubHex: phone.sign.publicKeyHex,
            dhPubHex: phone.dh.publicKeyHex,
            pairingId: PAIRING,
          }
        },
        timeoutMs: 3_000,
      }),
      createCipher: (keys) => createBoxCodec({ keys, role: 'responder' }),
    },
    onEstablished: ({ devId }) => {
      established.push({ devId })
      scope?.deviceEstablished(devId)
    },
    onStateChange: (from, to) => {
      if (from === 'serving' && to !== 'serving') scope?.servingEnded()
    },
    onFrame: (frame) => {
      // 连接层交给上层的 `box` 一律是**明文载荷**（解箱在它内部完成）。
      // 不是每种帧都有 `box`（`presence` 就没有），所以先判在不在。
      if ('box' in frame && typeof frame.box === 'string') plaintexts.push(frame.box)
      scope?.handleFrame(frame)
    },
    heartbeatMs: 5_000,
  })
  scope = createConnectionScope(connection, deps)
  return { connection, established, plaintexts }
}

function phoneFor(nonceA: string, eph: string): Phone {
  const pc = deriveIdentity(PC_SEED)
  const identity = deriveIdentity(PHONE_SEED)
  return createPhone({
    devId: DEV_ID,
    staticSeedHex: identity.dhSeedHex,
    signSeedHex: identity.signSeedHex,
    ephSeedHex: eph,
    nonceA,
    pairingId: PAIRING,
    pcSignPubHex: pc.sign.publicKeyHex,
    pcDhPubHex: pc.dh.publicKeyHex,
  })
}

/** 客户端侧：连上监听面，走完三帧握手。 */
async function handshakeAsPhone(url: string, phone: Phone) {
  const client = new WebSocket(url)
  const lines: string[] = []
  client.onmessage = (event) => {
    const raw = String((event as { data: unknown }).data)
    for (const line of raw.split('\n')) if (line.trim() !== '') lines.push(line)
  }
  await new Promise<void>((resolve, reject) => {
    client.onopen = () => resolve()
    client.onerror = () => reject(new Error(`连不上监听面 ${url}`))
  })

  // **必须补换行**：行级分帧（§3），漏了的表现是"两侧都正常、对端什么都没收到"。
  client.send(`${JSON.stringify({ v: 1, t: 'hello', id: 'h1', box: phone.helloBox() })}\n`)
  await waitFor('收到 hello-ack', () => lines.some((line) => line.includes('"t":"hello-ack"')))
  const ackLine = lines.find((line) => line.includes('"t":"hello-ack"'))!
  assert.equal(ackLine.includes('"fc"'), false, '握手帧不带 fc（§3）')
  const ack = JSON.parse(ackLine) as { box: string }

  const accepted = phone.acceptAck(ack.box)
  client.send(`${JSON.stringify({ v: 1, t: 'confirm', id: 'c1', box: accepted.confirmBox })}\n`)
  return { client, lines, keys: accepted.keys }
}

/** 起一个监听面（系统分配端口），把每条 accept 都记下来。 */
async function startTracking(t: { after(fn: () => void | Promise<void>): void }, deps: ConnectionScopeDeps) {
  const pc = deriveIdentity(PC_SEED)
  const made: Accepted[] = []
  const listener = await startListener({
    port: 0,
    host: '127.0.0.1',
    accept: () => {
      const accepted = makeAccepted(deps, pc)
      made.push(accepted)
      return {
        port: accepted.connection,
        attach: (socket) => accepted.connection.attach(socket as DialSocket),
        stop: () => accepted.connection.stop(),
      }
    },
  })
  t.after(() => listener.close())
  return { listener, made }
}

test('端到端：手机直连监听面 → 真握手 → 两侧密钥同一把 → AEAD 双向', async (t) => {
  const { listener, made } = await startTracking(t, makeScopeDeps())
  const phone = phoneFor(seed(0xc3), seed(0xd4))
  const session = await handshakeAsPhone(`ws://127.0.0.1:${listener.port}`, phone)
  t.after(() => session.client.close())

  await waitFor('电脑侧进入 serving', () => made[0]?.established.length === 1)
  assert.equal(made[0]?.established[0]?.devId, DEV_ID, '接受来的连接也要能认证出设备身份')

  // ---- 手机 → 电脑：真 AEAD 业务帧。电脑侧解箱后把**明文**交给上层（方法面）。 ----
  const request = JSON.stringify({ method: 'repo.info' })
  const sealed = phoneSealBox({
    keys: session.keys,
    header: { t: 'req', fc: 0, id: 'r1' },
    plaintext: request,
  })
  session.client.send(`${JSON.stringify({ v: 1, t: 'req', id: 'r1', fc: 0, box: sealed })}\n`)
  await waitFor('电脑侧解出手机那一帧的明文', () => made[0]?.plaintexts.includes(request) === true)

  // ---- 电脑 → 手机：方法面的 `res` 由电脑侧封箱，手机侧用自己那把密钥解得开 ----
  await waitFor('收到应答', () => session.lines.some((line) => line.includes('"t":"res"')))
  const resLine = session.lines.find((line) => line.includes('"t":"res"'))!
  const res = JSON.parse(resLine) as { fc: number; id: string; ok: boolean; box: string }
  assert.equal(res.id, 'r1', '应答回显请求的 id（手机据此配对请求与应答）')
  const opened = phoneOpenBox({
    keys: session.keys,
    header: { t: 'res', fc: res.fc, id: res.id },
    box: res.box,
  })
  const envelope = JSON.parse(opened) as { ok: boolean; result: Record<string, unknown> }
  // 断言 `repo.info` 真正会回的内容（`handlers.ts:351-357`），不猜形状：
  // 方法面的应答是 `{ ok, result }` 信封，`result` 才是 handler 的返回值。
  assert.equal(envelope.ok, true, '手机解得开电脑侧的箱 —— 两侧密钥同一把')
  assert.equal(envelope.result['protocol'], 1, '内容也对（不只是能解开）')
  assert.deepEqual(envelope.result['caps'], CAPS, '能力位原样回给手机（UI 置灰靠它）')
})

test('两条连接各走各的：每 accept 一条装配一次，帧不串台', async (t) => {
  const { listener, made } = await startTracking(t, makeScopeDeps())

  // 两台设备先后连上（同 devId，但每连接各有一份装配 —— 这正是要验的）。
  const a = await handshakeAsPhone(`ws://127.0.0.1:${listener.port}`, phoneFor(seed(0xc3), seed(0xd4)))
  const b = await handshakeAsPhone(`ws://127.0.0.1:${listener.port}`, phoneFor(seed(0xe5), seed(0xf6)))
  t.after(() => {
    a.client.close()
    b.client.close()
  })

  await waitFor(
    '两条连接都握手完成',
    () => made.length === 2 && made.every((entry) => entry.established.length === 1),
  )
  assert.notEqual(made[0], made[1], '每 accept 一条要**新建**一份装配（共用一份会串台）')
  assert.equal(listener.active, 2)

  // A 发一帧 `ping`（要封箱：§3 只有握手三帧与 `presence` 是明文）。
  // 电脑侧的 `pong` 由**每连接装配**（`connection-scope.handleFrame`）产生 ——
  // 所以它同时证明"这一条连接有自己的 scope"。
  const before = b.lines.length
  const ping = phoneSealBox({ keys: a.keys, header: { t: 'ping', fc: 0 }, plaintext: '' })
  a.client.send(`${JSON.stringify({ v: 1, t: 'ping', fc: 0, box: ping })}\n`)
  await waitFor('A 收到 pong', () => a.lines.some((line) => line.includes('"t":"pong"')))
  assert.equal(b.lines.length, before, 'B 什么都没收到，却收到了 A 的 pong')
})

test('卸载时收口：停止接受并关掉已接受的连接', async (t) => {
  const { listener, made } = await startTracking(t, makeScopeDeps())
  const session = await handshakeAsPhone(`ws://127.0.0.1:${listener.port}`, phoneFor(seed(0xc3), seed(0xd4)))
  await waitFor('握手完成', () => made[0]?.established.length === 1)
  assert.equal(listener.active, 1)

  const closed = new Promise<void>((resolve) => {
    session.client.onclose = () => resolve()
  })
  await listener.close()
  await closed
  assert.equal(listener.active, 0, '卸载后不留活着的连接')
})

test('未配对的设备：握手在 hello 处被拒，连接被关（鉴权就是握手本身）', async (t) => {
  const { listener } = await startTracking(t, makeScopeDeps())

  // 用一个**不在设备表里**的 devId：监听面没有应用层鉴权，唯一的判据就是 §4.1 的握手。
  const stranger = createPhone({
    devId: 'dev-unknown',
    staticSeedHex: deriveIdentity(PHONE_SEED).dhSeedHex,
    signSeedHex: deriveIdentity(PHONE_SEED).signSeedHex,
    ephSeedHex: seed(0xd4),
    nonceA: seed(0xc3),
    pairingId: PAIRING,
    pcSignPubHex: deriveIdentity(PC_SEED).sign.publicKeyHex,
    pcDhPubHex: deriveIdentity(PC_SEED).dh.publicKeyHex,
  })

  const client = new WebSocket(`ws://127.0.0.1:${listener.port}`)
  t.after(() => client.close())
  const closed = new Promise<number>((resolve) => {
    client.onclose = (event) => resolve((event as { code: number }).code)
  })
  await new Promise<void>((resolve, reject) => {
    client.onopen = () => resolve()
    client.onerror = () => reject(new Error('连不上监听面'))
  })
  client.send(`${JSON.stringify({ v: 1, t: 'hello', id: 'h1', box: stranger.helloBox() })}\n`)

  const code = await closed
  assert.equal(code, 4003, '未配对 → protocol/not-paired → 关闭码 4003（§4.1）')
})
