/**
 * 端点自报面的单测（`endpoint.describe`，契约 §5.7 / §14.6）。
 *
 * ## 为什么这几条要钉
 *
 * 1. **顺序即偏好**：direct 先于 relay。顺序反了不会报错，只会让手机上
 *    "同一网络"排在"中转"后面 —— 于是用户每次都得手动挑，而功能看着是好的。
 * 2. **没有监听面就一条 direct 都不给**：否则手机上会多一个必然拨不通的端点，
 *    而它会和真端点混在同一个列表里，用户分不出哪个是假的。
 * 3. **地址是实际绑定的那个**，不是配置里写的字符串：配 `0.0.0.0` 时后者
 *    根本不是可拨地址。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { describeEndpoints } from '../src/endpoints.js'
import type { Listener } from '../src/transport/listener.js'

function fakeListener(urls: { url: string; label: string }[]): Listener {
  return {
    port: 8788,
    active: 0,
    urls,
    close: async () => {},
  }
}

test('direct 先于 relay（顺序即偏好）', () => {
  const result = describeEndpoints({
    relayUrl: 'wss://relay.example',
    listener: fakeListener([{ url: 'ws://192.168.1.5:8788', label: 'Wi-Fi' }]),
  })
  assert.deepEqual(result.endpoints, [
    { kind: 'direct', url: 'ws://192.168.1.5:8788', label: 'Wi-Fi' },
    { kind: 'relay', url: 'wss://relay.example', label: '中转' },
  ])
})

test('没有监听面：一条 direct 都不给（不许造可拨地址）', () => {
  const result = describeEndpoints({ relayUrl: 'wss://relay.example', listener: null })
  assert.deepEqual(result.endpoints, [
    { kind: 'relay', url: 'wss://relay.example', label: '中转' },
  ])
})

test('没有中转地址（只配了直连）：只有 direct', () => {
  const result = describeEndpoints({
    relayUrl: undefined,
    listener: fakeListener([{ url: 'ws://10.0.0.2:8788', label: 'eth0' }]),
  })
  assert.deepEqual(result.endpoints, [
    { kind: 'direct', url: 'ws://10.0.0.2:8788', label: 'eth0' },
  ])
})

test('空 label 不上线（它不是身份，缺了让手机自己造）', () => {
  const result = describeEndpoints({
    relayUrl: 'wss://relay.example',
    listener: fakeListener([{ url: 'ws://10.0.0.2:8788', label: '' }]),
  })
  assert.deepEqual(result.endpoints[0], { kind: 'direct', url: 'ws://10.0.0.2:8788' })
})

test('多个网卡就报多条（切网卡时手机侧列表自己变）', () => {
  const result = describeEndpoints({
    relayUrl: 'wss://relay.example',
    listener: fakeListener([
      { url: 'ws://192.168.1.5:8788', label: 'Wi-Fi' },
      { url: 'ws://100.100.1.2:8788', label: 'Tailscale' },
    ]),
  })
  assert.equal(result.endpoints.length, 3)
  assert.deepEqual(
    result.endpoints.filter((e) => e.kind === 'direct').map((e) => e.url),
    ['ws://192.168.1.5:8788', 'ws://100.100.1.2:8788'],
  )
})

test('中转地址为空串当没有（装配层的兜底不该变成一条假端点）', () => {
  const result = describeEndpoints({ relayUrl: '', listener: null })
  assert.deepEqual(result.endpoints, [])
})
