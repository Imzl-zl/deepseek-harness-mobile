/**
 * 传输通道注册表（`transport/channels.ts`）的回归。
 *
 * 2026-10-17 用户原话：「不是有两中方式为啥就一个开关？……后面我要是再加新的方式
 * 也就一个开关吗？」。传输面因此从"一把 startTransport"改成**按方式分的注册表**，
 * 管理面与 UI 都按它枚举。这里钉住的正是那件事的不变量：
 *
 * 1. **停一条不碰另一条**（这是"两个开关"的实质，不是两个按钮调同一个函数）；
 * 2. **未知 id 不当成功**（静默 no-op 会让界面显示"已启动"而什么都没发生）；
 * 3. **启动失败原样抛出**（端口被占要让操作者看见原因，而不是假成功）；
 * 4. **加一种方式只是加一个端口**（"形状不变"的可执行证明）。
 *
 * 端口全是测试替身 —— 真的起停在 `index.ts` 的装配里（`tests/listener.test.ts`
 * 与真机组覆盖 socket 级行为）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  createTransportChannels,
  describeChannels,
  DIRECT_UNCONFIGURED,
  type ChannelPort,
} from '../src/transport/channels.js'

/** 一个可编程的假通道：记调用次数，可按配置抛错。 */
function fakePort(spec: {
  id: string
  label?: string
  running?: () => boolean
  detail?: () => string
  connected?: () => boolean
  failStart?: boolean
}): ChannelPort & { starts: number; stops: number } {
  const port = {
    id: spec.id,
    label: spec.label ?? spec.id,
    running: spec.running ?? ((): boolean => false),
    detail: spec.detail ?? ((): string => ''),
    ...(spec.connected === undefined ? {} : { connected: spec.connected }),
    starts: 0,
    stops: 0,
    async start() {
      port.starts += 1
      if (spec.failStart === true) throw new Error('listen EADDRINUSE: 8790')
    },
    async stop() { port.stops += 1 },
  }
  return port
}

test('channels()：按注册顺序给出每个通道的状态（管理面与 UI 的唯一数据源）', () => {
  const relay = fakePort({ id: 'relay', label: '中转拨号', running: () => true, detail: () => 'ws://127.0.0.1:8787' })
  const direct = fakePort({ id: 'direct', label: '直连监听', running: () => false, detail: () => DIRECT_UNCONFIGURED })
  const channels = createTransportChannels([relay, direct])

  assert.deepEqual(channels.channels(), [
    { id: 'relay', label: '中转拨号', running: true, detail: 'ws://127.0.0.1:8787' },
    { id: 'direct', label: '直连监听', running: false, detail: DIRECT_UNCONFIGURED },
  ])
})

test('channels()：只有拨出去的通道给 connected；监听面不给（它没有"连上"这个事实）', () => {
  // `running` 与 `connected` 是两件事：`start()` 之后到 open 之前，对象在跑、连接不在。
  const relay = fakePort({ id: 'relay', running: () => true, connected: () => false, detail: () => 'ws://r' })
  const direct = fakePort({ id: 'direct', running: () => true, detail: () => '0.0.0.0:8790' })
  const [relayState, directState] = createTransportChannels([relay, direct]).channels()
  assert.equal(relayState?.connected, false, '在跑但没连上')
  assert.equal('connected' in (directState ?? {}), false, '直连没有这个键，而不是"false"')
})

test('setChannel：起停只打到目标通道，另一条原样不动', async () => {
  const relay = fakePort({ id: 'relay' })
  const direct = fakePort({ id: 'direct' })
  const channels = createTransportChannels([relay, direct])

  await channels.setChannel('direct', false)
  assert.equal(direct.stops, 1)
  assert.equal(relay.stops, 0, '停直连不碰中转')
  assert.equal(relay.starts, 0)

  await channels.setChannel('relay', true)
  assert.equal(relay.starts, 1)
  assert.equal(direct.starts, 0, '起中转不碰直连')
})

test('setChannel：未知 id 抛出，不当成功', async () => {
  const relay = fakePort({ id: 'relay' })
  const channels = createTransportChannels([relay])
  await assert.rejects(() => channels.setChannel('tailscale', true), /未知传输通道：tailscale/)
  assert.equal(relay.starts, 0, '不认识的 id 不该动任何通道')
})

test('setChannel：启动失败原样抛出（端口被占），通道保持未运行', async () => {
  const direct = fakePort({ id: 'direct', failStart: true })
  const channels = createTransportChannels([direct])
  await assert.rejects(() => channels.setChannel('direct', true), /EADDRINUSE/)
  // 端口自己没起来，running 仍为 false —— 管理面据此继续显示"未运行"。
  assert.equal(channels.channels()[0]?.running, false)
})

test('加一种方式只是加一个端口：注册表现长、起停照旧', async () => {
  const relay = fakePort({ id: 'relay', label: '中转拨号' })
  const direct = fakePort({ id: 'direct', label: '直连监听' })
  const tailscale = fakePort({ id: 'tailscale', label: 'Tailscale' })
  const channels = createTransportChannels([relay, direct, tailscale])

  assert.deepEqual(channels.channels().map((state) => state.id), ['relay', 'direct', 'tailscale'])
  await channels.setChannel('tailscale', true)
  assert.equal(tailscale.starts, 1)
  assert.equal(relay.starts, 0)
  assert.equal(direct.starts, 0)
})

test('describeChannels：一行日志里每条通道一个词', () => {
  const relay = fakePort({ id: 'relay', label: '中转拨号', running: () => true })
  const direct = fakePort({ id: 'direct', label: '直连监听', running: () => false })
  assert.equal(
    describeChannels(createTransportChannels([relay, direct]).channels()),
    '中转拨号:运行中 直连监听:未运行',
  )
})
