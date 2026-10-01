/**
 * 完整握手的回归（契约 §4.1）—— **两个端点真的走完一次**。
 *
 * 把前面几轮造好的零件串起来：三帧组装与 transcript 拼接（`handshake-frames.ts`）、
 * 相互认证与摘要比对（`handshake.ts`）、双侧密钥派生（`crypto.ts`）。
 *
 * 它的价值不在覆盖率，而在**形状**：这是唯一一条会同时走到「两侧各算一遍」、
 * 「签名真验一遍」、「摘要真比一遍」的测试。这三件事上单侧输入输出的测试都是
 * **无效证据** —— 顺序反了、验签被短路、摘要不比对，它们都不会红。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { deriveSessionKeys, keyPairFrom, signTranscript } from '../src/protocol/crypto.js'
import { ProtocolError } from '../src/protocol/errors.js'
import {
  encodeConfirm,
  encodeHello,
  encodeHelloAck,
  parseConfirm,
  parseHello,
  parseHelloAck,
  transcriptFromFields,
} from '../src/protocol/handshake-frames.js'
import { transcriptHashOf, verifyConfirm, verifySignature } from '../src/protocol/handshake.js'

const sha256 = (data: Buffer): Buffer => createHash('sha256').update(data).digest()
const seed = (n: number): string => n.toString(16).padStart(2, '0').repeat(32)

const INFO = 'dsh-mobile/v1'
const PAIRING = 'pair-1'

test('两个端点走完一次完整握手，并派生出同一把会话密钥', () => {
  // 长期密钥 + **每连接新生成**的临时密钥。
  const phoneStatic = keyPairFrom('x25519', seed(0x01))
  const phoneSign = keyPairFrom('ed25519', seed(0x02))
  const phoneEph = keyPairFrom('x25519', seed(0x03))
  const pcStatic = keyPairFrom('x25519', seed(0x11))
  const pcSign = keyPairFrom('ed25519', seed(0x12))
  const pcEph = keyPairFrom('x25519', seed(0x13))

  const nonceA = 'aa'.repeat(32)
  const nonceB = 'bb'.repeat(32)

  // ---- 1. 手机 → 电脑：hello ----
  const helloFields = { ephPubA: phoneEph.publicKeyHex, devId: 'dev-1', nonceA }
  const helloBox = encodeHello(helloFields)

  // ---- 2. 电脑 → 手机：hello-ack（含 sigB）----
  const pcHello = parseHello(helloBox)
  const ackFields = { ephPubB: pcEph.publicKeyHex, pcId: 'pc-1', nonceB }
  // transcript 只拼**除签名外的字段** —— 所以这里没有循环：算完 transcript 再签，
  // 签名进 box 也不影响 transcript。
  const pcTranscript = transcriptFromFields(pcHello, ackFields)
  const sigB = signTranscript(seed(0x12), pcTranscript)
  const helloAckBox = encodeHelloAck({ ...ackFields, sigB })

  // ---- 3. 手机侧：解析并验电脑的签名 ----
  const ack = parseHelloAck(helloAckBox)
  // 手机用**自己发出的 hello 字段** + **收到的 ack 字段**重算 transcript。
  // 这正是修掉循环依赖后的关键：两侧拼的是同一组字段，与 box 的具体字节无关。
  const phoneTranscript = transcriptFromFields(helloFields, ack)
  assert.deepEqual(phoneTranscript, pcTranscript, '两侧必须拼出同一段 transcript')

  assert.doesNotThrow(() =>
    verifySignature({
      transcript: phoneTranscript,
      publicKeyHex: pcSign.publicKeyHex,
      signatureHex: ack.sigB,
      role: '电脑侧',
    }),
  )

  // ---- 4. 手机 → 电脑：confirm ----
  const sigA = signTranscript(seed(0x02), phoneTranscript)
  const confirm = parseConfirm(
    encodeConfirm({ sigA, transcriptHash: transcriptHashOf(phoneTranscript, sha256) }),
  )

  // ---- 5. 电脑侧验签与摘要 ----
  assert.doesNotThrow(() =>
    verifySignature({
      transcript: pcTranscript,
      publicKeyHex: phoneSign.publicKeyHex,
      signatureHex: confirm.sigA,
      role: '手机侧',
    }),
  )
  assert.doesNotThrow(() =>
    verifyConfirm({ transcript: pcTranscript, transcriptHash: confirm.transcriptHash, sha256 }),
  )

  // ---- 6. 两侧各自派生，必须得到同一把 ----
  const phoneKeys = deriveSessionKeys({
    role: 'initiator',
    ownStaticPrivate: phoneStatic.privateKey,
    ownEphemeralPrivate: phoneEph.privateKey,
    peerStaticPublicHex: pcStatic.publicKeyHex,
    peerEphemeralPublicHex: ack.ephPubB,
    nonceA,
    nonceB,
    info: INFO,
    pairingId: PAIRING,
  })
  const pcKeys = deriveSessionKeys({
    role: 'responder',
    ownStaticPrivate: pcStatic.privateKey,
    ownEphemeralPrivate: pcEph.privateKey,
    peerStaticPublicHex: phoneStatic.publicKeyHex,
    peerEphemeralPublicHex: pcHello.ephPubA,
    nonceA,
    nonceB,
    info: INFO,
    pairingId: PAIRING,
  })

  assert.deepEqual(phoneKeys, pcKeys, '两侧必须派生出同一把会话密钥')
  assert.notEqual(phoneKeys.kA2B, phoneKeys.kB2A, '两个方向必须是两把密钥')
})

test('篡改 hello 字段会让签名验不过（transcript 覆盖了它们）', () => {
  const pcSign = keyPairFrom('ed25519', seed(0x12))
  const ackFields = { ephPubB: seed(0x13), pcId: 'pc-1', nonceB: 'bb'.repeat(32) }
  const honest = { ephPubA: seed(0x03), devId: 'dev-1', nonceA: 'aa'.repeat(32) }
  const sigB = signTranscript(seed(0x12), transcriptFromFields(honest, ackFields))

  // 攻击者把 devId 换掉 —— 但 devId 参与了 transcript 拼接，签名随之作废。
  const tampered = { ...honest, devId: 'dev-2' }
  assert.throws(
    () =>
      verifySignature({
        transcript: transcriptFromFields(tampered, ackFields),
        publicKeyHex: pcSign.publicKeyHex,
        signatureHex: sigB,
        role: '电脑侧',
      }),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/not-paired',
  )
})

test('编解码校验对称：坏值在本地就被拦，不留到对端', () => {
  const good = { ephPubA: seed(0x03), devId: 'dev-1', nonceA: 'aa'.repeat(32) }

  // 编与解两侧对同一个坏值都该抛 —— 只校验一侧会让坏值发出去、到对端才炸。
  for (const bad of [
    { ...good, ephPubA: 'ab'.repeat(31) },
    { ...good, devId: 'dev 1' },
    { ...good, nonceA: 'not-hex' },
  ]) {
    assert.throws(() => encodeHello(bad), (e: unknown) => e instanceof ProtocolError)
    assert.throws(
      () => parseHello(encodeHelloForTest(bad)),
      (e: unknown) => e instanceof ProtocolError,
    )
  }

  // 不是 JSON 的 box。
  assert.throws(() => parseHello('not-json'), (e: unknown) => e instanceof ProtocolError)
  // 签名长度不对。
  assert.throws(
    () => encodeHelloAck({ ephPubB: seed(0x13), pcId: 'pc-1', nonceB: 'bb'.repeat(32), sigB: 'dd'.repeat(10) }),
    (e: unknown) => e instanceof ProtocolError,
  )
})

/** 绕过校验直接封箱，用来测 parse 侧的校验（否则 encode 会先拦掉）。 */
function encodeHelloForTest(fields: Record<string, unknown>): string {
  return JSON.stringify(fields)
}
