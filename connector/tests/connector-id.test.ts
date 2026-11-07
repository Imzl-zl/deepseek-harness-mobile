/**
 * 连接器标识：首装与旧装 `local` 都生成随机值。
 *
 * 2026-11-06 生产事故：两个账号的电脑都用旧默认 `local`，令牌表出现两条指向
 * 同一 `connectorId` 的记录，中转重启拒绝启动（停了 4 分钟）。2026-11-07 用户
 * 拍板：用户少、未宣发，**旧装也强制迁移**，不留 `local` 兼容尾巴。这条用例钉住
 * "任何存储里的 local 都不会被原样返回"。
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

test('resolveConnectorId：首装 / 旧装 local 都生成；已是随机值则保留', () => {
  let n = 0
  const generate = (): string => `pc-gen${++n}`

  assert.equal(resolveConnectorId('', generate), 'pc-gen1', '首装要生成')
  assert.equal(
    resolveConnectorId(LEGACY_CONNECTOR_ID, generate),
    'pc-gen2',
    '旧装 local 即使有已配对设备也强制迁移（用户 2026-11-07 拍板）',
  )
  assert.equal(
    resolveConnectorId('pc-already-unique', generate),
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
