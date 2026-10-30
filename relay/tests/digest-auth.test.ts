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

import { createDigestAuthenticator, rateKeyOf, type TokenDigest } from '../src/digest-auth.ts'

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

test('owner：同一人的多台电脑带同一个值，限流桶按**人**算（没配就退回按连接器）', () => {
  // 中转本身不需要"用户"：路由与名册全按 (connectorId, deviceId) 走，已经分得清
  // "这台手机在哪台电脑名下"。`owner` 只服务按人的东西 —— 限流与日志归属。
  // 没有它，一个人多开几台电脑就等于多领几份限流预算（绕过限流的免费办法）。
  const authenticate = createDigestAuthenticator([
    { kind: 'connector', id: 'home-pc', hash: hash('t-home'), owner: 'alice' },
    { kind: 'connector', id: 'work-pc', hash: hash('t-work'), owner: 'alice' },
    { kind: 'connector', id: 'solo', hash: hash('t-solo') },
  ])
  assert.deepEqual(authenticate('t-home'), { kind: 'connector', id: 'home-pc', owner: 'alice' })
  assert.equal(rateKeyOf(authenticate('t-home')!), rateKeyOf(authenticate('t-work')!), '同一个人的两台电脑共用一个桶')
  assert.equal(rateKeyOf(authenticate('t-work')!), 'user:alice')
  assert.equal(rateKeyOf(authenticate('t-solo')!), 'connector:solo', '没配 owner 按连接器分桶（旧行为）')
  // owner 不参与路由：同一人的两台电脑仍然是两个独立身份。
  assert.notEqual(authenticate('t-home')!.id, authenticate('t-work')!.id)
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
