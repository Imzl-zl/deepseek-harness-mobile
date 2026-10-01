/**
 * 身份落点的回归（契约 §4.1、§12.1）。
 *
 * 这里钉的是**身份种子的一生**：什么时候生成、什么时候必须拒绝。
 * 它值得一组自己的测试，因为写错的后果不是"报错"，而是**悄悄换一套身份** ——
 * 电脑侧一切正常，而所有已配对的手机从此连不上（且看起来像"验签失败"）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import type { CredentialKey, CredentialRecord } from '@deepseek-ai/dsh-credentials'

import { IDENTITY_RECORD, loadOrCreateIdentity, type IdentityCredentials } from '../src/dsh/identity.js'

/** 内存版凭据记录面：`modifyRecord` 的语义照 DSH —— 回调返回 `undefined` 即"不改"。 */
function fakeCredentials(initial?: CredentialRecord): IdentityCredentials & {
  writes: number
  stored(): CredentialRecord | undefined
} {
  let record = initial
  let writes = 0
  return {
    async readRecord(key: CredentialKey) {
      assert.equal(key, IDENTITY_RECORD)
      return record
    },
    async modifyRecord(key, mutate) {
      assert.equal(key, IDENTITY_RECORD)
      const next = await mutate(record)
      if (next !== undefined) {
        record = next
        writes += 1
      }
      return record
    },
    get writes() {
      return writes
    },
    stored: () => record,
  }
}

const grantWith = (seed: unknown): CredentialRecord => ({ kind: 'grant', payload: { masterSeed: seed } })

test('没有记录时：生成一次、落盘、派生出身份', async () => {
  const credentials = fakeCredentials()
  const identity = await loadOrCreateIdentity(credentials)

  assert.match(identity.masterSeed, /^[0-9a-f]{64}$/, '主种子是 32 字节 hex')
  assert.equal(credentials.writes, 1, '应当恰好写一次')
  assert.deepEqual(credentials.stored(), grantWith(identity.masterSeed))
  // 返回值与派生结果必须自洽（不是"写了一个、用了另一个"）。
  assert.equal(identity.keys.sign.publicKeyHex.length, 64)
  assert.equal(identity.keys.dh.publicKeyHex.length, 64)
  assert.notEqual(identity.keys.signSeedHex, identity.keys.dhSeedHex)
})

test('已有记录时：原样用它，不重新生成、不写盘', async () => {
  const existing = grantWith('ab'.repeat(32))
  const credentials = fakeCredentials(existing)
  const identity = await loadOrCreateIdentity(credentials)

  assert.equal(identity.masterSeed, 'ab'.repeat(32))
  assert.equal(credentials.writes, 0, '已有身份不该再写一次')
})

test('并发首启：以**记录里那条**为准，不是自己生成的那条', async () => {
  // 模拟"另一个进程先写进去了"：我们的 mutate 回调看到已有记录 → 返回 undefined（不改），
  // 于是返回给我们的是先到者写的那条。用自己生成的那个会让两端身份悄悄分叉。
  const winner = grantWith('cd'.repeat(32))
  const credentials: IdentityCredentials = {
    async readRecord() {
      return undefined
    },
    async modifyRecord() {
      return winner
    },
  }

  const identity = await loadOrCreateIdentity(credentials)
  assert.equal(identity.masterSeed, 'cd'.repeat(32), '必须采用记录里的那条')
})

test('记录不是本插件写的 grant 记录：抛错，绝不覆盖', async () => {
  const credentials = fakeCredentials({ kind: 'api-key', key: 'sk-someone-elses' })
  await assert.rejects(() => loadOrCreateIdentity(credentials), /不是本插件写的 grant 记录/)
  assert.equal(credentials.writes, 0, '不覆盖别人的记录')
})

test('记录里的 masterSeed 不合法：抛错，绝不覆盖', async () => {
  for (const bad of [undefined, '', 'not-hex', 'ab'.repeat(31)]) {
    const credentials = fakeCredentials(grantWith(bad))
    await assert.rejects(
      () => loadOrCreateIdentity(credentials),
      /masterSeed 不合法/,
      `坏种子 ${String(bad)} 应被拒绝`,
    )
    assert.equal(credentials.writes, 0, '覆盖等于把所有已配对设备一次性作废')
  }
})

test('写入后仍读不到（提供方拒绝了写）：抛错，不返回半成品', async () => {
  const credentials: IdentityCredentials = {
    async readRecord() {
      return undefined
    },
    async modifyRecord() {
      return undefined
    },
  }
  await assert.rejects(() => loadOrCreateIdentity(credentials), /写入后仍读不到/)
})
