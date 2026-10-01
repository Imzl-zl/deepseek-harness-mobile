/**
 * 箱层的回归（契约 §3、§4.2）。
 *
 * 这一层值得单独一组测试，因为它同时承担三件"错了不会报错、只会静默失效"的事：
 *
 * 1. **方向密钥映射**（`kA2B` / `kB2A`）：写反了两侧都解不开，而单侧往返测试照样绿；
 * 2. **AAD 绑定**：字段少绑一个，攻击者就能改那个字段而认证照样通过；
 * 3. **重放窗口的顺序**：只有"先验签、后推进"才拦得住"用未认证的 `fc` 把窗口推高"
 *    —— 这条错了的表现是**连接被自己人反复关闭**。
 *
 * 所以下面每一条都主动构造"该拒"的形状，而不是只跑一遍正确路径。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createBoxCodec, packBox, unpackBox, TAG_BYTES } from '../src/protocol/box.js'
import { deriveSessionKeys, keyPairFrom, type SessionKeys } from '../src/protocol/crypto.js'
import { ProtocolError } from '../src/protocol/errors.js'
import type { WireFrame } from '../src/protocol/frame.js'

/** 固定的 32 字节种子。 */
const seed = (n: number): string => n.toString(16).padStart(2, '0').repeat(32)

/** 两侧各自派生一次，得到同一把会话密钥（与 §4.1 的用法一致）。 */
function sessionKeys(): SessionKeys {
  return deriveSessionKeys({
    role: 'responder',
    ownStaticPrivate: keyPairFrom('x25519', seed(0x11)).privateKey,
    ownEphemeralPrivate: keyPairFrom('x25519', seed(0x13)).privateKey,
    peerStaticPublicHex: keyPairFrom('x25519', seed(0x01)).publicKeyHex,
    peerEphemeralPublicHex: keyPairFrom('x25519', seed(0x03)).publicKeyHex,
    nonceA: seed(0xa1),
    nonceB: seed(0xb2),
    info: 'dsh-mobile/v1/keys',
    pairingId: 'pair-1',
  })
}

const evFrame = (fc: number, seq = 1): WireFrame => ({
  v: 1,
  t: 'ev',
  sid: 'sid_0123456789ab',
  seq,
  fc,
  box: '',
})

const pingFrame = (fc: number): WireFrame => ({ v: 1, t: 'ping', fc, box: '' })

test('容器：往返一致，且坏编码在本地就被拦住', () => {
  const sealed = { ciphertextHex: 'aabbcc', tagHex: 'dd'.repeat(16) }
  const box = packBox(sealed)
  // 密文 3 字节 + tag 16 字节 = 19 字节 → base64url 26 字符（无填充）。
  assert.equal(box.length, 26)
  assert.deepEqual(unpackBox(box), sealed)

  // 空密文也合法（控制帧就是空载荷）。
  const empty = packBox({ ciphertextHex: '', tagHex: 'ee'.repeat(16) })
  assert.deepEqual(unpackBox(empty), { ciphertextHex: '', tagHex: 'ee'.repeat(16) })

  for (const bad of [
    'not base64!', // 字母表
    '', // 连标签都不够
    'AAAA', // 3 字节 < 16
    `${box}=`, // 带填充:非规范编码
  ]) {
    assert.throws(
      () => unpackBox(bad),
      (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/bad-frame',
      `${JSON.stringify(bad)} 应被拒`,
    )
  }
})

test('封箱：两个方向各自可解，交叉解必失败（方向映射写反就会红）', () => {
  const keys = sessionKeys()
  const pc = createBoxCodec({ keys, role: 'responder' })
  const phone = createBoxCodec({ keys, role: 'initiator' })

  const fromPc = pc.sealFrame(evFrame(0), '{"text":"电脑说的"}')
  const fromPhone = phone.sealFrame(evFrame(0), '{"text":"手机说的"}')

  // 各自的入站侧能解（`kA2B` / `kB2A` 用对了）。
  assert.equal(phone.openFrame(evFrame(0), fromPc), '{"text":"电脑说的"}')
  assert.equal(pc.openFrame(evFrame(0), fromPhone), '{"text":"手机说的"}')

  // 拿自己发出去的那把去解自己的出站帧：方向反了，必须失败。
  const other = createBoxCodec({ keys, role: 'responder' })
  assert.throws(() => other.openFrame(evFrame(0), fromPc))
})

test('封箱：同一帧内容用不同 fc 封，密文必不同（nonce 在起作用）', () => {
  const keys = sessionKeys()
  const pc = createBoxCodec({ keys, role: 'responder' })
  assert.notEqual(pc.sealFrame(evFrame(0), 'same'), pc.sealFrame(evFrame(1), 'same'))
})

test('AAD 绑定：改动帧头任一参与字段都必须解不开', () => {
  const keys = sessionKeys()
  const pc = createBoxCodec({ keys, role: 'responder' })
  const box = pc.sealFrame(evFrame(0, 1), 'payload')

  // 逐字段改，每一个都必须让认证失败 —— 少绑一个字段就等于那个字段可被中继篡改。
  for (const tampered of [
    evFrame(0, 2), // seq
    { ...evFrame(0, 1), sid: 'sid_ffffffffffff' }, // sid
    { ...evFrame(0, 1), t: 'live' } as WireFrame, // 帧类型
    { ...evFrame(0, 1), v: 2 } as unknown as WireFrame, // 版本
  ]) {
    const fresh = createBoxCodec({ keys, role: 'responder' })
    assert.throws(
      () => fresh.openFrame(tampered, box),
      (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/bad-frame',
      `${JSON.stringify(tampered)} 被篡改后仍解开了`,
    )
  }

  // 密文本身被改一个字符也必须失败。
  const flipped = `${box.slice(0, 3)}${box[3] === 'A' ? 'B' : 'A'}${box.slice(4)}`
  assert.throws(() => pc.openFrame(evFrame(0, 1), flipped))
})

test('控制帧：空载荷也要封箱，且能原样解出空串', () => {
  const keys = sessionKeys()
  const pc = createBoxCodec({ keys, role: 'responder' })
  const phone = createBoxCodec({ keys, role: 'initiator' })

  // ping 的 `fc` 在 AAD 里 —— 这正是"控制帧也要认证"的理由：不认证就等于让
  // 未认证的数字驱动重放窗口。
  const ping = pc.sealFrame(pingFrame(0), '')
  assert.equal(phone.openFrame(pingFrame(0), ping), '')
  assert.equal(phone.maxFc, 0, '控制帧同样推进窗口')
})

test('先验后进：伪造的 fc 推不动重放窗口', () => {
  const keys = sessionKeys()
  const pc = createBoxCodec({ keys, role: 'responder' })
  const phone = createBoxCodec({ keys, role: 'initiator' })

  // 攻击者造一个"未来的" fc 想替对端把窗口推高（推高之后所有合法帧都会被判重放）。
  const forged = packBox({ ciphertextHex: 'ff'.repeat(8), tagHex: '00'.repeat(16) })
  assert.throws(
    () => pc.openFrame(evFrame(9999), forged),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/bad-frame',
  )
  assert.equal(pc.maxFc, -1, '认证没过就绝不能推进窗口')

  // 于是紧跟着的合法帧必须照常解开 —— 这正是"先验后进"要保的东西。
  assert.equal(pc.openFrame(evFrame(0), phone.sealFrame(evFrame(0), 'ok')), 'ok')
  assert.equal(pc.maxFc, 0)
})

test('重放：同一个 fc 再来一次是 protocol/replay（不是 bad-frame）', () => {
  const keys = sessionKeys()
  const pc = createBoxCodec({ keys, role: 'responder' })
  const phone = createBoxCodec({ keys, role: 'initiator' })

  const box = phone.sealFrame(evFrame(0), 'once')
  assert.equal(pc.openFrame(evFrame(0), box), 'once')
  assert.throws(
    () => pc.openFrame(evFrame(0), box),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/replay',
  )

  // 窗口只认严格递增：跳号可以（中间那些帧可能走的是别的方向），回退不行。
  assert.equal(pc.openFrame(evFrame(5), phone.sealFrame(evFrame(5), 'later')), 'later')
  // 回退的帧要用**另一个封箱器**造：同一个封箱器不许回头再封一个更小的 fc（nonce 绊线）。
  const otherPhone = createBoxCodec({ keys, role: 'initiator' })
  assert.throws(
    () => pc.openFrame(evFrame(4), otherPhone.sealFrame(evFrame(4), 'earlier')),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/replay',
  )
})

test('nonce 绊线：同一个 fc 想封第二次就直接吵', () => {
  const keys = sessionKeys()
  const pc = createBoxCodec({ keys, role: 'responder' })
  pc.sealFrame(evFrame(3), 'first')

  // 重用 nonce 会直接破掉 AEAD，而症状是"内容能被恢复"这种最难发现的事 ——
  // 所以分配权虽然在连接层，这一层也要有绊线。
  assert.throws(
    () => pc.sealFrame(evFrame(3), 'second'),
    (e: unknown) => e instanceof ProtocolError && String(e.message).includes('nonce'),
  )
  assert.throws(() => pc.sealFrame(evFrame(2), 'older'))
})

test('没有 fc 的帧不该封箱（presence 是明文，握手帧在别处）', () => {
  const keys = sessionKeys()
  const pc = createBoxCodec({ keys, role: 'responder' })
  assert.throws(
    () => pc.sealFrame({ v: 1, t: 'presence', computer: 'online' } as WireFrame, ''),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/bad-frame',
  )
  assert.equal(TAG_BYTES, 16)
})
