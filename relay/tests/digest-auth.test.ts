/**
 * 令牌摘要校验的回归（契约 §12.2）。
 *
 * 两条用例：认得出（按摘要，不按原文）、认不出就 `undefined`（调用方据此 401）。
 * 外加一条"配置写重了要拒绝启动" —— 那会让"谁是谁"变得看运气。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { createDigestAuthenticator, type TokenDigest } from '../src/digest-auth.ts'

const hash = (token: string): string => createHash('sha256').update(token, 'utf8').digest('hex')

const ENTRIES: TokenDigest[] = [
  { kind: 'device', id: 'dev-1', hash: hash('device-token-1') },
  { kind: 'connector', id: 'conn-1', hash: hash('connector-token-1') },
]

test('按摘要认令牌：拿到的是它绑定的身份与类型', () => {
  const authenticate = createDigestAuthenticator(ENTRIES)
  assert.deepEqual(authenticate('device-token-1'), { kind: 'device', id: 'dev-1' })
  assert.deepEqual(authenticate('connector-token-1'), { kind: 'connector', id: 'conn-1' })
  assert.equal(authenticate.size, 2)
})

test('认不出就 undefined（不抛）：调用方据此回 401，且不区分原因', () => {
  const authenticate = createDigestAuthenticator(ENTRIES)
  assert.equal(authenticate(''), undefined)
  assert.equal(authenticate('nope'), undefined)
  // 摘要本身不是令牌（拿摘要来当令牌不该通过 —— 那会让"泄露摘要"等于"泄露凭据"）
  assert.equal(authenticate(hash('device-token-1')), undefined)
})

test('摘要表里有重复：**拒绝启动**（否则"谁是谁"看运气）', () => {
  assert.throws(
    () => createDigestAuthenticator([...ENTRIES, { kind: 'device', id: 'dev-2', hash: hash('device-token-1') }]),
    /重复条目/,
  )
})
