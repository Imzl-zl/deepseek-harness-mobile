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

test('多个网卡且没有默认路由提示：仍选出**局域网 IPv4**，不选 CGNAH/组网地址', () => {
  // 2026-11-20 改：旧判据在这里"一条都不报"（多候选不猜）。
  // 但 `100.100.1.2` 是 Tailscale（CGNAT 段 `100.64/10`），手机在普通 WiFi 下
  // 拨不通；而 `192.168.1.5` 是真局域网 —— 这不是"猜"，是**地址自己的事实**。
  // 不选它的后果就是用户截图里那句「没有可上报的地址」。
  const result = describeEndpoints({
    relayUrl: 'wss://relay.example',
    listener: fakeListener([
      { url: 'ws://192.168.1.5:8788', label: 'Wi-Fi' },
      { url: 'ws://100.100.1.2:8788', label: 'Tailscale' },
    ]),
  })
  assert.deepEqual(
    result.endpoints.filter((e) => e.kind === 'direct').map((e) => e.url),
    ['ws://192.168.1.5:8788'],
    '选真局域网地址；Tailscale 的 CGNAT 地址要用户点名 extra 才上报',
  )
})

test('只有一个候选时默认报它（显式绑定 / 单网卡机器）', () => {
  const result = describeEndpoints({
    relayUrl: 'wss://relay.example',
    listener: fakeListener([{ url: 'ws://10.0.0.2:8788', label: 'eth0' }]),
  })
  assert.deepEqual(
    result.endpoints.filter((e) => e.kind === 'direct').map((e) => e.url),
    ['ws://10.0.0.2:8788'],
  )
})

test('全部局域网 IPv4 都上报，默认路由那条排第一（2026-11-24 起不再"只报一条"）', () => {
  // 为什么改：只报一条就必须猜"哪条对"，而哪条拨得通只有手机知道。
  // 猜错的表现是"码里写着死地址"或"明明有局域网却说没有"（2026-11-20 / 2026-11-24）。
  const result = describeEndpoints({
    relayUrl: 'wss://relay.example',
    lanHint: '192.168.110.79',
    listener: fakeListener([
      { url: 'ws://192.168.40.1:8788', label: 'VMware' },
      { url: 'ws://192.168.110.79:8788', label: 'WLAN 2' },
      { url: 'ws://192.168.2.41:8788', label: '以太网' },
    ]),
  })
  assert.deepEqual(
    result.endpoints.filter((e) => e.kind === 'direct').map((e) => e.url),
    ['ws://192.168.110.79:8788', 'ws://192.168.40.1:8788', 'ws://192.168.2.41:8788'],
    'hint 那条排第一；其余局域网地址照报（手机并行拨，先通先用）',
  )
})

test('relay 条目用实时提示：配置写环回时上报手机可达地址', () => {
  const result = describeEndpoints({
    relayUrl: 'ws://127.0.0.1:8787/ws/connector',
    lanHint: '192.168.110.79',
    listener: null,
  })
  assert.deepEqual(
    result.endpoints,
    [{ kind: 'relay', url: 'ws://192.168.110.79:8787/ws/connector', label: '中转' }],
    '环回地址手机拨不进来；自报与二维码必须同一个答案',
  )
})

test('中转地址为空串当没有（装配层的兜底不该变成一条假端点）', () => {
  const result = describeEndpoints({ relayUrl: '', listener: null })
  assert.deepEqual(result.endpoints, [])
})

test('监听面没起：`extra` 也一条都不报（否则二维码会宣称"局域网可用"）', () => {
  // 2026-11-14 真机验收踩到：直连监听停了，但 `extra` 里点名的那条地址
  // 照旧进上报集合 ⇒ `lanAvailable` 为真、二维码带着一条拨不通的局域网地址。
  // `extra` 的语义是"额外上报哪几条"，不是"凭空造一条能拨的路"。
  const result = describeEndpoints({
    relayUrl: 'wss://relay.example',
    listener: null,
    lanHint: '192.168.110.79',
    advertise: new Map([['ws://192.168.2.41:18791', 'extra' as const]]),
  })
  assert.deepEqual(
    result.endpoints.filter((e) => e.kind === 'direct'),
    [],
    '没在监听就没有可拨的直连地址 —— 用户点名也不该让它上码',
  )
})
