/**
 * 设备名册的回归（契约 §8.2 的 `devices` 表）。
 *
 * 核心不变量：**名册是电脑侧的全量快照，差集即删除**。
 * 2026-10-15 真机实测到违反它的后果 —— 电脑侧删掉一台设备后，它在中转层**还换得到票**：
 * 手机因此通过换票、死在连接器握手（close 4003 + `protocol/not-paired`），
 * 而 App 只把"换票 401"映射终态，于是无限"重连中…"，两端日志都没有原因。
 * （连接器那侧的意图本来就写在 `device-publish.ts` 文件头："空名册也要报……
 *   少报这一次会让中转留着一份过期的归属"—— 是中转没实现。）
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { createDeviceRegistry, type DeviceRegistration } from '../src/device-registry.ts'

/** 名册里只存摘要，所以测试里也要算真的（`device-registry.ts` 的 `hashOf` 同一条）。 */
const hashOf = (token: string): string =>
  createHash('sha256').update(token, 'utf8').digest('hex')

const row = (id: string, token: string): DeviceRegistration => ({
  id,
  pairingId: `pair-${id}`,
  devPubEd: `ed-${id}`,
  devPubDh: `dh-${id}`,
  name: `手机-${id}`,
  tokenHash: hashOf(token),
})

test('报到即建行：令牌认得出、归属查得到、计数对', () => {
  const devices = createDeviceRegistry()
  assert.equal(devices.register('conn-1', [row('d1', 't1')]), 1)
  assert.equal(devices.authenticate('t1'), 'd1')
  assert.equal(devices.connectorOf('d1'), 'conn-1')
  assert.deepEqual(devices.stats, { devices: 1, bound: 1 })
})

test('令牌诊断：ok / revoked / unknown 三者分开（手机据此决定重试还是解禁）', () => {
  // 为什么必须分开：`authenticate` 把"已停用"与"没见过"折成同一个 `undefined`，
  // 于是 401 只能回一句含糊的 `unauthorized` —— 手机就显示"可能已停用，或凭据已失效"。
  // 而用户真正需要知道的是"重连可能就好"还是"要去电脑上解禁/重扫"。
  const devices = createDeviceRegistry()
  devices.register('conn-1', [
    row('d1', 't1'),
    { ...row('d2', 't2'), revokedAt: 1 },
  ])
  assert.equal(devices.classify('t1'), 'ok')
  assert.equal(devices.classify('t2'), 'revoked')
  assert.equal(devices.classify('nope'), 'unknown')
  assert.equal(devices.classify(''), 'unknown')
})

test('差集即删除：这次没报到的行必须消失（行 + 令牌索引 + 计数）', () => {
  const devices = createDeviceRegistry()
  devices.register('conn-1', [row('d1', 't1'), row('d2', 't2')])
  assert.equal(devices.stats.devices, 2)

  // 电脑侧删掉了 d2：名册是全量快照，所以只报 d1。
  devices.register('conn-1', [row('d1', 't1')])

  assert.equal(devices.stats.devices, 1, 'd2 的行没了')
  assert.equal(devices.authenticate('t2'), undefined, 'd2 的令牌也认不出了（索引一起清）')
  assert.equal(devices.authenticate('t1'), 'd1', '还在名册里的 d1 不受影响')
})

test('空名册清空：那正是"这台电脑上没有设备了"的形状', () => {
  const devices = createDeviceRegistry()
  devices.register('conn-1', [row('d1', 't1'), row('d2', 't2')])
  assert.equal(devices.register('conn-1', []), 0, '空名册认下 0 行')
  assert.equal(devices.stats.devices, 0, '但要把旧的都收敛掉')
  assert.equal(devices.authenticate('t1'), undefined)
  assert.equal(devices.authenticate('t2'), undefined)
})

test('不误删别人的行：一份短名册只收敛自己的设备', () => {
  const devices = createDeviceRegistry()
  devices.register('conn-1', [row('d1', 't1')])
  devices.register('conn-2', [row('d2', 't2')])

  devices.register('conn-1', [])

  assert.equal(devices.authenticate('t1'), undefined, '自己的收敛掉了')
  assert.equal(devices.authenticate('t2'), 'd2', 'conn-2 的没动')
  assert.equal(devices.connectorOf('d2'), 'conn-2')
})

test('断开留行、回来重播接回（I7：中转可被清空后重启）', () => {
  const devices = createDeviceRegistry()
  devices.register('conn-1', [row('d1', 't1')])
  assert.equal(devices.detachConnector('conn-1'), 1)

  assert.equal(devices.stats.devices, 1, '行留着')
  assert.equal(devices.stats.bound, 0, '归属清掉')
  assert.equal(devices.connectorOf('d1'), undefined)
  assert.equal(devices.authenticate('t1'), 'd1', '令牌还能认（设备要能自己回来）')

  devices.register('conn-1', [row('d1', 't1')])
  assert.equal(devices.connectorOf('d1'), 'conn-1', '重播即接回')
})

test('断开后报更短的名册也收敛：published 跨 detach 存活', () => {
  const devices = createDeviceRegistry()
  devices.register('conn-1', [row('d1', 't1'), row('d2', 't2')])
  devices.detachConnector('conn-1')

  // 断开期间电脑侧删了 d2，回来只报 d1。
  devices.register('conn-1', [row('d1', 't1')])

  assert.equal(devices.authenticate('t1'), 'd1')
  assert.equal(devices.authenticate('t2'), undefined, '过期的行不能因为断开过一次就复活')
  assert.equal(devices.stats.devices, 1)
})

test('同一 id 换令牌：旧摘要立刻失效（否则"换令牌"等于"多一把钥匙"）', () => {
  const devices = createDeviceRegistry()
  devices.register('conn-1', [row('d1', 't1')])
  devices.register('conn-1', [row('d1', 't2')])
  assert.equal(devices.authenticate('t1'), undefined, '旧令牌失效')
  assert.equal(devices.authenticate('t2'), 'd1', '新令牌可用')
  assert.equal(devices.stats.devices, 1, '还是同一行')
})

test('临时身份与空摘要永不落表', () => {
  const devices = createDeviceRegistry()
  assert.equal(
    devices.register('conn-1', [
      { ...row('pending:x', 'tp'), id: 'pending:x' },
      { ...row('d1', ''), tokenHash: '' },
      row('d2', 't2'),
    ]),
    1,
    '只认下 d2',
  )
  assert.equal(devices.stats.devices, 1)
  assert.equal(devices.authenticate('t2'), 'd2')
})

test('吊销的行认不下（行留着是为了可辨识）', () => {
  const devices = createDeviceRegistry()
  devices.register('conn-1', [{ ...row('d1', 't1'), revokedAt: 1_000 }])
  assert.equal(devices.authenticate('t1'), undefined)
  assert.equal(devices.connectorOf('d1'), undefined)
  assert.equal(devices.stats.devices, 1, '行还在')
})

test('多连接器共用一个进程：**别的连接器的行不许被覆盖**（键是设备 id，不带租户前缀）', () => {
  // 这张表按设备 id 存（设备 id 由公钥派生，正常不会撞）。没有归属校验的话，
  // 任何持有合法连接器令牌的人只要知道对方的 id，就能把那一行换成自己的摘要 ——
  // 原设备从此换票 401 device-unknown（定向 DoS），中转完全看不出异常。
  const devices = createDeviceRegistry()
  assert.equal(devices.register('conn-1', [row('d1', 't1')]), 1, '先来的认下')

  // 第二个连接器报了**同一个设备 id**、但换了自己的令牌摘要：拒绝，且一个字都不写。
  assert.equal(devices.register('conn-2', [row('d1', 't2')]), 0, '不许覆盖别的连接器的行')
  assert.equal(devices.authenticate('t1'), 'd1', '原设备的令牌仍然有效')
  assert.equal(devices.authenticate('t2'), undefined, '入侵者的令牌拿不到身份')
  assert.equal(devices.connectorOf('d1'), 'conn-1', '归属没变')
  assert.deepEqual(devices.stats, { devices: 1, bound: 1 })

  // 各报各的设备：互不影响，两张表一起长。
  assert.equal(devices.register('conn-2', [row('d2', 't2')]), 1)
  assert.equal(devices.connectorOf('d1'), 'conn-1')
  assert.equal(devices.connectorOf('d2'), 'conn-2')

  // 连接器 2 断开：只清自己的归属，连接器 1 的行一位不动。
  devices.detachConnector('conn-2')
  assert.equal(devices.connectorOf('d1'), 'conn-1')
  assert.equal(devices.connectorOf('d2'), undefined, '自己的行清归属（行留着）')
  assert.equal(devices.authenticate('t1'), 'd1')
})
