/**
 * **带密钥的三方链路**（契约 §4）：手机替身带票连中转 → 握手（真签名与真 transcript）→
 * 发一句（真 AEAD）→ 收一句。
 *
 * 与同文件里那条"明文模式往返"的分工：
 * - 那条证明**路由**两向都对（设备 ⇄ 连接器，明文模式，不看密码学）；
 * - 这条证明**密码学在同一条路上也成立** —— 握手三帧无 `sid`（靠 ticket 绑定路由），
 *   业务帧带 `sid`（靠归属表路由），而两条路都穿过同一个中继进程。
 *
 * 配对流程**故意不走**（`peerOf` 直接给出手机的公钥与 `pairingId`）：配对本身有独立用例，
 * 这里要钉住的是"握手与 AEAD 能不能经中继跑通"。
 */
import assert from 'node:assert/strict'
import { randomBytes } from 'node:crypto'
import { test } from 'node:test'

import { deriveIdentity } from '../src/protocol/crypto.js'
import { createBoxCodec } from '../src/protocol/box.js'
import { createHandshakeDriver } from '../src/protocol/handshake-driver.js'
import { createConnection } from '../src/transport/connection.js'
import { PHONE_SEED, PC_SEED, DEV_ID, PAIRING } from './support/secure-connection.js'
import { createPhone, phoneOpenBox, phoneSealBox } from './support/phone.js'
import { startRelayProcess, waitFor } from './support/relay-process.js'

const TOKEN = 'connector-token-1'
const DEVICE_TOKEN = 'device-token-1'

test(
  '带密钥的三方链路：握手经中继成立，业务帧 AEAD 双向通过',
  async (t) => {
  const relay = await startRelayProcess(t, [
    { kind: 'connector', id: 'conn-1', token: TOKEN },
    { kind: 'device', id: 'dev-1', token: DEVICE_TOKEN },
  ])
  const httpBase = `http://127.0.0.1:${relay.port}`
  const wsBase = `ws://127.0.0.1:${relay.port}`

  const pc = deriveIdentity(PC_SEED)
  const phoneIdentity = deriveIdentity(PHONE_SEED)
  const phone = createPhone({
    devId: DEV_ID,
    staticSeedHex: phoneIdentity.dhSeedHex,
    signSeedHex: phoneIdentity.signSeedHex,
    // 临时种子**每连接换一个**（§4.1）；这里随机取一个新连接的量。
    ephSeedHex: randomBytes(32).toString('hex'),
    nonceA: randomBytes(32).toString('hex'),
    pairingId: PAIRING,
    pcSignPubHex: pc.sign.publicKeyHex,
    pcDhPubHex: pc.dh.publicKeyHex,
  })

  // 连接器侧：真连接层 + 真握手驱动器 + 真密码器。
  const served: { t?: string; sid?: string }[] = []
  let established = 0
  const connection = createConnection({
    url: `${wsBase}/ws/connector`,
    dial: (url) =>
      new WebSocket(url, { headers: { authorization: `Bearer ${TOKEN}` } } as never) as never,
    secure: {
      handshake: createHandshakeDriver({
        identity: { dh: pc.dh, signSeedHex: pc.signSeedHex },
        pcId: 'pc-e2e',
        peerOf: (devId: string) =>
          devId === DEV_ID
            ? {
                edPubHex: phoneIdentity.sign.publicKeyHex,
                dhPubHex: phoneIdentity.dh.publicKeyHex,
                pairingId: PAIRING,
              }
            : undefined,
      }),
      createCipher: (keys) => createBoxCodec({ keys, role: 'responder' }),
    },
    onEstablished: () => {
      established += 1
    },
    onFrame: (frame) => served.push(frame as { t?: string; sid?: string }),
  })
  t.after(() => connection.stop())
  connection.start()
  await waitFor('连接器进入握手态', () => connection.state === 'handshake')

  // 设备换票（真流程：登记 → 换票）
  const codeHash = 'hash-keyed'
  await fetch(`${httpBase}/pairing/register`, {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ codeHash }),
  })
  const ticketed = await fetch(`${httpBase}/ws-ticket`, {
    method: 'POST',
    headers: { authorization: `Bearer ${DEVICE_TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ codeHash }),
  })
  assert.equal(ticketed.status, 201)
  const { ticket } = (await ticketed.json()) as { ticket: string }

  const device = new WebSocket(`${wsBase}/ws/device?ticket=${encodeURIComponent(ticket)}`)
  t.after(() => device.close())
  await new Promise<void>((resolve, reject) => {
    device.onopen = () => resolve()
    device.onerror = () => reject(new Error('设备带票升级失败'))
  })

  // 手机侧：每收到一帧就按握手/业务两条路各自处理（两者都经中继）。
  let keys: Parameters<typeof phoneSealBox>[0]['keys'] | undefined
  const framesBack: { t: string; box: string; fc: number }[] = []
  device.onmessage = (event) => {
    const line = String((event as { data: unknown }).data).trim()
    const frame = JSON.parse(line) as { t: string; id?: string; sid?: string; fc?: number; box: string }
    if (frame.t === 'hello-ack') {
      const ack = phone.acceptAck(frame.box)
      keys = ack.keys
      device.send(`${JSON.stringify({ v: 1, t: 'confirm', id: frame.id ?? 'h1', box: ack.confirmBox })}\n`)
      return
    }
    framesBack.push({ t: frame.t, box: frame.box, fc: frame.fc ?? 0 })
  }

  // 握手第一步：hello（明文帧，无 sid ⇒ 靠 ticket 绑定路由，第 47 轮那条规则）
  device.send(`${JSON.stringify({ v: 1, t: 'hello', id: 'h1', box: phone.helloBox() })}\n`)
  try {
    await waitFor('连接器握手成立', () => established === 1, 8_000)
  } catch (error) {
    // 超时时把中转的输出带出来：它逐条记录"收到/投给谁/丢弃原因"。
    throw new Error(`${String(error)}\n中转输出：\n${relay.output()}`)
  }
  assert.equal(connection.state, 'serving', '握手成立后连接器进入服务态')

  // 业务帧：真 AEAD（手机封、连接器解；连接器封、手机解）。
  // **不带 `sid`**：这正是生产里的形状 —— 请求帧靠"设备→绑定的连接器"走（无 sid 路由），
  // 而 `sid` 由 `params` 携带；带 `sid` 的是**事件帧**（`ev`/`live`），它们由连接器发出，
  // 中继的归属表也正是在那时学到的。
  assert.ok(keys !== undefined)
  const header = { t: 'req', id: 'r1', fc: 1 }
  const sealed = phoneSealBox({ keys, header, plaintext: JSON.stringify({ method: 'session.list' }) })
  device.send(`${JSON.stringify({ v: 1, t: 'req', id: 'r1', fc: 1, box: sealed })}\n`)

  await waitFor('连接器解出业务帧', () => served.some((frame) => frame.t === 'req'), 8_000)
  assert.equal(served.find((frame) => frame.t === 'req')?.t, 'req')

  // 回程：连接器封箱 → 经中继 → 手机解箱（`id` 回显，故无需 `sid` 也能回到发起方）
  assert.equal(
    connection.send({ v: 1, t: 'res', id: 'r1', ok: true, box: JSON.stringify({ ok: true }) }),
    true,
  )
  await waitFor('手机收到应答帧', () => framesBack.some((frame) => frame.t === 'res'), 8_000)
  const reply = framesBack.find((frame) => frame.t === 'res')
  assert.ok(reply !== undefined)
  const opened = phoneOpenBox({
    keys,
    header: { t: 'res', id: 'r1', fc: reply.fc },
    box: reply.box,
  })
  assert.deepEqual(JSON.parse(opened), { ok: true }, 'AEAD 双向成立（手机解开了连接器封的那一箱）')
})
