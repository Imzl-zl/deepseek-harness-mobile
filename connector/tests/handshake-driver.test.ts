/**
 * 握手驱动器的回归（契约 §4.1）。
 *
 * 这组测试的价值全在**形状**：它让手机侧替身（`support/phone.ts`）真的跑一遍，
 * 而不是喂给驱动器一个手写的"正确 confirm"。所以下面每一条都至少经过
 * 「电脑侧签 → 手机侧验 → 手机侧签 → 电脑侧验 → 两侧各自派生 → 比对」中的一段。
 *
 * 单侧输入输出的测试在这里是**无效证据**：`transcript` 顺序写反、`role` 传错、
 * 验签被短路，这三种错都不会让"断言该拒"的用例变红 —— 它们只会让真机连不上。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { deriveIdentity, signTranscript } from '../src/protocol/crypto.js'
import type { WireFrame } from '../src/protocol/frame.js'
import {
  createHandshakeDriver,
  type HandshakeDriverOptions,
  type HandshakeEstablishment,
  type HandshakeSession,
} from '../src/protocol/handshake-driver.js'
import { encodeConfirm, parseHelloAck, transcriptFromFields } from '../src/protocol/handshake-frames.js'
import { transcriptHashOf } from '../src/protocol/handshake.js'
import { createPhone, type Phone } from './support/phone.js'

const sha256 = (data: Buffer): Buffer => createHash('sha256').update(data).digest()

/** 固定的 32 字节种子。 */
const seed = (n: number): string => n.toString(16).padStart(2, '0').repeat(32)

const PC_SEED = seed(0xa1)
const PC_ID = 'pc-1'
const PHONE_SEED = seed(0xb2)
const DEV_ID = 'dev-1'
const PAIRING = 'pair-1'
const NONCE_A = seed(0xc3)

interface Harness {
  session: HandshakeSession
  phone: Phone
  /** 电脑侧发出去的帧。 */
  sent: WireFrame[]
  established: HandshakeEstablishment[]
  failures: { reason: string; error?: unknown }[]
  /** 触发注入的超时定时器。 */
  fireTimeout(): void
}

function buildHarness(overrides: Partial<HandshakeDriverOptions> = {}): Harness {
  const pc = deriveIdentity(PC_SEED)
  const phoneIdentity = deriveIdentity(PHONE_SEED)
  const phone = createPhone({
    devId: DEV_ID,
    staticSeedHex: phoneIdentity.dhSeedHex,
    signSeedHex: phoneIdentity.signSeedHex,
    ephSeedHex: seed(0xd4),
    nonceA: NONCE_A,
    pairingId: PAIRING,
    pcSignPubHex: pc.sign.publicKeyHex,
    pcDhPubHex: pc.dh.publicKeyHex,
  })

  const sent: WireFrame[] = []
  const established: HandshakeEstablishment[] = []
  const failures: { reason: string; error?: unknown }[] = []
  let timeout: (() => void) | null = null

  const driver = createHandshakeDriver({
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
    ...overrides,
  })

  const session = driver({
    send: (frame) => sent.push(frame),
    established: (result) => established.push(result),
    failed: (reason, error) => failures.push({ reason, ...(error === undefined ? {} : { error }) }),
    schedule: (fn) => {
      timeout = fn
      return () => {
        timeout = null
      }
    },
  })

  return { session, phone, sent, established, failures, fireTimeout: () => timeout?.() }
}

const helloFrame = (box: string): WireFrame => ({ v: 1, t: 'hello', id: 'h1', box })
const confirmFrame = (box: string): WireFrame => ({ v: 1, t: 'confirm', id: 'c1', box })

type HelloAckFrame = { v: 1; t: 'hello-ack'; id: string; box: string }

function isHelloAck(frame: WireFrame | undefined): frame is HelloAckFrame {
  return frame !== undefined && frame.t === 'hello-ack'
}

/** 取电脑侧最后发出去的那个 `hello-ack` 的 `box`。 */
function ackBoxOf(h: Harness): string {
  const ack = h.sent.at(-1)
  assert.ok(isHelloAck(ack), '电脑侧应回 hello-ack')
  return ack.box
}

/** 走完 hello → hello-ack，返回手机侧算出来的 confirm 与密钥。 */
function exchangeHello(h: Harness): {
  confirmBox: string
  phoneKeys: HandshakeEstablishment['keys']
} {
  h.session.onFrame(helloFrame(h.phone.helloBox()))
  const accepted = h.phone.acceptAck(ackBoxOf(h))
  return { confirmBox: accepted.confirmBox, phoneKeys: accepted.keys }
}

test('三帧走完：两侧各自派生，密钥必须相同', () => {
  const h = buildHarness()
  const { confirmBox, phoneKeys } = exchangeHello(h)
  h.session.onFrame(confirmFrame(confirmBox))

  assert.deepEqual(h.failures, [], '不该有任何失败')
  assert.equal(h.established.length, 1, '应恰好成功一次')
  const result = h.established[0]!
  assert.equal(result.devId, DEV_ID)
  assert.deepEqual(result.keys, phoneKeys, '两侧必须派生出同一把会话密钥')
  assert.notEqual(result.keys.kA2B, result.keys.kB2A, '两个方向必须是两把密钥')
})

test('电脑侧只发 hello-ack，且握手帧的形状里没有 fc / sid', () => {
  const h = buildHarness()
  exchangeHello(h)

  assert.deepEqual(
    h.sent.map((frame) => frame.t),
    ['hello-ack'],
    '握手阶段电脑侧只发一帧',
  )
  assert.equal('fc' in h.sent[0]!, false, '握手帧不带 fc')
  assert.equal('sid' in h.sent[0]!, false, '握手帧不挂会话别名')
})

test('hello-ack 的签名真的能被手机侧用扫码公钥验过，且 pcId 进的是 transcript', () => {
  const h = buildHarness()
  h.session.onFrame(helloFrame(h.phone.helloBox()))
  const box = ackBoxOf(h)

  // `acceptAck` 内部就是"重算 transcript + 用 pcSignPubHex 验签"，它不抛即通过。
  const fields = parseHelloAck(box)
  assert.equal(fields.pcId, PC_ID)
  assert.equal(fields.ephPubB.length, 64)
  assert.equal(fields.sigB.length, 128)

  // pcId 参与 transcript：把它换掉，两侧拼出的字节就不同（真机上表现为验签失败）。
  const transcript = transcriptFromFields(h.phone.helloFields(), fields)
  const withOtherPcId = transcriptFromFields(h.phone.helloFields(), { ...fields, pcId: 'pc-2' })
  assert.notDeepEqual(transcript, withOtherPcId)
  assert.doesNotThrow(() => h.phone.acceptAck(box), '原样的 ack 必须验得过')
})

test('未配对的 devId：一帧都不发，直接 not-paired', () => {
  const h = buildHarness()
  const stranger = createPhone({
    devId: 'dev-unknown',
    staticSeedHex: seed(0xf1),
    signSeedHex: seed(0xf2),
    ephSeedHex: seed(0xf3),
    nonceA: NONCE_A,
    pairingId: PAIRING,
    pcSignPubHex: deriveIdentity(PC_SEED).sign.publicKeyHex,
    pcDhPubHex: deriveIdentity(PC_SEED).dh.publicKeyHex,
  })
  h.session.onFrame(helloFrame(stranger.helloBox()))

  assert.deepEqual(h.sent, [], '对未配对的设备不该发出任何帧')
  assert.equal(h.failures[0]?.reason, 'protocol/not-paired')
  assert.equal(h.established.length, 0)
})

test('confirm 的签名是别人签的：not-paired，且不派生密钥', () => {
  const h = buildHarness()
  const { confirmBox, phoneKeys } = exchangeHello(h)
  assert.ok(phoneKeys.master.length > 0)

  // 攻击者用自己的身份密钥签**同一段 transcript** —— 正是"中继替换公钥"的形状。
  const attacker = deriveIdentity(seed(0xe5))
  const ack = parseHelloAck(ackBoxOf(h))
  const transcript = transcriptFromFields(h.phone.helloFields(), ack)
  const forged = encodeConfirm({
    sigA: signTranscript(attacker.signSeedHex, transcript),
    transcriptHash: transcriptHashOf(transcript, sha256),
  })
  assert.notEqual(forged, confirmBox)

  h.session.onFrame(confirmFrame(forged))
  assert.equal(h.failures[0]?.reason, 'protocol/not-paired')
  assert.equal(h.established.length, 0, '验签没过就绝不能派生密钥')
})

test('confirm 的摘要对不上（双方拼的不是同一段字节）：not-paired', () => {
  const h = buildHarness()
  const { phoneKeys } = exchangeHello(h)

  const ack = parseHelloAck(ackBoxOf(h))
  const transcript = transcriptFromFields(h.phone.helloFields(), ack)
  // 摘要取自另一段 transcript，**但签名对这一段的**：这样验签会过、只有摘要比对失败 ——
  // 否则这条用例会先撞上验签，`verifyConfirm` 根本没被执行到。
  const other = transcriptFromFields(h.phone.helloFields(), { ...ack, pcId: 'pc-2' })
  assert.notDeepEqual(transcript, other)
  const box = encodeConfirm({
    sigA: signTranscript(deriveIdentity(PHONE_SEED).signSeedHex, transcript),
    transcriptHash: transcriptHashOf(other, sha256),
  })
  assert.notEqual(phoneKeys.master, '')

  h.session.onFrame(confirmFrame(box))
  assert.equal(h.failures[0]?.reason, 'protocol/not-paired')
  assert.equal(h.established.length, 0)
})

test('顺序错：先 confirm 后 hello 一律 bad-frame', () => {
  const h = buildHarness()
  h.session.onFrame(confirmFrame('{}'))
  assert.equal(h.failures[0]?.reason, 'protocol/bad-frame')
  assert.equal(h.established.length, 0)
})

test('hello 之后再来一个 hello 也是 bad-frame（第二次握手不由本连接承担）', () => {
  const h = buildHarness()
  exchangeHello(h)
  h.session.onFrame(helloFrame(h.phone.helloBox()))
  assert.equal(h.failures[0]?.reason, 'protocol/bad-frame')
})

test('超时：本地判定，不派生密钥；之后补上的 confirm 也不再生效', () => {
  const h = buildHarness({ timeoutMs: 10 })
  const { confirmBox } = exchangeHello(h)

  h.fireTimeout()
  assert.deepEqual(
    h.failures.map((f) => f.reason),
    ['handshake-timeout'],
    '超时不是协议错误（对端可能已经死了），用本地的判定名',
  )

  h.session.onFrame(confirmFrame(confirmBox))
  assert.equal(h.established.length, 0, '已经收口的会话不该再成功')
})

test('dispose 之后超时不再触发（连接已收，不该再报失败）', () => {
  const h = buildHarness()
  h.session.dispose()
  h.fireTimeout()
  assert.deepEqual(h.failures, [])
})
