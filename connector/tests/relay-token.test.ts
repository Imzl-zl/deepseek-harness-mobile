/**
 * 连接器令牌读取的回归（契约 §12.2）。
 *
 * 三条失败路径各配一条用例：它们都会让"连不上中转"，而只有**大声失败**才能让人
 * 一眼看出是"令牌没配/配错"而不是"网络问题"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { credentialKey, type CredentialKey, type CredentialRecord } from '@deepseek-ai/dsh-credentials'

import { RelayTokenError, readRelayToken } from '../src/dsh/relay-token.js'

const KEY = credentialKey('dsh-mobile-connector', 'relay-token')

/** 假的凭据面：记下**实际传入的键**（`CredentialKey` 是品牌类型，只能整体比对）。 */
const source = (record: CredentialRecord | undefined) => {
  const seen: CredentialKey[] = []
  return {
    seen,
    readRecord: (key: CredentialKey) => {
      seen.push(key)
      return Promise.resolve(record)
    },
  }
}

test('读得到：返回令牌本体（不缓存，每次现读），且读的是那个具名记录', async () => {
  const s = source({ kind: 'grant', payload: { token: 'tok-1' } } as CredentialRecord)
  let reads = 0
  const credentials = {
    readRecord: () => {
      reads += 1
      return Promise.resolve({ kind: 'grant', payload: { token: 'tok-1' } } as CredentialRecord)
    },
  }
  assert.equal(await readRelayToken(credentials, 'relay-token'), 'tok-1')
  assert.equal(await readRelayToken(credentials, 'relay-token'), 'tok-1')
  assert.equal(reads, 2, '不缓存：操作者更新令牌后必须立刻生效')
})

test('记录不存在：抛（**不去编一个** —— 编出来的中转不认，症状是"连不上"）', async () => {
  await assert.rejects(
    () => readRelayToken(source(undefined), 'relay-token'),
    (error: unknown) => error instanceof RelayTokenError && /没有连接器令牌记录/.test(error.message),
  )
})

test('记录类型不对：抛（别人的记录不许静默当成"没配"）', async () => {
  await assert.rejects(
    () =>
      readRelayToken(
        source({ kind: 'oauth', payload: { token: 'tok' } } as unknown as CredentialRecord),
        'relay-token',
      ),
    (error: unknown) => error instanceof RelayTokenError && /不是本插件写的 grant 记录/.test(error.message),
  )
})

test('载荷里没有非空 token：抛（空串会退化成匿名连接，症状与"没配"一样却更难关联）', async () => {
  for (const payload of [{}, { token: '' }, { token: 42 }]) {
    await assert.rejects(
      () => readRelayToken(source({ kind: 'grant', payload } as CredentialRecord), 'relay-token'),
      (error: unknown) => error instanceof RelayTokenError && /没有非空的 token/.test(error.message),
    )
  }
})
