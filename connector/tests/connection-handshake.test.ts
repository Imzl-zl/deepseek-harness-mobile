/**
 * 连接级握手的端到端回归（契约 §2.2 + §4.1）。
 *
 * 这是「握手真的跑在连接上」的唯一证据：手机侧替身走**真的 WebSocket**，
 * 电脑侧的握手驱动跑在 `createConnection` 里面。所以下面这几条同时覆盖了三件
 * 单测各自覆盖不到的事：
 *
 * 1. `hello-ack` 能在 `serving` **之前**发出去（连接层只给握手帧开了这条路）；
 * 2. 两道校验都过了连接才进 `serving`，密钥由连接层交给上层；
 * 3. 两侧派生的密钥真的能用 —— 用手机侧的 `kA2B` 封一帧，电脑侧那把必须解得开。
 *
 * 反过来，`confirm` 伪造时连接必须被关掉且**永不**进 `serving`：
 * 少了这条，「握手失败也照样服务」不会让任何别的测试变红。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { deriveIdentity, open, seal, signTranscript, type SessionKeys } from '../src/protocol/crypto.js'
import { createBoxCodec } from '../src/protocol/box.js'
import type { AadFields, WireFrame } from '../src/protocol/frame.js'
import {
  createHandshakeDriver,
  type HandshakeEstablishment,
} from '../src/protocol/handshake-driver.js'
import { encodeConfirm, parseHelloAck, transcriptFromFields } from '../src/protocol/handshake-frames.js'
import { transcriptHashOf } from '../src/protocol/handshake.js'
import { createConnection, type Connection } from '../src/transport/connection.js'
import { startPeer, waitFor, type Peer } from './support/peer.js'
import { createPhone, phoneOpenBox, phoneSealBox, type Phone } from './support/phone.js'

const sha256 = (data: Buffer): Buffer => createHash('sha256').update(data).digest()

/** 固定的 32 字节种子。 */
const seed = (n: number): string => n.toString(16).padStart(2, '0').repeat(32)

const PC_SEED = seed(0xa1)
const PC_ID = 'pc-1'
const PHONE_SEED = seed(0xb2)
const DEV_ID = 'dev-1'
const PAIRING = 'pair-1'

type Cleanup = { after(fn: () => void | Promise<void>): void }

interface Fixture {
  connection: Connection
  peer: Peer
  phone: Phone
  established: HandshakeEstablishment[]
  /** 连接层交给上层的业务帧（握手帧不该出现在这里）。 */
  frames: WireFrame[]
  /** 服务端看到的关闭帧（`code` / `reason`）。 */
  closes: { code: number; reason: string }[]
  /** 在握手阶段就挂上关闭监听 —— 连接被关得很快，晚了就抓不到。 */
  watchClose(): void
}

/**
 * 起对端 + 连接，并注册清理。
 *
 * 清理必须挂在测试上下文上：`waitFor` 超时抛错后，后面的 `stop()` 不会执行，
 * 而连接内部的定时器链会把整个测试进程吊住不退出（表现是"失败了但命令不返回"）。
 */
async function start(t: Cleanup): Promise<Fixture> {
  const pc = deriveIdentity(PC_SEED)
  const phoneIdentity = deriveIdentity(PHONE_SEED)
  const phone = createPhone({
    devId: DEV_ID,
    staticSeedHex: phoneIdentity.dhSeedHex,
    signSeedHex: phoneIdentity.signSeedHex,
    ephSeedHex: seed(0xd4),
    nonceA: seed(0xc3),
    pairingId: PAIRING,
    pcSignPubHex: pc.sign.publicKeyHex,
    pcDhPubHex: pc.dh.publicKeyHex,
  })

  const established: HandshakeEstablishment[] = []
  const frames: WireFrame[] = []
  const closes: { code: number; reason: string }[] = []

  const peer = await startPeer()
  const connection = createConnection({
    url: peer.url,
    dial: (target) => new WebSocket(target) as never,
    secure: {
      handshake: createHandshakeDriver({
        identity: { dh: pc.dh, signSeedHex: pc.signSeedHex },
        pcId: PC_ID,
        peerOf: (devId) =>
          devId === DEV_ID
            ? {
                edPubHex: phoneIdentity.sign.publicKeyHex,
                dhPubHex: phoneIdentity.dh.publicKeyHex,
                pairingId: PAIRING,
              }
            : undefined,
        timeoutMs: 2_000,
      }),
      // 电脑侧 = 应答方：`kA2B` 解入站、`kB2A` 封出站。
      createCipher: (keys) => createBoxCodec({ keys, role: 'responder' }),
    },
    onEstablished: (result) => established.push(result),
    onFrame: (frame) => frames.push(frame),
    heartbeatMs: 5_000,
    batchMs: 30,
  })
  t.after(async () => {
    connection.stop()
    await peer.close()
  })

  return {
    connection,
    peer,
    phone,
    established,
    frames,
    closes,
    watchClose: () => {
      peer.sockets.at(-1)?.on('close', (code: number, reason: Buffer) => {
        closes.push({ code, reason: reason.toString() })
      })
    },
  }
}

/** 手机 → 电脑：`hello`。 */
function sendHello(f: Fixture): void {
  f.peer.send({ v: 1, t: 'hello', id: 'h1', box: f.phone.helloBox() })
}

/** 等电脑侧的 `hello-ack`，顺带断言握手帧的线上形状（§3：没有 `fc`、没有 `sid`）。 */
async function waitHelloAck(f: Fixture): Promise<string> {
  await waitFor('收到 hello-ack', () => f.peer.received.some((frame) => frame.t === 'hello-ack'))
  const frame = f.peer.received.find((candidate) => candidate.t === 'hello-ack')
  assert.ok(frame !== undefined && frame.t === 'hello-ack')
  assert.equal('fc' in frame, false, '握手帧不带 fc')
  assert.equal('sid' in frame, false, '握手帧不挂会话别名')
  return frame.box
}

/** 手机 → 电脑：`confirm`。 */
function sendConfirm(f: Fixture, box: string): void {
  f.peer.send({ v: 1, t: 'confirm', id: 'c1', box })
}

/** 走完三帧，返回手机侧独立派生出来的会话密钥。 */
async function completeHandshake(f: Fixture): Promise<SessionKeys> {
  sendHello(f)
  const accepted = f.phone.acceptAck(await waitHelloAck(f))
  sendConfirm(f, accepted.confirmBox)
  await waitFor('进入 serving', () => f.connection.state === 'serving')
  return accepted.keys
}

test('端到端：走完三帧进入 serving，两侧密钥同一把且真的能用', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')

  sendHello(f)
  const accepted = f.phone.acceptAck(await waitHelloAck(f))
  sendConfirm(f, accepted.confirmBox)

  await waitFor('进入 serving', () => f.connection.state === 'serving')
  assert.equal(f.established.length, 1)
  const keys = f.established[0]!.keys
  assert.equal(f.established[0]!.devId, DEV_ID)
  assert.deepEqual(keys, accepted.keys, '两侧必须派生出同一把会话密钥')

  // ---- 密钥真的能用：手机侧封、电脑侧开（AAD 与 nonce 也一起过一遍）----
  const aad: AadFields = { v: 1, t: 'credit', id: '', sid: '', seq: '', fc: 0 }
  const sealed = seal({ keyHex: accepted.keys.kA2B, fc: 0, aadFields: aad, plaintext: '{"ok":true}' })
  assert.equal(
    open({
      keyHex: keys.kA2B,
      fc: 0,
      aadFields: aad,
      ciphertextHex: sealed.ciphertextHex,
      tagHex: sealed.tagHex,
    }),
    '{"ok":true}',
    '电脑侧用自己派生的 kA2B 必须解得开手机侧封的那一帧',
  )
  // 反方向是另一把密钥：拿 kB2A 去解必须失败（否则"两个方向"就是假的）。
  assert.throws(() =>
    open({
      keyHex: keys.kB2A,
      fc: 0,
      aadFields: aad,
      ciphertextHex: sealed.ciphertextHex,
      tagHex: sealed.tagHex,
    }),
  )

  // ---- 握手帧不占 `fc`：握手后第一帧业务帧必须还是 0 ----
  assert.equal(f.connection.send({ v: 1, t: 'credit', box: '' }), true)
  await waitFor('业务帧到达', () => f.peer.received.some((frame) => frame.t === 'credit'))
  const credit = f.peer.received.find((frame) => frame.t === 'credit')
  assert.ok(credit !== undefined && 'fc' in credit)
  assert.equal(credit.fc, 0, '握手帧不消耗 fc，业务方向仍从 0 开始')
  assert.deepEqual(f.frames, [], '握手帧不该被交给上层')
})

test('端到端：confirm 是伪造的 → 关连接，且永不进 serving', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  f.watchClose()

  sendHello(f)
  const ack = parseHelloAck(await waitHelloAck(f))

  // 攻击者签了**同一段 transcript**，但用的是自己的身份密钥 —— "中继替换公钥"的形状。
  const attacker = deriveIdentity(seed(0xe5))
  const transcript = transcriptFromFields(f.phone.helloFields(), ack)
  sendConfirm(
    f,
    encodeConfirm({
      sigA: signTranscript(attacker.signSeedHex, transcript),
      // 摘要给**对**的值：这样拒绝的原因只可能是验签，而不是顺带被摘要拦下。
      transcriptHash: transcriptHashOf(transcript, sha256),
    }),
  )

  await waitFor('连接被关闭', () => f.closes.length > 0)
  assert.equal(f.closes[0]?.code, 4003, '握手失败用独立的关闭码')
  assert.equal(f.closes[0]?.reason, 'protocol/not-paired')
  assert.equal(f.established.length, 0, '验签没过绝不能进 serving')
  assert.notEqual(f.connection.state, 'serving')
})

test('端到端：配了驱动器也一样，握手期收到业务帧即关闭', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  f.watchClose()

  // 握手帧之外的一切都还在门禁外 —— 驱动器在场不改变这一点。
  f.peer.send({ v: 1, t: 'credit', fc: 0 })
  await waitFor('连接被关闭', () => f.closes.length > 0)
  assert.equal(f.closes[0]?.code, 4002)
  assert.equal(f.closes[0]?.reason, 'protocol/bad-frame')
  assert.equal(f.established.length, 0)
})

test('端到端：没配驱动器时连接停在 handshake，业务帧发不出去', async (t) => {
  const peer = await startPeer()
  const connection = createConnection({
    url: peer.url,
    dial: (target) => new WebSocket(target) as never,
    onFrame: () => {},
    heartbeatMs: 5_000,
    batchMs: 30,
  })
  t.after(async () => {
    connection.stop()
    await peer.close()
  })

  connection.start()
  await waitFor('进入 handshake', () => connection.state === 'handshake')
  assert.equal(connection.send({ v: 1, t: 'credit', box: '' }), false, '握手期业务帧发不出去')
  assert.equal(peer.received.length, 0, '没配驱动器时电脑侧不会主动发握手帧')
})

// ---------------------------------------------------------------------------
// 业务帧的封箱与解封（契约 §3、§4.2）
//
// 手机侧用的是 `support/phone.ts` 里**自己那份**实现（直接拿 node:crypto 拼 nonce 与
// AAD、自己拼 base64url 容器），不 import 产品的 `box.ts`。所以下面每条都在验证
// "两个独立实现能不能对上"，而不只是"我自己和自己对得上"。
// ---------------------------------------------------------------------------

test('端到端：手机封、电脑解 —— 上层拿到的是明文载荷', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  const header = { t: 'req', fc: 0, id: 'req_0123456789ab', sid: 'sid_0123456789ab' }
  f.peer.send({
    v: 1,
    t: 'req',
    id: header.id,
    sid: header.sid,
    fc: header.fc,
    box: phoneSealBox({ keys, header, plaintext: '{"method":"repo.info"}' }),
  })

  await waitFor('上层收到业务帧', () => f.frames.length > 0)
  const got = f.frames[0]
  assert.ok(got !== undefined && got.t === 'req')
  // 上层看到的 `box` 是**明文**：加密只存在于连接层。
  assert.equal(got.box, '{"method":"repo.info"}')
  assert.equal(got.id, header.id)
})

test('端到端：电脑封、手机解 —— 出站帧在线上确实是密文', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  const plaintext = '{"itemId":"m:1:1:assistant","text":"你好"}'
  assert.equal(
    f.connection.send({ v: 1, t: 'ev', sid: 'sid_0123456789ab', seq: 7, box: plaintext }),
    true,
  )
  await waitFor('对端收到 ev', () => f.peer.received.some((frame) => frame.t === 'ev'))

  const ev = f.peer.received.find((frame) => frame.t === 'ev')
  assert.ok(ev !== undefined && ev.t === 'ev')
  // 线上不是明文（否则加密就是摆设）。
  assert.equal(ev.box.includes('你好'), false, '线上不该出现明文')
  // 手机侧用自己的实现解开：AAD 字段序、方向密钥、容器格式三者必须都对得上。
  assert.equal(
    phoneOpenBox({
      keys,
      header: { t: 'ev', fc: ev.fc, sid: ev.sid, seq: ev.seq },
      box: ev.box,
    }),
    plaintext,
  )
})

test('端到端：密文被改一个字符 → 关连接（protocol/bad-frame）', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)
  f.watchClose()

  const header = { t: 'req', fc: 0, id: 'req_0123456789ab' }
  const box = phoneSealBox({ keys, header, plaintext: '{"method":"repo.info"}' })
  const tampered = `${box.slice(0, 5)}${box[5] === 'A' ? 'B' : 'A'}${box.slice(6)}`
  f.peer.send({ v: 1, t: 'req', id: header.id, fc: header.fc, box: tampered })

  await waitFor('连接被关闭', () => f.closes.length > 0)
  assert.equal(f.closes[0]?.code, 4002)
  assert.equal(f.closes[0]?.reason, 'protocol/bad-frame')
  assert.deepEqual(f.frames, [], '被篡改的帧绝不能交给上层')
})

test('端到端：同一帧重放 → 关连接（protocol/replay）', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  const keys = await completeHandshake(f)

  const header = { t: 'req', fc: 0, id: 'req_0123456789ab' }
  const frame = {
    v: 1 as const,
    t: 'req' as const,
    id: header.id,
    fc: header.fc,
    box: phoneSealBox({ keys, header, plaintext: '{"method":"repo.info"}' }),
  }
  f.peer.send(frame)
  await waitFor('第一帧被交给上层', () => f.frames.length === 1)

  f.watchClose()
  f.peer.send(frame)
  await waitFor('连接被关闭', () => f.closes.length > 0)
  assert.equal(f.closes[0]?.reason, 'protocol/replay')
  assert.equal(f.frames.length, 1, '重放的那一帧不该再交给上层')
})

test('端到端：该封箱的帧缺 box → 关连接（不许跳过认证）', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  await completeHandshake(f)
  f.watchClose()

  // 伪造的 `credit` 若被放行，就等于跳过认证与重放守卫直接改状态（§4.3 的发送窗口）。
  f.peer.send({ v: 1, t: 'credit', fc: 0 })
  await waitFor('连接被关闭', () => f.closes.length > 0)
  assert.equal(f.closes[0]?.reason, 'protocol/bad-frame')
  assert.deepEqual(f.frames, [])
})
