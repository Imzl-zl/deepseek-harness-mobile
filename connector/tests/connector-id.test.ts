/**
 * 连接器标识：新装随机、老装 `local` 只在没有已配对设备时迁移。
 *
 * 2026-11-06 生产事故：两个账号的电脑都用旧默认 `local`，令牌表出现两条指向
 * 同一 `connectorId` 的记录，中转重启拒绝启动（停了 4 分钟）。这条用例钉住
 * "新装不再产生 `local`"与"有配对的老装不被动换 id"两个边界。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  LEGACY_CONNECTOR_ID,
  isConnectorId,
  newConnectorId,
  resolveConnectorId,
} from '../src/connector-id.js'

test('newConnectorId：不是 local，形状合法，多次生成不重复', () => {
  const seen = new Set<string>()
  for (let index = 0; index < 100; index += 1) {
    const id = newConnectorId()
    assert.notEqual(id, LEGACY_CONNECTOR_ID, '新装绝不能再用旧默认值')
    assert.match(id, /^pc-[A-Za-z0-9_-]{12}$/, `形状不对：${id}`)
    assert.equal(isConnectorId(id), true)
    assert.equal(seen.has(id), false, '随机 id 撞了')
    seen.add(id)
  }
})

test('resolveConnectorId：首装 / 老装无配对 → 迁移；有配对 → 保留 local', () => {
  let n = 0
  const generate = (): string => `pc-gen${++n}`

  assert.equal(resolveConnectorId('', false, generate), 'pc-gen1', '首装要生成')
  assert.equal(
    resolveConnectorId(LEGACY_CONNECTOR_ID, false, generate),
    'pc-gen2',
    '老装但没有已配对设备：迁移是免费的',
  )
  assert.equal(
    resolveConnectorId(LEGACY_CONNECTOR_ID, true, generate),
    LEGACY_CONNECTOR_ID,
    '有已配对设备：换 id 会让它们全部验签失败，必须保留',
  )
  assert.equal(
    resolveConnectorId('pc-already-unique', true, generate),
    'pc-already-unique',
    '已经是新标识的装机不动',
  )
})

test('isConnectorId：只收中转控制面接受的形状', () => {
  for (const value of ['local', 'pc-abc_123-XYZ', 'a'.repeat(64)]) {
    assert.equal(isConnectorId(value), true, `${value} 应该合法`)
  }
  for (const value of ['', 'a'.repeat(65), 'has space', 'has:colon', '中文']) {
    assert.equal(isConnectorId(value), false, `${value} 不该合法`)
  }
})
