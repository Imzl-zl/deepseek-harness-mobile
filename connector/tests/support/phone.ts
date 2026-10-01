/**
 * 手机侧的**独立**替身（握手发起方）。
 *
 * 它存在的唯一理由：凡「两侧各算一遍」的协议，只测一侧是**无效证据**。
 * 所以这里刻意不碰 `handshake-driver.ts` 的任何代码 —— 按契约 §4.1 的话重写一遍：
 *
 * ```text
 * 1. 发 hello { ephPubA, devId, nonceA }
 * 2. 收到 hello-ack：用**自己发出的 hello 字段** + **收到的 ack 字段**重算 transcript，
 *    再用扫码得到的电脑侧公钥验 sigB
 * 3. 派生会话密钥（role = initiator）→ 发 confirm { sigA, transcriptHash }
 * ```
 *
 * 它同时被两组测试用：进程内的驱动器单测、以及走真 WebSocket 的连接级 e2e。
 * 两侧的角色名（`initiator` / `responder`）与材料顺序不同，这正是它要跑真一遍的原因。
 */
import { createHash } from 'node:crypto'

import {
  deriveSessionKeys,
  keyPairFrom,
  signTranscript,
  KEY_INFO,
  type SessionKeys,
} from '../../src/protocol/crypto.js'
import { encodeConfirm, encodeHello, parseHelloAck, transcriptFromFields } from '../../src/protocol/handshake-frames.js'
import { transcriptHashOf, verifySignature } from '../../src/protocol/handshake.js'

const sha256 = (data: Buffer): Buffer => createHash('sha256').update(data).digest()

export interface PhoneOptions {
  devId: string
  /** 手机静态 DH 种子。 */
  staticSeedHex: string
  /** 手机 Ed25519 身份种子。 */
  signSeedHex: string
  /** 手机临时种子（**每连接换一个**，契约 §4.1）。 */
  ephSeedHex: string
  nonceA: string
  pairingId: string
  /** 电脑侧的 Ed25519 公钥 —— 手机"只信任二维码带出的电脑公钥"（§12.1）。 */
  pcSignPubHex: string
  /** 电脑侧的 X25519 静态公钥。 */
  pcDhPubHex: string
  info?: string
}

export interface Phone {
  /** 第一条消息的 `box`。 */
  helloBox(): string
  /**
   * 手机侧发出的 hello 字段。
   *
   * 暴露它，是为了让测试能独立重算 transcript（比如构造"签名合法但摘要来自另一段字节"的
   * 负向用例）—— 这是测试替身该给的观察面，不是产品 API。
   */
  helloFields(): { ephPubA: string; devId: string; nonceA: string }
  /**
   * 收到 `hello-ack` 之后要做的事。
   *
   * @returns `confirmBox` 与**手机侧独立派生**出来的密钥（用来和电脑侧比对）。
   */
  acceptAck(ackBox: string): { confirmBox: string; keys: SessionKeys }
}

export function createPhone(options: PhoneOptions): Phone {
  const staticKeys = keyPairFrom('x25519', options.staticSeedHex)
  const ephemeralKeys = keyPairFrom('x25519', options.ephSeedHex)
  const helloFields = {
    ephPubA: ephemeralKeys.publicKeyHex,
    devId: options.devId,
    nonceA: options.nonceA,
  }

  return {
    helloBox: () => encodeHello(helloFields),
    helloFields: () => ({ ...helloFields }),

    acceptAck(ackBox) {
      const ack = parseHelloAck(ackBox)
      const transcript = transcriptFromFields(helloFields, ack)

      // 验电脑侧的签名：这是"中继替换公钥"唯一的落点（§4.1）。验不过就抛，测试据此断言。
      verifySignature({
        transcript,
        publicKeyHex: options.pcSignPubHex,
        signatureHex: ack.sigB,
        role: '电脑侧',
      })

      const keys = deriveSessionKeys({
        role: 'initiator',
        ownStaticPrivate: staticKeys.privateKey,
        ownEphemeralPrivate: ephemeralKeys.privateKey,
        peerStaticPublicHex: options.pcDhPubHex,
        peerEphemeralPublicHex: ack.ephPubB,
        nonceA: options.nonceA,
        nonceB: ack.nonceB,
        info: options.info ?? KEY_INFO,
        pairingId: options.pairingId,
      })

      return {
        confirmBox: encodeConfirm({
          sigA: signTranscript(options.signSeedHex, transcript),
          transcriptHash: transcriptHashOf(transcript, sha256),
        }),
        keys,
      }
    },
  }
}
