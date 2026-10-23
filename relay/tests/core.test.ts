/**
 * 中转大脑的回归（契约 §2 / §12.1、I10；不变量见 `docs/subsystems/pairing-v2.md`）。
 *
 * ## 四条路由规则（全部与载荷内容无关）
 *
 * 1. **归属就是通道绑定**：`channelId → (connectorId, deviceId, purpose)`，
 *    两侧的帧各自只投给**同一条通道**的另一端 —— 不按 `sid` 广播。
 * 2. **回程不靠帧头 `id`**：`id` 是端点的关联标记，中转不认识它；
 *    两条通道上出现同一个 `id` 时各回各的。
 * 3. **中转不解析载荷**：坏行、未知 `sid`、方法名都进不了这一层。
 * 4. **唯一的丢弃理由是"没有这条通道"**，每一次丢弃都要计数（静默丢弃最难查）。
 *
 * 另外三条边界来自 §1 的不变量：一设备一通道、连接代次唯一、配对候选有界。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createRelayCore } from '../src/core.ts'
import {
  MAX_PAIRING_CANDIDATES,
  MAX_WIRE_BYTES,
  deviceIdOf,
  type DeviceBinding,
} from '../../protocol/relay-control.mjs'

const line = (frame: Record<string, unknown>): string => JSON.stringify({ v: 1, ...frame })
const ev = (sid: string, seq: number, box = 'x'): string =>
  line({ t: 'ev', sid, seq, fc: seq, box })
const binding = (deviceId: string, connectorId = 'pc-1'): DeviceBinding =>
  ({ connectorId, deviceId, purpose: 'paired' })

/** 两台设备各占一条通道 —— 这是"按 `sid` 广播"最容易串台的形状。 */
function setup() {
  const core = createRelayCore()
  core.attachConnector('pc-1')
  core.openDevice('channel-a', binding('phone-a'))
  core.openDevice('channel-b', binding('phone-b'))
  return core
}

test('通道绑定即订阅：两侧的帧只投给同一条通道的另一端（没绑数据连接的通道收不到）', () => {
  const core = setup()
  core.attachConnector('pc-2')
  core.openDevice('channel-c', binding('phone-c', 'pc-2'))
  core.attachData('pc-1', 'phone-a', 'channel-a')

  // 三个方向都拿**逐字相同**的帧（同一个 `sid`、同一个 `id`）：绑定即订阅，不看内容。
  const raw = ev('sid_1', 1)
  assert.deepEqual(
    core.onLine({ kind: 'device', channelId: 'channel-a' }, raw),
    [{ channelId: 'channel-a', to: 'data', raw }],
    '设备侧的帧投给它自己那条通道的电脑侧',
  )
  assert.deepEqual(
    core.onLine({ kind: 'data', channelId: 'channel-a' }, raw),
    [{ channelId: 'channel-a', to: 'device', raw }],
    '电脑侧的帧投给该通道的设备（另一台设备在听同一个 sid 也不算听众）',
  )

  // channel-b / channel-c 还没有数据连接 = 没有听众：不许把帧投给别的设备，而是明确拒绝。
  assert.throws(() => core.onLine({ kind: 'data', channelId: 'channel-b' }, raw), /数据连接尚未绑定/)
  assert.throws(() => core.onLine({ kind: 'data', channelId: 'channel-c' }, raw), /数据连接尚未绑定/)
  assert.deepEqual(
    core.attachData('pc-1', 'phone-b', 'channel-b'),
    [],
    '没有替谁排队：电脑侧的帧不会躺进"等设备说话"的那条缓冲里',
  )
})

test('配对用途通道：候选帧沿它自己那条通道投给连接器，回帧不看帧头 id；邀请失效后开不出通道', () => {
  const core = createRelayCore()
  core.attachConnector('pc-1')
  const offerA = 'A'.repeat(22)
  const offerB = 'B'.repeat(22)
  core.registerPairing('pc-1', offerA)

  const candidate = { offerId: offerA, devPubEd: 'a'.repeat(64), devPubDh: 'b'.repeat(64), name: '手机' }
  const deviceId = deviceIdOf(candidate)
  core.openDevice('pair-channel', { connectorId: 'pc-1', deviceId, purpose: 'pairing', candidate })
  core.attachData('pc-1', deviceId, 'pair-channel')

  const commit = line({ t: 'pair-commit', id: 'p1', fc: 1, box: '{}' })
  assert.deepEqual(
    core.onLine({ kind: 'device', channelId: 'pair-channel' }, commit),
    [{ channelId: 'pair-channel', to: 'data', raw: commit }],
    '配对提交没有 sid —— 靠通道绑定路由，而不是被当成"没有归属"丢掉',
  )
  const result = line({ t: 'pair-result', id: 'p1', fc: 1, box: '{}' })
  assert.deepEqual(
    core.onLine({ kind: 'data', channelId: 'pair-channel' }, result),
    [{ channelId: 'pair-channel', to: 'device', raw: result }],
    '没有 sid 的回帧靠通道绑定找回发起方，而不是靠帧头 id 猜',
  )

  // 重新出码：旧的公开邀请立即失效，拿着它来的**新候选**也开不出通道（§3：同时只有一份当前出码）。
  // 换一台候选公钥是刻意的：同一台候选的第二条通道会被"一设备一通道"先挡掉，测不到邀请的存活性。
  core.registerPairing('pc-1', offerB)
  assert.equal(core.lookupPairing(offerA), undefined)
  const lateCandidate = { ...candidate, devPubDh: 'e'.repeat(64) }
  assert.throws(
    () => core.openDevice('pair-channel-2', {
      connectorId: 'pc-1', deviceId: deviceIdOf(lateCandidate), purpose: 'pairing', candidate: lateCandidate,
    }),
    /公开邀请已失效/,
  )
  assert.equal(core.stats.channels, 1, '被拒的那一次不许留下通道')
})

test('丢弃要计数、要有理由：没有这条通道的帧一律丢弃并计数（内容不进这一层）', () => {
  const core = setup()
  core.attachData('pc-1', 'phone-a', 'channel-a')

  assert.deepEqual(core.onLine({ kind: 'device', channelId: 'channel-x' }, 'not json'), [], '坏行不由中转判定')
  assert.deepEqual(core.onLine({ kind: 'data', channelId: 'channel-x' }, ev('sid_x', 1)), [], '未知 sid 不由中转判定')
  assert.deepEqual(
    core.onLine({ kind: 'device', channelId: 'channel-gone' }, line({ t: 'pair', id: 'p1', box: '{}' })),
    [],
    '没有这条通道：不知道该给谁',
  )
  assert.equal(core.stats.dropped, 3, '每一次丢弃都要计数（静默丢弃最难查）')

  // 反面：已绑定的通道上**逐字转发**，它是不是 JSON、携不携 sid 都与中转无关。
  const opaque = 'not json at all'
  assert.deepEqual(core.onLine({ kind: 'device', channelId: 'channel-a' }, opaque), [
    { channelId: 'channel-a', to: 'data', raw: opaque },
  ])
  assert.equal(core.stats.dropped, 3, '转发成功不产生丢弃')
})

test('连接器断开：它的通道全部关闭、登记失效（不留指向消失连接的投递）', () => {
  const core = createRelayCore()
  core.attachConnector('pc-1')
  core.attachConnector('pc-2')
  const offerA = 'A'.repeat(22)
  const offerB = 'B'.repeat(22)
  core.registerPairing('pc-1', offerA)
  core.registerPairing('pc-1', offerB)
  core.openDevice('channel-a', binding('phone-a'))
  core.openDevice('channel-b', binding('phone-b', 'pc-2'))
  core.attachData('pc-1', 'phone-a', 'channel-a')
  core.attachData('pc-2', 'phone-b', 'channel-b')

  assert.deepEqual(core.detachConnector('pc-1'), ['channel-a'], '它的通道随它一起关闭')
  assert.equal(core.lookupPairing(offerB), undefined, '没用上的公开邀请随连接器一起失效')
  assert.equal(core.stats.registrations, 0)
  assert.deepEqual(
    core.onLine({ kind: 'device', channelId: 'channel-a' }, line({ t: 'pair', id: 'p2', box: '{}' })),
    [],
    '设备失去了通道：不能把帧投给一条已消失的连接',
  )
  assert.equal(core.stats.dropped, 1, '这条帧算一次丢弃，而不是投给空气')
  assert.equal(core.channelOf('pc-1', 'phone-a'), undefined)
  assert.equal(core.channel('channel-b')?.connected, true, '别的连接器的通道不受影响')
})

test('开通道时连接器已离线：归属不成立（设备不该拿到指向空气的通道）', () => {
  const core = createRelayCore()
  core.attachConnector('pc-1')
  const offerId = 'A'.repeat(22)
  core.registerPairing('pc-1', offerId)
  core.detachConnector('pc-1') // 登记被清掉了

  assert.throws(() => core.openDevice('channel-a', binding('phone-a')), /归属无效或连接器离线/)
  assert.equal(core.lookupPairing(offerId), undefined, '离线的连接器的邀请不再是可用的邀请')
  assert.equal(core.stats.channels, 0, '拒绝时不许留下通道')
})

test('通道关闭：归属与统计一并清掉，重连是一条新代次（旧代次再关一次无效）', () => {
  const core = setup()
  core.attachData('pc-1', 'phone-a', 'channel-a')
  core.attachData('pc-1', 'phone-b', 'channel-b')
  assert.equal(core.stats.channels, 2)

  assert.deepEqual(core.closeChannel('channel-a'), {
    channelId: 'channel-a',
    binding: binding('phone-a'),
    connected: true,
  })
  assert.equal(core.channel('channel-a'), undefined)
  assert.equal(core.channelOf('pc-1', 'phone-a'), undefined)
  assert.equal(core.stats.channels, 1, '另一台设备不受影响')

  // 重连：同一台设备开一条新通道 = 新代次。
  core.openDevice('channel-new', binding('phone-a'))
  assert.equal(core.channelOf('pc-1', 'phone-a'), 'channel-new')
  assert.equal(core.closeChannel('channel-a'), undefined, '旧代次已经不存在')
  assert.equal(core.channelOf('pc-1', 'phone-a'), 'channel-new', '关旧代次不许清掉新代次')

  core.closeChannel('channel-b')
  core.closeChannel('channel-new')
  assert.equal(core.stats.channels, 0)
  // `stats` 里**没有 `devices`**：设备数是名册的事（`deviceRegistry.stats.devices`），
  // 这里原来那个 `devices: channels.size` 与 `channels` 恒等，是个不携带信息的第二个名字。
  assert.deepEqual(Object.keys(core.stats).sort(), ['channels', 'connectors', 'dropped', 'registrations'])
})

test('一设备一通道、一通道一代次：重复开通道与同设备的第二条通道都被拒', () => {
  const core = setup()

  assert.throws(() => core.openDevice('channel-a', binding('phone-b')), /连接代次已存在/)
  assert.throws(() => core.openDevice('channel-c', binding('phone-a')), /旧设备连接必须先关闭/, '一台设备同时只能有一条数据连接')

  // 归属是 (连接器, 设备) 二元组：两台连接器上的同名设备互不影响。
  core.attachConnector('pc-2')
  core.openDevice('channel-c', binding('phone-a', 'pc-2'))
  assert.equal(core.channelOf('pc-2', 'phone-a'), 'channel-c')
  assert.equal(core.channelOf('pc-1', 'phone-a'), 'channel-a')
})

test('配对候选有界：同一连接器最多 MAX_PAIRING_CANDIDATES 条待配对通道（§3 的"候选数量有界"）', () => {
  const core = createRelayCore()
  core.attachConnector('pc-1')
  const offerId = 'A'.repeat(22)
  core.registerPairing('pc-1', offerId)
  // 每台候选的公钥不同 → 派生出的设备 id 不同（同一候选的第二条通道会被"一设备一通道"挡掉）。
  const candidateOf = (index: number) => ({
    offerId,
    devPubEd: 'a'.repeat(64),
    devPubDh: index.toString(16).padStart(64, '0'),
    name: `手机 ${index}`,
  })

  for (let index = 0; index < MAX_PAIRING_CANDIDATES; index += 1) {
    const candidate = candidateOf(index)
    core.openDevice(`pair-${index}`, {
      connectorId: 'pc-1',
      deviceId: deviceIdOf(candidate),
      purpose: 'pairing',
      candidate,
    })
  }
  const extra = candidateOf(MAX_PAIRING_CANDIDATES)
  assert.throws(
    () => core.openDevice('pair-over', {
      connectorId: 'pc-1',
      deviceId: deviceIdOf(extra),
      purpose: 'pairing',
      candidate: extra,
    }),
    /待配对连接数量已达上限/,
    '没有上界的话，一次出码窗口内可以堆出无数条待配对连接',
  )
  assert.equal(core.stats.channels, MAX_PAIRING_CANDIDATES)
})

test('通道上限：单帧超过 MAX_WIRE_BYTES 被拒（不静默截断）', () => {
  const core = setup()
  core.attachData('pc-1', 'phone-a', 'channel-a')

  assert.throws(
    () => core.onLine({ kind: 'device', channelId: 'channel-a' }, 'x'.repeat(MAX_WIRE_BYTES + 1)),
    /通道上限/,
  )
  assert.equal(core.stats.dropped, 0, '拒帧不算丢弃（它是一帧明确被拒绝的输入，不是无处可投）')
})
