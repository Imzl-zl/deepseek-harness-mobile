/**
 * 握手驱动（**应答方** / 电脑侧）：把 §4.1 的三条消息走完，并把结论交给连接层。
 *
 * ```text
 * 手机 → 电脑   hello      → 查设备表、生成临时密钥、签 transcript、回 hello-ack
 * 手机 → 电脑   confirm    → 验签 sigA + 比对 transcriptHash → 派生会话密钥
 * ```
 *
 * ## 为什么只有应答方这一半
 *
 * 发起方是**手机**（`hello` 由它发），电脑侧永远只应答 —— 不是"暂时没写另一半"。
 * 所以这里没有 `role` 分支：加一个永远不被走到的 initiator 分支，
 * 只会在将来被误当成"协议支持双向发起"。
 *
 * ## 失败一律是关闭，不是重试
 *
 * §4.1：「握手失败不计入业务重试次数」。所以本文件不重试、不降级、不"先收着"：
 * 任何一步不通过都调 `context.failed()`，由连接层关掉这条连接（随后按退避重连，
 * 而重连会换一套临时密钥与 `fc` 计数器 —— 这正是重试安全的来源）。
 *
 * ## 密钥只在两道校验都过了之后才派生
 *
 * `verifySignature`（对方持有私钥、且签的是这段 transcript）与 `verifyConfirm`
 * （双方拼出的是同一段字节）缺一不可，两道都过才 `deriveSessionKeys`。
 * 顺序不能颠倒：先派生再校验，等于让一个没通过认证的对端参与密钥计算。
 *
 * 契约 §4.1 明写「中继替换公钥无法通过验签」—— 也就是说**端到端加密的抗中间人能力
 * 完全落在这一层**。它写错的表现是：握手照样成功、AEAD 照样能解开，只是不再防中间人。
 *
 * 取舍见 `.agents/notes/implemented/2026-10-01-handshake-on-connection.md`
 */
import { createHash, randomBytes } from 'node:crypto'

import {
  deriveSessionKeys,
  keyPairFrom,
  signTranscript,
  KEY_INFO,
  type KeyPair,
  type SessionKeys,
} from './crypto.js'
import { ProtocolError } from './errors.js'
import { newFrameId, type WireFrame } from './frame.js'
import {
  encodeHelloAck,
  parseConfirm,
  parseHello,
  transcriptFromFields,
  type HelloAckFields,
} from './handshake-frames.js'
import { transcriptHashOf, verifyConfirm, verifySignature } from './handshake.js'

/** 握手超时（契约 §4.1 参数表：10 s）。 */
export const HANDSHAKE_TIMEOUT_MS = 10_000

/** 对端设备在设备表里的三样东西（契约 §8.1）。 */
export interface HandshakePeer {
  /** Ed25519 身份签名公钥：验 `sigA`。 */
  edPubHex: string
  /** X25519 静态 DH 公钥：参与密钥派生。 */
  dhPubHex: string
  /** 配对标识（§12.1）：参与 HKDF 的 `info`，两端必须相同。 */
  pairingId: string
}

export interface HandshakeDriverOptions {
  /** 本端身份（电脑侧）。 */
  identity: {
    /** X25519 静态私钥。 */
    dh: KeyPair
    /** Ed25519 签名种子。 */
    signSeedHex: string
  }
  /** 本端标识：进 `hello-ack` 的 `pcId`，因而参与 transcript。 */
  pcId: string
  /**
   * 按 `devId` 查设备。**未配对、已吊销、查不到一律返回 `undefined`** ——
   * 三种情况对手机是同一件事（`protocol/not-paired` → 回配对页），
   * 在这里区分只会让调用方有机会把"已吊销"写成放行。
   */
  peerOf(devId: string): HandshakePeer | undefined
  /** 握手超时（毫秒）。 */
  timeoutMs?: number
}

/** 握手成功后的产物：交给连接层的上层（方法面要用它对 `box` 做 AEAD）。 */
export interface HandshakeEstablishment {
  /** 对端设备 id（来自 `hello`）。 */
  devId: string
  keys: SessionKeys
}

export interface HandshakeContext {
  /** 握手阶段发一帧。连接层保证这条路径只能出握手帧。 */
  send(frame: WireFrame): void
  /** 三帧走完、密钥已派生。连接层据此进 `serving`。 */
  established(result: HandshakeEstablishment): void
  /**
   * 握手失败。连接层应关闭这条连接。
   *
   * @param reason - 关闭原因（协议错误码，或 `handshake-timeout` 这类本地判定）。
   */
  failed(reason: string, error?: unknown): void
  /** `setTimeout` 语义，返回取消函数。由连接层注入（它已经持有可注入的定时器）。 */
  schedule(fn: () => void, ms: number): () => void
}

export interface HandshakeSession {
  /** 收到一帧握手帧。握手完成后连接层不再往这里投递。 */
  onFrame(frame: WireFrame): void
  /** 连接结束或主动停止：取消在途超时。 */
  dispose(): void
}

/** 每次建连调用一次，得到该连接的握手会话。 */
export type HandshakeDriver = (context: HandshakeContext) => HandshakeSession

const sha256 = (data: Buffer): Buffer => createHash('sha256').update(data).digest()

/** 32 字节随机十六进制（临时密钥种子、`nonceB`）。 */
const randomHex32 = (): string => randomBytes(32).toString('hex')

export function createHandshakeDriver(options: HandshakeDriverOptions): HandshakeDriver {
  const timeoutMs = options.timeoutMs ?? HANDSHAKE_TIMEOUT_MS

  return (context) => {
    let settled = false
    let cancelTimeout: (() => void) | null = null

    /** 收到 `hello` 之后、收到 `confirm` 之前要留住的东西。 */
    let flight: {
      devId: string
      peer: HandshakePeer
      /** 本连接的临时 DH 密钥对，**收到 hello 时才生成**（§4.1：每连接新生成）。 */
      ephemeral: KeyPair
      helloEphPubA: string
      nonceA: string
      nonceB: string
      transcript: Buffer
    } | null = null

    const settle = (): void => {
      settled = true
      cancelTimeout?.()
      cancelTimeout = null
    }

    const fail = (reason: string, error?: unknown): void => {
      if (settled) return
      settle()
      context.failed(reason, error)
    }

    /** `hello` → 回 `hello-ack`。 */
    const acceptHello = (frame: WireFrame & { t: 'hello' }): void => {
      const hello = parseHello(frame.box)
      const peer = options.peerOf(hello.devId)
      if (peer === undefined) {
        // 与"验签不过"同一个码：对手机来说这就是"这一端不是我以为的那一端"。
        throw new ProtocolError('protocol/not-paired', `设备 ${hello.devId} 未配对或已吊销`)
      }

      // 每连接新生成（§4.1）：复用临时密钥会让 fc 从 0 重数 ⇒ nonce 重用 ⇒ 破掉 AEAD。
      const ephemeral = keyPairFrom('x25519', randomHex32())
      const nonceB = randomHex32()
      const ackFields: HelloAckFields = {
        ephPubB: ephemeral.publicKeyHex,
        pcId: options.pcId,
        nonceB,
      }
      // 两侧各拼一遍同一段字节：手机用**它自己发出的 hello 字段** + **收到的 ack 字段**。
      const transcript = transcriptFromFields(hello, ackFields)

      context.send({
        v: 1,
        t: 'hello-ack',
        // **回显请求的 `id`**（不是自己生成一个）：中继只看得见帧头（I10），
        // 而握手帧没有 `sid` —— 回帧要靠这个 `id` 才能被送回发起的那台设备。
        // 各自生成 id 的话，中继在"一台电脑同时服务多台设备"时无法解复用（只能丢弃回帧）。
        // 注意：`id` **不参与 transcript**（`transcriptFromFields` 只拼 box 里的字段），
        // 所以这里不影响签名与既有向量。
        id: frame.id,
        box: encodeHelloAck({ ...ackFields, sigB: signTranscript(options.identity.signSeedHex, transcript) }),
      })

      flight = {
        devId: hello.devId,
        peer,
        ephemeral,
        helloEphPubA: hello.ephPubA,
        nonceA: hello.nonceA,
        nonceB,
        transcript,
      }
    }

    /** `confirm` → 两道校验 → 派生密钥。 */
    const acceptConfirm = (frame: WireFrame & { t: 'confirm' }): void => {
      const current = flight
      if (current === null) {
        // 只有"先 confirm 后 hello"能走到这里（连接层已保证帧类型在握手集合内）。
        throw new ProtocolError('protocol/bad-frame', '还没收到 hello 就收到了 confirm')
      }
      const confirm = parseConfirm(frame.box)

      verifySignature({
        transcript: current.transcript,
        publicKeyHex: current.peer.edPubHex,
        signatureHex: confirm.sigA,
        role: '手机侧',
      })
      verifyConfirm({ transcript: current.transcript, transcriptHash: confirm.transcriptHash, sha256 })

      const keys = deriveSessionKeys({
        // 电脑侧永远是应答方；这个参数错了两侧主密钥就不同（见 `deriveSessionKeys`）。
        role: 'responder',
        ownStaticPrivate: options.identity.dh.privateKey,
        ownEphemeralPrivate: current.ephemeral.privateKey,
        peerStaticPublicHex: current.peer.dhPubHex,
        peerEphemeralPublicHex: current.helloEphPubA,
        nonceA: current.nonceA,
        nonceB: current.nonceB,
        info: KEY_INFO,
        pairingId: current.peer.pairingId,
      })

      settle()
      context.established({ devId: current.devId, keys })
    }

    cancelTimeout = context.schedule(() => {
      // 对端没在时限内把三条消息走完。不发任何协议帧：对端要么已经死了，要么在等我们 ——
      // 两种情况下关掉连接都是唯一有意义的动作。
      fail('handshake-timeout')
    }, timeoutMs)

    return {
      onFrame(frame) {
        if (settled) return
        try {
          if (flight === null) {
            if (frame.t !== 'hello') {
              throw new ProtocolError('protocol/bad-frame', `握手第一步应是 hello，收到 ${frame.t}`)
            }
            acceptHello(frame)
            return
          }
          if (frame.t !== 'confirm') {
            throw new ProtocolError('protocol/bad-frame', `握手第二步应是 confirm，收到 ${frame.t}`)
          }
          acceptConfirm(frame)
        } catch (error) {
          fail(error instanceof ProtocolError ? error.code : 'internal', error)
        }
      },

      dispose() {
        settle()
      },
    }
  }
}
