import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createRelayCore } from '../src/core.ts'
import { createTicketStore } from '../src/tickets.ts'
import { deviceIdOf, MAX_PENDING_BYTES, type DeviceBinding } from '../../protocol/relay-control.mjs'

const binding = (deviceId: string, connectorId = 'pc-1'): DeviceBinding => ({ connectorId, deviceId, purpose: 'paired' })

function setup() {
  const core = createRelayCore()
  core.attachConnector('pc-1')
  core.attachConnector('pc-2')
  core.openDevice('channel-a', binding('phone-a'))
  core.openDevice('channel-b', binding('phone-b'))
  return core
}

test('连接隔离：相同 sid 和请求 id 也只回自己的设备', () => {
  const core = setup()
  core.attachData('pc-1', 'phone-a', 'channel-a')
  core.attachData('pc-1', 'phone-b', 'channel-b')
  for (const raw of ['{"t":"credit"}', '{"t":"res","id":"same","sid":"same"}', '{"t":"ev","sid":"same"}']) {
    assert.deepEqual(core.onLine({ kind: 'data', channelId: 'channel-a' }, raw).deliveries, [{ channelId: 'channel-a', to: 'device', raw }])
  }
  assert.equal(core.stats.channels, 2)
})

test('连接隔离：连接器身份、设备身份和代次缺一不可', () => {
  const core = setup()
  assert.throws(() => core.attachData('pc-2', 'phone-a', 'channel-a'), /归属/)
  assert.throws(() => core.attachData('pc-1', 'phone-b', 'channel-a'), /归属/)
  assert.throws(() => core.attachData('pc-1', 'phone-a', 'expired'), /归属/)
  assert.equal(core.channel('channel-a')?.connected, false)
})

test('连接隔离：旧连接失效不会清掉新连接，也不影响另一台设备', () => {
  const core = setup()
  core.attachData('pc-1', 'phone-b', 'channel-b')
  core.closeChannel('channel-a')
  core.openDevice('channel-new', binding('phone-a'))
  core.attachData('pc-1', 'phone-a', 'channel-new')
  assert.deepEqual(core.onLine({ kind: 'data', channelId: 'channel-a' }, 'old').deliveries, [])
  assert.equal(core.closeChannel('channel-a'), undefined)
  assert.equal(core.channelOf('pc-1', 'phone-a'), 'channel-new')
  assert.equal(core.channel('channel-b')?.connected, true)
})

test('连接隔离：首帧等待电脑连接，缓冲有硬上界', () => {
  const core = setup()
  assert.deepEqual(core.onLine({ kind: 'device', channelId: 'channel-a' }, 'hello').deliveries, [])
  assert.deepEqual(core.attachData('pc-1', 'phone-a', 'channel-a'), [{ channelId: 'channel-a', to: 'data', raw: 'hello' }])
  assert.throws(() => core.onLine({ kind: 'device', channelId: 'channel-b' }, 'x'.repeat(MAX_PENDING_BYTES + 1)), /缓冲/)
})

test('公开邀请：查询不消费授权，控制连接断开使邀请失效', () => {
  const core = createRelayCore()
  core.attachConnector('pc-1')
  const offerId = 'A'.repeat(22)
  core.registerPairing('pc-1', offerId)
  assert.equal(core.lookupPairing(offerId), 'pc-1')
  assert.equal(core.lookupPairing(offerId), 'pc-1')
  const candidate = { offerId, devPubEd: 'a'.repeat(64), devPubDh: 'b'.repeat(64), name: '手机' }
  core.openDevice('pair-channel', { connectorId: 'pc-1', deviceId: deviceIdOf(candidate), purpose: 'pairing', candidate })
  assert.deepEqual(core.detachConnector('pc-1'), ['pair-channel'])
  assert.equal(core.lookupPairing(offerId), undefined)
})

test('一次性票保留设备用途与归属，消费后失效', () => {
  const tickets = createTicketStore()
  const original = binding('phone-a')
  const ticket = tickets.issue(original)
  assert.deepEqual(tickets.consume(ticket.ticket), original)
  assert.equal(tickets.consume(ticket.ticket), undefined)
})
