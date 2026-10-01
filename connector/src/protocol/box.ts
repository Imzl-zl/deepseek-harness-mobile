/**
 * 箱:业务帧的 AEAD 封装与解封（契约 §3、§4.2）。
 *
 * ## 它解决什么
 *
 * 握手只把密钥谈出来;从握手完成到"手机看到一句话"之间,还差**每一帧的封箱与解封**。
 * 契约把这一层划给连接层(§4 的标题就是"握手、密钥、计数器、流控"),所以本文件是
 * **纯函数 + 一个每连接的实例**,由连接层在握手成功时装上。
 *
 * ## 三条不可协商的规则
 *
 * 1. **每一个 `fc` 只封一次箱**。`fc` 就是 nonce(§4.2),同一个 `fc` 封两次即 nonce 重用,
 *    而 nonce 重用会**直接破掉 AEAD**(可恢复明文、可伪造)。分配权在连接层,本文件只
 *    多设一道绊线:单调性被破坏就抛,而不是默默再封一次。
 * 2. **先验签,后推进重放窗口**。窗口只在 AEAD 校验通过后前进 —— 否则未认证的 `fc`
 *    就能替对端"提前"推进窗口,把后续合法帧全判成重放(§4.2)。
 * 3. **方向由角色决定,不由调用方决定**。`kA2B` / `kB2A` 是两条方向的两把密钥,
 *    映射写反了**不会报错**,只会两侧都解不开 —— 所以映射写在协议层一处,
 *    并由"两侧各算一遍"的测试盯着(§4.1 的教训)。
 *
 * ## 控制帧为什么也封箱
 *
 * `ping` / `pong` / `credit` / `persisted` 的载荷是空串,但它们的 `fc` 在 AAD 里。
 * 不认证就等于让未认证的数字驱动重放窗口,也让 `credit`(放宽发送窗口)与
 * `persisted`(允许裁剪增量缓冲)变成中继可伪造的状态变更。代价是 16 字节标签。
 */
import { createReplayGuard, open, seal, type ReplayGuard, type SessionKeys } from './crypto.js'
import { ProtocolError } from './errors.js'
import { aadFieldsOf, type WireFrame } from './frame.js'

/** 认证标签长度（ChaCha20-Poly1305）。 */
export const TAG_BYTES = 16

/**
 * 明文 → 线上箱:`base64url(密文 ‖ tag)`,无填充。
 *
 * 密文长度由总长减 16 得出,所以不需要分隔符。选 base64url 而不是十六进制:
 * 十六进制把载荷体积翻倍,而 8 MiB 单帧上限是按编码后的行算的 —— 翻倍等于砍半预算。
 */
export function packBox(sealed: { ciphertextHex: string; tagHex: string }): string {
  return Buffer.concat([
    Buffer.from(sealed.ciphertextHex, 'hex'),
    Buffer.from(sealed.tagHex, 'hex'),
  ]).toString('base64url')
}

/**
 * 线上箱 → 密文与标签。
 *
 * **严格校验而不是"尽力解码"**:`Buffer.from(x, 'base64url')` 会静默丢弃非法字符,
 * 于是 `"!!!"` 会解出一个空缓冲、再被 AEAD 判成认证失败 —— 错误信息指向"认证失败",
 * 而真正的问题是"这一帧根本不是箱"。所以先查字母表与长度,再查规范化
 * (非规范编码可以有两个字符串对应同一串字节,允许它没有意义)。
 */
export function unpackBox(box: string): { ciphertextHex: string; tagHex: string } {
  if (typeof box !== 'string' || !/^[A-Za-z0-9_-]*$/.test(box)) {
    throw new ProtocolError('protocol/bad-frame', '箱不是 base64url 文本')
  }
  const raw = Buffer.from(box, 'base64url')
  if (raw.length < TAG_BYTES) {
    throw new ProtocolError(
      'protocol/bad-frame',
      `箱只有 ${raw.length} 字节,连认证标签(${TAG_BYTES} 字节)都不够`,
    )
  }
  if (raw.toString('base64url') !== box) {
    // 非规范编码:同一串字节可以有多个字符串表示,放行只会让"两端各写一遍"时对不上账。
    throw new ProtocolError('protocol/bad-frame', '箱不是规范的 base64url(请用无填充编码)')
  }
  const ciphertext = raw.subarray(0, raw.length - TAG_BYTES)
  const tag = raw.subarray(raw.length - TAG_BYTES)
  return { ciphertextHex: ciphertext.toString('hex'), tagHex: tag.toString('hex') }
}

export interface BoxCodec {
  /** 用这一帧的头（含**已分配**的 `fc`）封箱。 */
  sealFrame(frame: WireFrame, plaintext: string): string
  /**
   * 解箱。
   *
   * @throws {ProtocolError} `protocol/bad-frame`（不是箱 / 认证失败）、
   *   `protocol/replay`（`fc` 不单调）。
   */
  openFrame(frame: WireFrame, box: string): string
  /** 已经收到并验证过的最大 `fc`（指标与调试用）。 */
  readonly maxFc: number
}

/** 取 `fc`；没有 `fc` 的帧不该走到这里（握手帧与 `presence` 明文）。 */
function fcOf(frame: WireFrame): number {
  if (!('fc' in frame) || frame.fc === undefined) {
    throw new ProtocolError('protocol/bad-frame', `${frame.t} 帧没有 fc,不该封箱`)
  }
  return frame.fc
}

export interface BoxCodecOptions {
  keys: SessionKeys
  /**
   * 本端角色。`initiator` = 手机 = `A`,`responder` = 电脑 = `B` ——
   * 与 `deriveSessionKeys` 用的是同一套词汇,避免两处各有一套"谁是谁"。
   */
  role: 'initiator' | 'responder'
}

export function createBoxCodec(options: BoxCodecOptions): BoxCodec {
  const { keys, role } = options
  /** 发出去用本端 → 对端那把;收进来用对端 → 本端那把。 */
  const outboundKey = role === 'initiator' ? keys.kA2B : keys.kB2A
  const inboundKey = role === 'initiator' ? keys.kB2A : keys.kA2B

  const guard: ReplayGuard = createReplayGuard()
  /** 上一次封箱用过的 `fc`（nonce 重用的绊线）。 */
  let lastSealedFc = -1

  return {
    get maxFc() {
      return guard.maxFc
    },

    sealFrame(frame, plaintext) {
      const fc = fcOf(frame)
      if (fc <= lastSealedFc) {
        // 走到这里说明有人把同一个 fc 用了两次 —— 那等于重用 nonce,AEAD 直接失效。
        // 正常路径不会发生(分配权在连接层且单调),所以这是绊线而不是校验。
        throw new ProtocolError(
          'internal',
          `fc=${fc} 不大于已封过的 ${lastSealedFc}:拒绝用同一个 nonce 再封一次`,
        )
      }
      const packed = packBox(
        seal({ keyHex: outboundKey, fc, aadFields: aadFieldsOf(frame), plaintext }),
      )
      lastSealedFc = fc
      return packed
    },

    openFrame(frame, box) {
      const fc = fcOf(frame)
      // 便宜的单调性预检:重放/重复投递在这里就出局,**不推进任何状态**。
      // 注意它只读不写 —— 窗口的前进在下面认证通过之后。
      if (fc <= guard.maxFc) {
        throw new ProtocolError('protocol/replay', `fc=${fc} 不大于已见最大 ${guard.maxFc}`)
      }
      const { ciphertextHex, tagHex } = unpackBox(box)
      // 认证失败会抛(可能来自 `crypto.open` 的 auth 失败,也可能来自上面的容器校验)。
      const plaintext = open({ keyHex: inboundKey, fc, aadFields: aadFieldsOf(frame), ciphertextHex, tagHex })
      // **先验后进**:只有走到这里,这个 fc 才算被接受。
      guard.accept(fc)
      return plaintext
    },
  }
}
