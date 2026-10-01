/**
 * 握手校验的回归（契约 §4.1）。
 *
 * 这组测试的存在理由：**校验写错不会让任何东西看起来坏掉** —— 握手照样成功、
 * AEAD 照样能解开，只是不再防中间人。所以这里必须主动构造"被换过公钥/签过别的串"
 * 的情形，证明它真的会拒。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { ProtocolError } from '../src/protocol/errors.js'
import { CONFIRM_HASH_BYTES, transcriptHashOf, verifyConfirm, verifySignature } from '../src/protocol/handshake.js'
import { keyPairFrom, signTranscript, transcriptOf } from '../src/protocol/crypto.js'

const sha256 = (data: Buffer): Buffer => createHash('sha256').update(data).digest()

/** 固定的 32 字节种子。 */
const seed = (n: number): string => n.toString(16).padStart(2, '0').repeat(32)

const transcript = (): Buffer =>
  transcriptOf({
    info: 'dsh-mobile/v1',
    pairingId: 'pair-1',
    helloBox: 'hello-box-bytes',
    helloAckBox: 'hello-ack-box-bytes',
  })

test('验签：正确的签名通过', () => {
  const signer = keyPairFrom('ed25519', seed(0x11))
  const sig = signTranscript(seed(0x11), transcript())
  assert.doesNotThrow(() =>
    verifySignature({
      transcript: transcript(),
      publicKeyHex: signer.publicKeyHex,
      signatureHex: sig,
      role: '电脑侧',
    }),
  )
})

test('验签：被换过公钥即拒，且错误码是 protocol/not-paired', () => {
  // 攻击者用**自己的**私钥签同一段 transcript，然后把公钥也换成自己的 ——
  // 这正是"中继替换公钥"的形状。
  const attacker = keyPairFrom('ed25519', seed(0x22))
  const attackerSig = signTranscript(seed(0x22), transcript())

  // 攻击者自签自验当然通过（它内部一致）。
  assert.doesNotThrow(() =>
    verifySignature({
      transcript: transcript(),
      publicKeyHex: attacker.publicKeyHex,
      signatureHex: attackerSig,
      role: '电脑侧',
    }),
  )

  // 但拿**真**电脑侧的公钥去验攻击者的签名，必须失败。
  const real = keyPairFrom('ed25519', seed(0x11))
  assert.throws(
    () =>
      verifySignature({
        transcript: transcript(),
        publicKeyHex: real.publicKeyHex,
        signatureHex: attackerSig,
        role: '电脑侧',
      }),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/not-paired',
  )
})

test('验签：签的是别的 transcript 也拒', () => {
  const signer = keyPairFrom('ed25519', seed(0x11))
  const otherTranscript = transcriptOf({
    info: 'dsh-mobile/v1',
    pairingId: 'pair-1',
    helloBox: 'tampered',
    helloAckBox: 'hello-ack-box-bytes',
  })
  const sig = signTranscript(seed(0x11), otherTranscript)

  // hello 帧被改过一个字节 → 签名对不上。
  assert.throws(
    () =>
      verifySignature({
        transcript: transcript(),
        publicKeyHex: signer.publicKeyHex,
        signatureHex: sig,
        role: '电脑侧',
      }),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/not-paired',
  )
})

test('验签：公钥长度不对也归到 not-paired，不暴露内部分支', () => {
  assert.throws(
    () =>
      verifySignature({
        transcript: transcript(),
        publicKeyHex: 'aabb',
        signatureHex: '00'.repeat(64),
        role: '电脑侧',
      }),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/not-paired',
  )
})

test('confirm：摘要取前 8 字节，匹配则通过', () => {
  const hash = transcriptHashOf(transcript(), sha256)
  assert.equal(hash.length, CONFIRM_HASH_BYTES * 2, '十六进制长度应为 16')
  assert.equal(hash, sha256(transcript()).subarray(0, CONFIRM_HASH_BYTES).toString('hex'))

  assert.doesNotThrow(() => verifyConfirm({ transcript: transcript(), transcriptHash: hash, sha256 }))
})

test('confirm：摘要在就一个字节也对不上', () => {
  const hash = transcriptHashOf(transcript(), sha256)
  const tampered = (hash[0] === '0' ? '1' : '0') + hash.slice(1)
  assert.notEqual(tampered, hash)
  assert.throws(
    () => verifyConfirm({ transcript: transcript(), transcriptHash: tampered, sha256 }),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/not-paired',
  )
})

test('confirm：transcript 本身不同（哪怕签名都合法）也要被拦', () => {
  // 这是 confirm 存在的理由：签名只能证明"对方持有私钥"，
  // 不能证明"我们签的是同一段字节"。
  const mine = transcript()
  const theirs = transcriptOf({
    info: 'dsh-mobile/v1',
    pairingId: 'pair-1',
    helloBox: 'hello-box-bytes',
    helloAckBox: 'different-ack',
  })
  const theirHash = transcriptHashOf(theirs, sha256)
  assert.throws(
    () => verifyConfirm({ transcript: mine, transcriptHash: theirHash, sha256 }),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/not-paired',
  )
})
