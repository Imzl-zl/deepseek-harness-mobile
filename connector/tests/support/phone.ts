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
import { createCipheriv, createDecipheriv, createHash } from 'node:crypto'

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

// ---------------------------------------------------------------------------
// 手机侧的封箱：**独立实现**（刻意不 import `src/protocol/box.ts`）
//
// 这就是"两侧各写一遍"的意义：AAD 字段序、容器格式、方向密钥、nonce 来源这四件事，
// 只要有一件两侧理解不同，这组测试就该红 —— 而它们合起来自洽、分开各测时都不会红
// （本项目已经在这一类错上栽过两次：帧分隔符、DH 角色顺序）。
//
// 于是这里连 `seal`/`open` 都不用：直接用 `node:crypto` 拼 nonce 与 AAD，
// 就像 Dart 侧将来要自己做的那样。
// ---------------------------------------------------------------------------

/** 箱里带的明文头（与线上帧头同形，缺字段即缺席）。 */
export interface PhoneFrameHeader {
  t: string
  fc: number
  id?: string
  sid?: string
  seq?: number
}

/** nonce = `fc` 的 96 位大端（§4.2）。自己拼，不用产品的 `nonceOf`。 */
function phoneNonce(fc: number): Buffer {
  const nonce = Buffer.alloc(12)
  nonce.writeBigUInt64BE(BigInt(fc), 4)
  return nonce
}

/**
 * `setAAD` 的最小结构类型。
 *
 * `@types/node` 把 `chacha20-poly1305` 的 `setAAD` 声明成**必须**带 `{ plaintextLength }`
 * （那只对 CCM / OCB 有意义，Node 文档明说本算法不需要），而解密侧更是填不出这个值。
 * 产品代码 (`src/protocol/crypto.ts`) 有同一处断言，理由一致。
 */
interface AeadCodec {
  setAAD(buffer: NodeJS.ArrayBufferView, options?: unknown): unknown
}

/** AAD = `v|t|id|sid|seq|fc`，缺字段空串（§3）。自己拼串，不经过 `aadOf`。 */
function phoneAad(header: PhoneFrameHeader): Buffer {
  return Buffer.from(
    [1, header.t, header.id ?? '', header.sid ?? '', header.seq ?? '', header.fc].join('|'),
    'utf8',
  )
}

/** 明文 → 箱：`base64url(密文 ‖ tag)`（§3）。 */
export function phoneSealBox(input: {
  keys: SessionKeys
  header: PhoneFrameHeader
  plaintext: string
}): string {
  const cipher = createCipheriv('chacha20-poly1305', Buffer.from(input.keys.kA2B, 'hex'), phoneNonce(input.header.fc), {
    authTagLength: 16,
  })
  ;(cipher as unknown as AeadCodec).setAAD(phoneAad(input.header))
  const body = Buffer.concat([
    cipher.update(Buffer.from(input.plaintext, 'utf8')),
    cipher.final(),
    cipher.getAuthTag(),
  ])
  return body.toString('base64url')
}

/** 箱 → 明文。认证失败即抛（测试据此断言连接被关）。 */
export function phoneOpenBox(input: {
  keys: SessionKeys
  header: PhoneFrameHeader
  box: string
}): string {
  const raw = Buffer.from(input.box, 'base64url')
  const decipher = createDecipheriv(
    'chacha20-poly1305',
    Buffer.from(input.keys.kB2A, 'hex'),
    phoneNonce(input.header.fc),
    { authTagLength: 16 },
  )
  ;(decipher as unknown as AeadCodec).setAAD(phoneAad(input.header))
  decipher.setAuthTag(raw.subarray(raw.length - 16))
  return Buffer.concat([decipher.update(raw.subarray(0, raw.length - 16)), decipher.final()]).toString('utf8')
}

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
