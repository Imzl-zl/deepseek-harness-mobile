/**
 * 出码入口的回归（契约 §12.1 第 1 步）。
 *
 * 三条用例，盯住的是**顺序**与**失败时的行为**（它们都不会报错，只会让人排查错方向）：
 * 登记成功才给码；登记失败**不给码**；登记用的 `codeHash` 必须与码同源。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { PAIRING_TTL_MS, createPairing, pairingCodeHash } from '../src/pairing.js'
import { offerForScanning, issuePairingOffer } from '../src/pairing-offer.js'
import { silentLogger } from '../src/observability.js'

function setup(registerImpl?: (codeHash: string) => Promise<void>, lanUrls?: () => readonly string[]) {
  let sequence = 0
  const pairing = createPairing({
    pcId: 'pc-1',
    relayUrl: 'wss://relay.example/ws',
    pcPubEd: 'a'.repeat(64),
    pcPubDh: 'b'.repeat(64),
    randomBytes: (size) => Uint8Array.from({ length: size }, () => ++sequence % 256),
    ...(lanUrls === undefined ? {} : { lanUrls }),
  })
  const registered: string[] = []
  const register =
    registerImpl ??
    ((codeHash: string) => {
      registered.push(codeHash)
      return Promise.resolve()
    })
  return { pairing, register, registered }
}

test('登记成功才出码：命令结果里带二维码载荷（含码与电脑公钥）', async () => {
  const { pairing, register, registered } = setup()
  const result = await offerForScanning({ pairing, register })

  assert.equal(result.kind, 'success')
  const payload = JSON.parse(result.text.split('\n')[1] ?? '') as Record<string, unknown>
  assert.equal(payload['relay'], 'wss://relay.example/ws')
  assert.equal(payload['pcPubEd'], 'a'.repeat(64))
  assert.equal(typeof payload['code'], 'string')

  // 登记用的必须是**这张码的哈希**（否则中转绑不上，手机扫了也配不上）。
  assert.deepEqual(registered, [payload['offerId']])
  assert.notEqual(registered[0], pairingCodeHash(String(payload['code'])), '登记值不能充当授权校验值')
})

test('登记失败：**不出码**，回一个说明原因的结果（而不是给一张配不上的二维码）', async () => {
  const { pairing } = setup(() => Promise.reject(new Error('中转连不上')))
  const result = await offerForScanning({ pairing, register: () => Promise.reject(new Error('中转连不上')) })

  assert.equal(result.kind, 'error')
  assert.match(result.text, /没有出码/)
  // 关键：失败结果里**不许**夹带任何码/载荷（否则操作者可能照着它去扫）。
  assert.equal(/[A-Za-z0-9_-]{22}/.test(result.text), false, '失败文案里不许出现码')
  assert.equal(result.text.includes('pcPubEd'), false, '也不许出现载荷片段')
})

test('登记失败但有局域网地址：仍然出码（只丢跨网那条路，不是"配不上"）', async () => {
  const warnings: string[] = []
  const lan = ['ws://192.168.1.5:8790', 'ws://10.0.0.7:8790']
  const { pairing } = setup(() => Promise.reject(new Error('中转连不上')), () => lan)
  const result = await offerForScanning({
    pairing,
    register: () => Promise.reject(new Error('中转连不上')),
    log: { ...silentLogger, warn: (message) => { warnings.push(message) } },
  })

  assert.equal(result.kind, 'success', '手机能直连，就不该把出码拦下来')
  const payload = JSON.parse(result.text.split('\n')[1] ?? '') as Record<string, unknown>
  assert.deepEqual(payload['lan'], lan, '二维码里必须带着局域网地址')
  assert.match(result.text, /局域网直连/, '命令输出要说明这次走的是局域网')

  assert.equal(warnings.length, 1, '降级要留声（否则"跨网配不上"没人知道为什么）')
  assert.match(warnings[0] ?? '', /只能走局域网直连/)

  // **登记仍然先试过**：中转可用时同一张码在跨网也能用，不能因为"有 lan"就跳过登记。
  const { pairing: healthy, register, registered } = setup(undefined, () => lan)
  const ok = await issuePairingOffer({ pairing: healthy, register })
  assert.deepEqual(registered, [JSON.parse(ok.payload).offerId])
})

test('成功文案里的有效期**从常量算**（写死数字会变成一句撒谎的提示）', async () => {
  const { pairing, register } = setup()
  const result = await offerForScanning({ pairing, register })
  assert.equal(result.kind, 'success')
  const minutes = Math.round(PAIRING_TTL_MS / 60_000)
  assert.match(
    result.text,
    new RegExp(`${minutes} 分钟`),
    '文案与 PAIRING_TTL_MS 必须同源：改常量而不改文案，操作者会按过期的时间安排',
  )
})

test('一次出码只登记一次，且用的是**这一次**的哈希（重新出码换哈希）', async () => {
  const { pairing, register, registered } = setup()
  let round = 0
  const pairing2 = createPairing({
    pcId: 'pc-1',
    relayUrl: 'wss://relay.example/ws',
    pcPubEd: 'a'.repeat(64),
    pcPubDh: 'b'.repeat(64),
    randomBytes: (size) => {
      round += 1
      return Uint8Array.from({ length: size }, (_, i) => (round * 53 + i) % 256)
    },
  })

  await offerForScanning({ pairing, register })
  await offerForScanning({ pairing: pairing2, register })
  assert.equal(registered.length, 2)
  assert.notEqual(registered[0], registered[1], '两次出码的哈希不同（码不同）')
})
