/**
 * 出码入口的回归（契约 §12.1 第 1 步）。
 *
 * 三条用例，盯住的是**顺序**与**失败时的行为**（它们都不会报错，只会让人排查错方向）：
 * 登记成功才给码；登记失败**不给码**；登记用的 `codeHash` 必须与码同源。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createPairing, pairingCodeHash } from '../src/pairing.js'
import { offerForScanning } from '../src/pairing-offer.js'

function setup(registerImpl?: (codeHash: string) => Promise<void>) {
  const pairing = createPairing({
    relayUrl: 'wss://relay.example/ws',
    pcPubEd: 'a'.repeat(64),
    pcPubDh: 'b'.repeat(64),
    randomBytes: (size) => Uint8Array.from({ length: size }, (_, i) => i + 7),
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
  assert.deepEqual(registered, [pairingCodeHash(String(payload['code']))])
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

test('一次出码只登记一次，且用的是**这一次**的哈希（重新出码换哈希）', async () => {
  const { pairing, register, registered } = setup()
  let round = 0
  const pairing2 = createPairing({
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
