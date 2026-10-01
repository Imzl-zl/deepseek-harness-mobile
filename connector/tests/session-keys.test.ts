/**
 * 双侧密钥协商的回归（契约 §4.1）。
 *
 * 这是**第一次让"两个端点"这件事有测试形状**：手机侧与电脑侧材料不同
 * （各自的私钥 + 对方的公钥），但算出来的三份共享密钥与主密钥必须一致。
 *
 * 有两条只有"真跑两侧"才会暴露的错误，向量测试抓不到（向量的输入是四个种子，
 * 形状决定了它绕开了这两条）：
 *
 * 1. **派生写成"自己的私钥 × 对端的公钥"**。如果某一侧错写成用自己的静态配自己的临时，
 *    两侧就会得到不同的 master。
 * 2. **`ss1||ss2||ss3` 的拼接顺序、以及 `nonceA||nonceB` 的顺序必须两侧一致**。
 *    顺序反了不会报错，只会让两侧派生出一对**互为反向**的密钥 ——
 *    症状是一方发的帧另一方永远解不开。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { deriveSessionKeys, keyPairFrom, publicKeyFrom } from '../src/protocol/crypto.js'

const seed = (n: number): string => n.toString(16).padStart(2, '0').repeat(32)

/** 固定输入；两侧共用。 */
const INPUT = {
  role: 'initiator',
  seedStaticA: seed(0xa1),
  seedStaticB: seed(0xb1),
  seedEphA: seed(0xa2),
  seedEphB: seed(0xb2),
  nonceA: '11'.repeat(32),
  nonceB: '22'.repeat(32),
  info: 'dsh-mobile/v1',
  pairingId: 'pair-1',
} as const

test('双侧派生：材料不同，结果必须相同', () => {
  const staticA = keyPairFrom('x25519', INPUT.seedStaticA)
  const staticB = keyPairFrom('x25519', INPUT.seedStaticB)
  const ephA = keyPairFrom('x25519', INPUT.seedEphA)
  const ephB = keyPairFrom('x25519', INPUT.seedEphB)

  // 手机侧（A）：自己的两把私钥 + 对端（B）的两把公钥。
  const fromA = deriveSessionKeys({
    ownStaticPrivate: staticA.privateKey,
    ownEphemeralPrivate: ephA.privateKey,
    peerStaticPublicHex: staticB.publicKeyHex,
    peerEphemeralPublicHex: ephB.publicKeyHex,
    ...INPUT,
  })

  // 电脑侧（B）：对称地调同一个函数。
  const fromB = deriveSessionKeys({
    ownStaticPrivate: staticB.privateKey,
    ownEphemeralPrivate: ephB.privateKey,
    peerStaticPublicHex: staticA.publicKeyHex,
    peerEphemeralPublicHex: ephA.publicKeyHex,
    ...INPUT,
    role: 'responder',
  })

  assert.deepEqual(fromA, fromB, '两侧必须派生出完全相同的会话密钥')
  assert.equal(fromA.master.length, 128, '主密钥 64 字节的十六进制')
  assert.equal(fromA.kA2B.length, 64, '方向密钥 32 字节')
  // 三个共享密钥互不相同（与向量侧同一条断言，这里在"双侧"形状下再验一次）。
  assert.equal(new Set([fromA.ss1, fromA.ss2, fromA.ss3]).size, 3)
})

test('前向保密：换掉临时密钥，主密钥必须整个变掉', () => {
  const staticA = keyPairFrom('x25519', INPUT.seedStaticA)
  const staticB = keyPairFrom('x25519', INPUT.seedStaticB)
  const ephA = keyPairFrom('x25519', INPUT.seedEphA)

  const derive = (peerEphHex: string) =>
    deriveSessionKeys({
      ownStaticPrivate: staticA.privateKey,
      ownEphemeralPrivate: ephA.privateKey,
      peerStaticPublicHex: staticB.publicKeyHex,
      peerEphemeralPublicHex: peerEphHex,
      ...INPUT,
    })

  const base = derive(keyPairFrom('x25519', INPUT.seedEphB).publicKeyHex)
  const other = derive(keyPairFrom('x25519', seed(0xb3)).publicKeyHex)
  assert.notEqual(base.master, other.master, '换了临时公钥就该派生出不同的密钥')

  // `ss3`（双方临时）是前向保密的来源：它必须参与派生，否则长期种子泄露即可解密历史。
  // 这里用一个可机械检查的推论：只改对端临时公钥，`ss3` 必须跟着变。
  assert.notEqual(base.ss3, other.ss3)
})

test('方向密钥不相等：kA2B 与 kB2A 必须是两把', () => {
  const staticA = keyPairFrom('x25519', INPUT.seedStaticA)
  const staticB = keyPairFrom('x25519', INPUT.seedStaticB)
  const ephA = keyPairFrom('x25519', INPUT.seedEphA)
  const ephB = keyPairFrom('x25519', INPUT.seedEphB)

  const keys = deriveSessionKeys({
    ownStaticPrivate: staticA.privateKey,
    ownEphemeralPrivate: ephA.privateKey,
    peerStaticPublicHex: staticB.publicKeyHex,
    peerEphemeralPublicHex: ephB.publicKeyHex,
    ...INPUT,
  })
  // 两个方向共用一把密钥会让"谁能发"这件事失去约束。
  assert.notEqual(keys.kA2B, keys.kB2A)
})

test('nonce 顺序必须两侧一致，反了会得到不同的主密钥', () => {
  const staticA = keyPairFrom('x25519', INPUT.seedStaticA)
  const staticB = keyPairFrom('x25519', INPUT.seedStaticB)
  const ephA = keyPairFrom('x25519', INPUT.seedEphA)
  const ephB = keyPairFrom('x25519', INPUT.seedEphB)

  const common = {
    role: 'initiator' as const,
    ownStaticPrivate: staticA.privateKey,
    ownEphemeralPrivate: ephA.privateKey,
    peerStaticPublicHex: staticB.publicKeyHex,
    peerEphemeralPublicHex: ephB.publicKeyHex,
    info: INPUT.info,
    pairingId: INPUT.pairingId,
  }
  const normal = deriveSessionKeys({ ...common, nonceA: INPUT.nonceA, nonceB: INPUT.nonceB })
  const swapped = deriveSessionKeys({ ...common, nonceA: INPUT.nonceB, nonceB: INPUT.nonceA })

  // 这条断言在"提醒"：nonce 顺序是协议的一部分，不是实现细节。
  assert.notEqual(normal.master, swapped.master)
})

test('公钥包装：长度不对必须当场抛，而不是留到 diffieHellman', () => {
  assert.throws(() => publicKeyFrom('x25519', 'aabb'), /32 字节/)
  assert.doesNotThrow(() => publicKeyFrom('x25519', seed(0x01)))
  assert.doesNotThrow(() => publicKeyFrom('ed25519', seed(0x01)))
})