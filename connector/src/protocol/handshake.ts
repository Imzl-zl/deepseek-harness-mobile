/**
 * 握手的**校验**一半（契约 §4.1）。
 *
 * 这一半是安全关键的：§4.1 写着「**相互认证**：双方都要验签对方的临时公钥；验签失败即
 * `protocol/not-paired` 并断开。**中继替换公钥无法通过验签**」。也就是说，端到端加密的
 * 抗中间人能力**完全落在这两个校验上** —— 少了它们，中转可以各自和两端握手，
 * 而两端的 AEAD 都"正常工作"。
 *
 * 所以本文件的失败一律是 `protocol/not-paired`（而不是 `internal` 或 `bad-frame`）：
 * 手机端要靠这个码决定「清除本地凭据，回到配对页」（契约 §3.1）。
 *
 * 另一半（派生与发帧）在 `crypto.ts`；这里只做**校验**，因为校验写错不会让任何东西
 * 看起来坏掉 —— 握手照样成功，只是不再防中间人。
 */
import { createPublicKey, verify as nodeVerify } from 'node:crypto'

import { ProtocolError } from './errors.js'

/** `confirm` 里带的 transcript 摘要长度：前 8 字节（契约 §4.1）。 */
export const CONFIRM_HASH_BYTES = 8

/** Ed25519 原始公钥（32 字节）的 SPKI 前缀。 */
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex')

/**
 * `transcriptHash` = SHA-256(transcript) 的前 {@link CONFIRM_HASH_BYTES} 字节，十六进制。
 *
 * 取 8 字节不是为了密码学强度，而是让「双方的 transcript 是不是同一个」这件事
 * 有一个便宜的比对值 —— 真正的认证由两个签名承担。
 */
export function transcriptHashOf(transcript: Buffer, sha256: (data: Buffer) => Buffer): string {
  return sha256(transcript).subarray(0, CONFIRM_HASH_BYTES).toString('hex')
}

export interface VerifySignatureInput {
  /** 被签的规范串（`crypto.ts` 的 `transcriptOf`）。 */
  transcript: Buffer
  /** 32 字节原始 Ed25519 公钥的十六进制。 */
  publicKeyHex: string
  /** 64 字节签名的十六进制。 */
  signatureHex: string
  /** 出错信息里标明是谁的签名，便于排查是哪一侧被换了公钥。 */
  role: string
}

/**
 * 验证对方对 transcript 的签名。
 *
 * 任何失败（公钥长度不对、签名格式不对、验签不通过）都抛 `protocol/not-paired` ——
 * 对手机端来说这些是同一件事：**这一端不是我以为的那一端**，该回配对页。
 */
export function verifySignature(input: VerifySignatureInput): void {
  const publicKey = Buffer.from(input.publicKeyHex, 'hex')
  if (publicKey.length !== 32) {
    throw new ProtocolError(
      'protocol/not-paired',
      `${input.role} 的 Ed25519 公钥应为 32 字节，收到 ${publicKey.length}`,
    )
  }
  const signature = Buffer.from(input.signatureHex, 'hex')

  let ok = false
  try {
    const key = createPublicKey({
      key: Buffer.concat([ED25519_SPKI_PREFIX, publicKey]),
      format: 'der',
      type: 'spki',
    })
    ok = nodeVerify(null, input.transcript, key, signature)
  } catch (error) {
    // 构造公钥失败也归到"不是我以为的那一端"，不暴露内部分支。
    throw new ProtocolError('protocol/not-paired', `${input.role} 验签无法进行：${String(error)}`)
  }

  if (!ok) {
    throw new ProtocolError(
      'protocol/not-paired',
      `${input.role} 的签名对不上 transcript（中继可能替换了公钥）`,
    )
  }
}

export interface VerifyConfirmInput {
  transcript: Buffer
  /** `confirm` 帧里带的 `transcriptHash[0..8)`。 */
  transcriptHash: string
  sha256: (data: Buffer) => Buffer
}

/**
 * 校验 `confirm` 里的 transcript 摘要。
 *
 * 它防的是「双方各自算出了不同的 transcript 却都没发现」—— 单靠签名验不过这一关，
 * 因为签名只能证明"对方持有私钥"，不能证明"我们签的是同一段字节"。
 */
export function verifyConfirm(input: VerifyConfirmInput): void {
  const expected = transcriptHashOf(input.transcript, input.sha256)
  if (input.transcriptHash !== expected) {
    throw new ProtocolError(
      'protocol/not-paired',
      `confirm 的 transcriptHash 不匹配（期望 ${expected}，收到 ${input.transcriptHash}）`,
    )
  }
}
