/**
 * 令牌摘要校验的回归（契约 §12.2）。
 *
 * 三条用例：认得出（按摘要，不按原文）、认不出就 `undefined`（调用方据此 401）、
 * 配置写重了要拒绝启动（那会让"谁是谁"变得看运气）。
 *
 * ## 这张表只放**连接器**令牌
 *
 * 设备令牌由电脑侧签发、摘要经 `POST /devices` 进名册（§8.2）。中转自己签设备令牌
 * 等于转发器凭空造出"我是某台设备"的凭据，是 v2 否掉的形状 —— 所以这里也有一条
 * "表里出现 device 条目就拒绝建表"的用例（与启动路径的那条配对）。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { createDigestAuthenticator, type TokenDigest } from '../src/digest-auth.ts'

const hash = (token: string): string => createHash('sha256').update(token, 'utf8').digest('hex')

const ENTRIES: TokenDigest[] = [
  { kind: 'connector', id: 'conn-1', hash: hash('connector-token-1') },
  { kind: 'connector', id: 'conn-2', hash: hash('connector-token-2') },
]

test('按摘要认令牌：拿到的是它绑定的身份', () => {
  const authenticate = createDigestAuthenticator(ENTRIES)
  assert.deepEqual(authenticate('connector-token-1'), { kind: 'connector', id: 'conn-1' })
  assert.deepEqual(authenticate('connector-token-2'), { kind: 'connector', id: 'conn-2' })
  assert.equal(authenticate.size, 2)
})

test('认不出就 undefined（不抛）：调用方据此回 401，且不区分原因', () => {
  const authenticate = createDigestAuthenticator(ENTRIES)
  assert.equal(authenticate(''), undefined)
  assert.equal(authenticate('nope'), undefined)
  // 摘要本身不是令牌（拿摘要来当令牌不该通过 —— 那会让"泄露摘要"等于"泄露凭据"）
  assert.equal(authenticate(hash('connector-token-1')), undefined)
})

test('摘要表里有重复：**拒绝启动**（否则"谁是谁"看运气）', () => {
  assert.throws(
    () => createDigestAuthenticator([...ENTRIES, { kind: 'connector', id: 'conn-3', hash: hash('connector-token-1') }]),
    /重复条目/,
  )
})

test('表里出现 device 条目：**拒绝建表**（v2 起中转只签连接器令牌）', () => {
  // 形状来自 `JSON.parse(config)`，而配置是人写的 —— 校验函数的职责正是接住
  // "类型说不可能、文件里却真有"的那种输入。
  const legacy = [
    ...ENTRIES,
    { kind: 'device', id: 'dev-1', hash: hash('v1-device-token') },
  ] as unknown as TokenDigest[]
  assert.throws(() => createDigestAuthenticator(legacy), /device 条目/)
})
