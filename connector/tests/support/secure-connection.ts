/**
 * 安全连接夹具：一台**真的**电脑侧连接 + 一个**独立实现**的手机侧替身。
 *
 * 从 `connection-handshake.test.ts` 抽出来，因为握手之外的用例（封箱、流控）要用同一套东西 ——
 * 两份拷贝会各自漂移，而漂移的症状是"只有某一组测试能过"。
 *
 * 三件事在这里一次定义好，测试文件只管自己要断言的行为：
 *
 * 1. **电脑侧真跑 `createConnection`**（含握手驱动器与箱密码器），不是桩；
 * 2. **手机侧走真 WebSocket**，封箱用 `support/phone.ts` 里自己那份实现（不 import 产品代码）；
 * 3. **清理挂在测试上下文上**：`waitFor` 超时抛错后，后面的 `stop()` 不会执行，
 *    而连接内部的定时器链会把测试进程吊住不退出（表现是"失败了但命令不返回"）。
 */
import assert from 'node:assert/strict'

import { createBoxCodec } from '../../src/protocol/box.js'
import { deriveIdentity, type SessionKeys } from '../../src/protocol/crypto.js'
import type { WireFrame } from '../../src/protocol/frame.js'
import {
  createHandshakeDriver,
  type HandshakeEstablishment,
} from '../../src/protocol/handshake-driver.js'
import { createConnection, type Connection } from '../../src/transport/connection.js'
import { startPeer, waitFor, type Peer } from './peer.js'
import { createPhone, type Phone } from './phone.js'

/** 固定的 32 字节种子。 */
export const seed = (n: number): string => n.toString(16).padStart(2, '0').repeat(32)

export const PC_SEED = seed(0xa1)
export const PC_ID = 'pc-1'
export const PHONE_SEED = seed(0xb2)
export const DEV_ID = 'dev-1'
export const PAIRING = 'pair-1'

export type Cleanup = { after(fn: () => void | Promise<void>): void }

export interface Fixture {
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

/** 起对端 + 连接，并注册清理。 */
export async function start(t: Cleanup): Promise<Fixture> {
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
export function sendHello(f: Fixture): void {
  f.peer.send({ v: 1, t: 'hello', id: 'h1', box: f.phone.helloBox() })
}

/** 等电脑侧的 `hello-ack`，顺带断言握手帧的线上形状（§3：没有 `fc`、没有 `sid`）。 */
export async function waitHelloAck(f: Fixture): Promise<string> {
  await waitFor('收到 hello-ack', () => f.peer.received.some((frame) => frame.t === 'hello-ack'))
  const frame = f.peer.received.find((candidate) => candidate.t === 'hello-ack')
  assert.ok(frame !== undefined && frame.t === 'hello-ack')
  assert.equal('fc' in frame, false, '握手帧不带 fc')
  assert.equal('sid' in frame, false, '握手帧不挂会话别名')
  return frame.box
}

/** 手机 → 电脑：`confirm`。 */
export function sendConfirm(f: Fixture, box: string): void {
  f.peer.send({ v: 1, t: 'confirm', id: 'c1', box })
}

/** 走完三帧，返回手机侧独立派生出来的会话密钥。 */
export async function completeHandshake(f: Fixture): Promise<SessionKeys> {
  sendHello(f)
  const accepted = f.phone.acceptAck(await waitHelloAck(f))
  sendConfirm(f, accepted.confirmBox)
  await waitFor('进入 serving', () => f.connection.state === 'serving')
  return accepted.keys
}
