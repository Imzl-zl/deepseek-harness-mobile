/**
 * 名册一行的形状（`device-publish.ts` 的 `rosterEntry`）。
 *
 * 这一篇只钉三条，但每条都有事故背景：
 *
 * 1. **停用的行照样上报**（带 `revokedAt`）—— 它是中转说 `device-revoked` 的
 *    唯一来源。报漏了，手机侧收到的就是 `device-unknown`（"名册还没同步"那一档），
 *    于是它一直重试，用户看不到"你被停用了"，停用功能在他那边等于没发生。
 * 2. **没有 `tokenHash` 的行不报**：缺摘要 = 换不到票，报了只会让中转留一份
 *    过期的归属（`device-registry` 的纪律 4 会按差集删，但没必要先塞进去）。
 * 3. **形状逐字**：名册字段名就是中转 `DeviceRegistration` 的字段名，多一个少一个
 *    都算契约漂移（中转的 `parseRegistrations` 对未知字段是忽略，所以这里靠测试钉）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { rosterEntry } from '../src/device-publish.js'

/** `devices` 表里的一行（与 `store/index.ts` 的 `DeviceRecord` 同形）。 */
const record = {
  edPub: 'a'.repeat(64),
  dhPub: 'b'.repeat(64),
  name: '我的手机',
  pairedAt: 1760000000000,
  pairingId: 'pair-1',
  tokenHash: 'c'.repeat(64),
}

test('未停用的行：不含 revokedAt 这个键（不是 undefined 值）', () => {
  const entry = rosterEntry('dev-1', record)
  assert.deepEqual(entry, {
    id: 'dev-1',
    pairingId: 'pair-1',
    devPubEd: record.edPub,
    devPubDh: record.dhPub,
    name: '我的手机',
    tokenHash: record.tokenHash,
  })
  assert.equal('revokedAt' in (entry ?? {}), false, 'JSON 里不该出现 revokedAt:null/undefined')
})

test('停用的行照样上报，带 revokedAt（device-revoked 的唯一来源）', () => {
  const entry = rosterEntry('dev-1', { ...record, revokedAt: 1760000500000 })
  assert.equal(entry?.revokedAt, 1760000500000)
  assert.equal(entry?.tokenHash, record.tokenHash, '停用不摘摘要：中转要靠它认出这枚令牌')
})

test('没有 tokenHash 的行报不进名册（换不到票，报了也没用）', () => {
  const { tokenHash: _omit, ...withoutHash } = record
  assert.equal(rosterEntry('dev-1', withoutHash), undefined)
})
