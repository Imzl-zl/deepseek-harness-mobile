/**
 * 上报地址判据：**TUN 抢走默认路由后，真实局域网地址仍然要上报**。
 *
 * ## 为什么这一组用例存在
 *
 * 2026-11-06 把默认上报集合收成"默认路由那张网卡的 IPv4"
 * （`defaultDirectUrls`），代价里写明："默认路由不是手机所在局域网时
 * （双网卡、默认路由走 WAN），直连默认不生效"。当时把那种情形当作**少数派代价**。
 *
 * 2026-11-20 用户的实机（原话："我确实开了代理的TUN这还影响吗？那这咋办？
 * 我确实需要开代理啊？"）证明它**不是少数派**：
 *
 * ```
 * defaultRouteIPv4 = 198.18.0.1        ← FlClash TUN 虚拟网卡
 * WLAN 2  IPv4      192.168.2.75       ← 真正的局域网
 * VMware VMnet1/8   192.168.40.1 / 192.168.235.1
 * 候选池共 6 条
 * ```
 *
 * 旧判据下这台机器有两个坏分支：
 * 1. TUN 的 `198.18.0.1` 在候选池里 ⇒ 上报**它** ⇒ 手机拨不通；
 * 2. `lanHint` 刷新后匹配不上（代理开关切换）⇒ 候选有 6 条、不满足"只有 1 条"
 *    ⇒ **一条都不报** ⇒ 出码失败「没有可上报的地址」。
 *
 * 这两条在**同一天**都出现过，所以下面每个分支各有一组用例。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { defaultDirectUrls, describeEndpoints } from '../src/endpoints.js'
import type { Listener } from '../src/transport/listener.js'

function fakeListener(urls: { url: string; label: string; virtual?: boolean }[]): Listener {
  return { port: 8790, active: 0, urls, close: async () => {} }
}

/**
 * 2026-11-20 用户实机的网卡快照（`os.networkInterfaces()` 实际输出）。
 *
 * 形状照 `transport/listener.ts` 的 `dialableUrls`：跳过 internal、跳过
 * `fe80` 开头的 IPv6、IPv4 排在前。FlClash 的 TUN 网卡也在里面 ——
 * 它对内核是普通网卡，枚举分不出来。
 *
 * `virtual` 来自 MAC 实测（`isVirtualMac`）：
 * - FlClash TUN → `00:00:00:00:00:00`；
 * - VMware → `00:50:56:c0:00:01` / `00:50:56:c0:00:08`；
 * - 真实 WLAN 2 → `d0:76:02:c9:f5:46`（真实网卡厂商 OUI）。
 */
const REAL_MACHINE = [
  { url: 'ws://198.18.0.1:8790', label: 'FlClash', virtual: true },
  { url: 'ws://192.168.2.75:8790', label: 'WLAN 2' },
  { url: 'ws://192.168.40.1:8790', label: 'VMware Network Adapter VMnet1', virtual: true },
  { url: 'ws://192.168.235.1:8790', label: 'VMware Network Adapter VMnet8', virtual: true },
  { url: 'ws://[2408:8220:7113:3604:2fe4:601d:2aa0:9348]:8790', label: 'WLAN 2' },
  { url: 'ws://[2408:8220:7113:3604:ec92:404d:2e2f:e32f]:8790', label: 'WLAN 2' },
]

const directUrls = (result: { endpoints: { kind: string; url: string }[] }): string[] =>
  result.endpoints.filter((e) => e.kind === 'direct').map((e) => e.url)

// ---- 分支 ①：TUN 抢走默认路由（上报了拨不通的地址）----

test('TUN 抢走默认路由：上报真实局域网，**不**上报 TUN 那条', () => {
  const result = describeEndpoints({
    relayUrl: 'wss://relay.example',
    lanHint: '198.18.0.1',
    listener: fakeListener(REAL_MACHINE),
  })
  const urls = directUrls(result)
  assert.ok(
    urls.includes('ws://192.168.2.75:8790'),
    `必须带真实局域网地址，实际 ${JSON.stringify(urls)}`,
  )
  assert.ok(
    !urls.includes('ws://198.18.0.1:8790'),
    'TUN 网卡地址手机拨不通，不该进默认上报集合',
  )
})

test('TUN 抢走默认路由时，VMware 虚拟网卡也不该借机上码', () => {
  const result = describeEndpoints({
    lanHint: '198.18.0.1',
    listener: fakeListener(REAL_MACHINE),
  })
  const urls = directUrls(result)
  assert.ok(!urls.some((u) => u.includes('192.168.40.1')), 'VMnet1 不该上报')
  assert.ok(!urls.some((u) => u.includes('192.168.235.1')), 'VMnet8 不该上报')
})

// ---- 分支 ②：lanHint 拿不到 / 已过期（一条都不报，出码直接失败）----

test('`lanHint` 为 null（选路失败 / 代理切换中）：多候选也要选出局域网地址', () => {
  const result = describeEndpoints({
    lanHint: null,
    listener: fakeListener(REAL_MACHINE),
  })
  const urls = directUrls(result)
  assert.deepEqual(
    urls,
    ['ws://192.168.2.75:8790'],
    '这就是用户截图里「没有可上报的地址」的那条路 —— 候选明明有可拨的',
  )
})

test('`lanHint` 是过期旧地址（换网后没刷新）：仍然选中真实局域网', () => {
  const result = describeEndpoints({
    lanHint: '192.168.110.79', // 上一张网的地址，这台机器上已不存在
    listener: fakeListener(REAL_MACHINE),
  })
  assert.deepEqual(directUrls(result), ['ws://192.168.2.75:8790'])
})

// ---- 不回归：原来那几条行为必须还在 ----

test('默认路由就是局域网时行为不变（仍只报它一条）', () => {
  const result = describeEndpoints({
    lanHint: '192.168.2.75',
    listener: fakeListener(REAL_MACHINE),
  })
  assert.deepEqual(directUrls(result), ['ws://192.168.2.75:8790'])
})

test('单网卡机器行为不变', () => {
  const urls = [{ url: 'ws://10.0.0.2:8790', label: 'eth0' }]
  assert.deepEqual([...defaultDirectUrls(urls, null)], ['ws://10.0.0.2:8790'])
})

test('只有虚拟网卡可用时**不猜**：宁可不报，也不给一条拨不通的地址', () => {
  // 一台只有 TUN + VMware 的机器（Tailscale 独占、无真实局域网）。
  // 旧判据会报 TUN 那条；新判据不许退化成"随便挑一条"。
  const result = describeEndpoints({
    listener: fakeListener([
      { url: 'ws://198.18.0.1:8790', label: 'FlClash', virtual: true },
      { url: 'ws://192.168.40.1:8790', label: 'VMware VMnet1', virtual: true },
    ]),
  })
  assert.deepEqual(
    directUrls(result),
    [],
    '没有真实局域网地址时如实不上报，由用户从「更多地址」点名',
  )
})

test('监听面没起：一条 direct 都不报（与原行为一致）', () => {
  const result = describeEndpoints({
    lanHint: '192.168.2.75',
    listener: null,
    advertise: new Map([['ws://192.168.2.75:8790', 'extra' as const]]),
  })
  assert.deepEqual(directUrls(result), [])
})

test('用户 `hide` 掉真实局域网后：不许自动挑回 TUN 那条来顶替', () => {
  const result = describeEndpoints({
    lanHint: '198.18.0.1',
    listener: fakeListener(REAL_MACHINE),
    advertise: new Map([['ws://192.168.2.75:8790', 'hide' as const]]),
  })
  const urls = directUrls(result)
  assert.ok(!urls.includes('ws://192.168.2.75:8790'), 'hide 必须生效')
  assert.ok(!urls.includes('ws://198.18.0.1:8790'), 'hidden 之后不许退到 TUN')
})

test('用户 `extra` 点名 TUN 那条：仍然尊重（显式表态优先于自动判据）', () => {
  const result = describeEndpoints({
    lanHint: '192.168.2.75',
    listener: fakeListener(REAL_MACHINE),
    advertise: new Map([['ws://198.18.0.1:8790', 'extra' as const]]),
  })
  const urls = directUrls(result)
  assert.ok(urls.includes('ws://198.18.0.1:8790'), 'extra 是用户的显式表态')
  assert.ok(urls.includes('ws://192.168.2.75:8790'), '默认那条也在')
})
