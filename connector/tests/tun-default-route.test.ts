/**
 * 出码地址判据：**只认地址段，不猜网卡**（2026-11-24）。
 *
 * ## 这一组替代了什么
 *
 * 2026-11-06 → 2026-11-20 之间，默认上报集合是"默认路由那张网卡的 IPv4"，
 * 再用 MAC OUI 判虚拟网卡（`isVirtualMac`）把它排除。两次真机事故都出在同一处猜法上：
 *
 * - TUN 抢走默认路由 ⇒ 上报 `198.18.0.1`（手机拨不通）；
 * - hint 匹配不上 ⇒ **一条都不报** ⇒ 出码报"没有可上报的地址"。
 *
 * 用户 2026-11-24 的原话：「开了 TUN……我只需要局域网地址就行吧，什么网卡，
 * 虚拟网卡啥的，用不上吧？」—— 对，判据收成一条：**地址是不是 RFC1918 局域网 IPv4**。
 * 哪一条拨得通，只有手机拨了才知道（码里全给，手机并行拨、先通先用）。
 *
 * ## 这里钉的事实
 *
 * 1. TUN 段（`198.18/15`）、CGNAT（`100.64/10`）、IPv6、回环都不进默认集合；
 * 2. **全部**局域网 IPv4 都进（不再"只报一条"）—— 包括 VMware 的 `192.168.x.1`：
 *    那不是猜出来的，是地址段的事实；手机拨不通会自己失败，代价只是并行拨里多一条；
 * 3. 默认路由那条**只当排序**：排第一，不当判据；
 * 4. `hide` 生效、`extra` 追加，二者都不改变第 1、2 条。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { autoAdvertisedUrls, describeEndpoints } from '../src/endpoints.js'
import type { Listener } from '../src/transport/listener.js'

function fakeListener(urls: { url: string; label: string }[]): Listener {
  return { port: 8790, active: 0, urls, close: async () => {} }
}

/**
 * 2026-11-20 用户实机的网卡快照（`os.networkInterfaces()` 实际输出形态）：
 * FlClash 的 TUN、真实 WLAN、两个 VMware host-only、两条轮换出来的 IPv6 GUA。
 */
const REAL_MACHINE = [
  { url: 'ws://198.18.0.1:8790', label: 'FlClash' },
  { url: 'ws://192.168.2.75:8790', label: 'WLAN 2' },
  { url: 'ws://192.168.40.1:8790', label: 'VMware Network Adapter VMnet1' },
  { url: 'ws://192.168.235.1:8790', label: 'VMware Network Adapter VMnet8' },
  { url: 'ws://[2408:8220:7113:3604:2fe4:601d:2aa0:9348]:8790', label: 'WLAN 2' },
  { url: 'ws://[2408:8220:7113:3604:ec92:404d:2e2f:e32f]:8790', label: 'WLAN 2' },
]

const directUrls = (result: { endpoints: { kind: string; url: string }[] }): string[] =>
  result.endpoints.filter((e) => e.kind === 'direct').map((e) => e.url)

test('TUN 抢走默认路由：TUN 的 198.18 不上报，真实局域网照报', () => {
  const result = describeEndpoints({
    relayUrl: 'wss://relay.example',
    lanHint: '198.18.0.1',
    listener: fakeListener(REAL_MACHINE),
  })
  const urls = directUrls(result)
  assert.ok(urls.includes('ws://192.168.2.75:8790'), `必须带真实局域网地址，实际 ${JSON.stringify(urls)}`)
  assert.ok(!urls.includes('ws://198.18.0.1:8790'), 'TUN 不是 RFC1918，手机拨不通')
})

test('全部局域网 IPv4 都进码：VMware 的 192.168.x.1 也在（不按网卡猜）', () => {
  const urls = directUrls(describeEndpoints({ lanHint: '198.18.0.1', listener: fakeListener(REAL_MACHINE) }))
  assert.deepEqual(urls, [
    'ws://192.168.2.75:8790',
    'ws://192.168.40.1:8790',
    'ws://192.168.235.1:8790',
  ], '三条都是局域网 IPv4 —— 哪条拨得通由手机拨了才知道')
})

test('IPv6 与 CGNAT 不进默认集合（要上码得用户 `extra` 点名）', () => {
  const urls = directUrls(describeEndpoints({ listener: fakeListener(REAL_MACHINE) }))
  assert.ok(!urls.some((u) => u.includes('[')), 'IPv6 GUA 默认不上报')
  assert.ok(!urls.some((u) => u.includes('100.100.')), 'CGNAT / Tailscale 默认不上报')
})

test('`lanHint` 只当排序：拿不到 / 已过期时照样全报，且不影响成员集合', () => {
  const noHint = directUrls(describeEndpoints({ lanHint: null, listener: fakeListener(REAL_MACHINE) }))
  const staleHint = directUrls(describeEndpoints({ lanHint: '192.168.110.79', listener: fakeListener(REAL_MACHINE) }))
  assert.deepEqual(noHint, staleHint, '换网后的旧 hint 不许改变"报哪几条"')
  assert.equal(noHint.length, 3)
})

test('默认路由那条排第一（排序而不筛选）', () => {
  const urls = directUrls(describeEndpoints({ lanHint: '192.168.235.1', listener: fakeListener(REAL_MACHINE) }))
  assert.equal(urls[0], 'ws://192.168.235.1:8790', '手机先拨最可能通的那条')
  assert.equal(urls.length, 3, '排第一不等于只报一条')
})

test('段序：192.168 先于 172.16 先于 10（hint 落空时）', () => {
  const urls = directUrls(describeEndpoints({
    lanHint: null,
    listener: fakeListener([
      { url: 'ws://10.1.2.3:8790', label: 'eth1' },
      { url: 'ws://172.20.0.5:8790', label: 'eth2' },
      { url: 'ws://192.168.3.4:8790', label: 'wlan' },
    ]),
  }))
  assert.deepEqual(urls, ['ws://192.168.3.4:8790', 'ws://172.20.0.5:8790', 'ws://10.1.2.3:8790'])
})

test('只有 TUN / CGNAT / IPv6 的机器：如实一条都不报（由用户从「更多地址」点名）', () => {
  const urls = directUrls(describeEndpoints({
    listener: fakeListener([
      { url: 'ws://198.18.0.1:8790', label: 'FlClash' },
      { url: 'ws://100.100.1.2:8790', label: 'Tailscale' },
    ]),
  }))
  assert.deepEqual(urls, [], '没有局域网 IPv4 时不猜一条能拨的地址')
})

test('监听面没起：一条 direct 都不报（含用户 extra）', () => {
  const result = describeEndpoints({
    lanHint: '192.168.2.75',
    listener: null,
    advertise: new Map([['ws://192.168.2.75:8790', 'extra' as const]]),
  })
  assert.deepEqual(directUrls(result), [])
})

test('`hide` 生效，且不许因此退回去报 TUN 那条', () => {
  const urls = directUrls(describeEndpoints({
    lanHint: '198.18.0.1',
    listener: fakeListener(REAL_MACHINE),
    advertise: new Map([['ws://192.168.2.75:8790', 'hide' as const]]),
  }))
  assert.ok(!urls.includes('ws://192.168.2.75:8790'), 'hide 必须生效')
  assert.ok(!urls.includes('ws://198.18.0.1:8790'), 'hidden 之后不许退到 TUN')
  assert.ok(urls.includes('ws://192.168.40.1:8790'), '其余局域网地址照旧')
})

test('`extra` 点名 TUN 那条：仍然尊重（显式表态优先于自动判据）', () => {
  const urls = directUrls(describeEndpoints({
    lanHint: '192.168.2.75',
    listener: fakeListener(REAL_MACHINE),
    advertise: new Map([['ws://198.18.0.1:8790', 'extra' as const]]),
  }))
  assert.ok(urls.includes('ws://198.18.0.1:8790'), 'extra 是用户的显式表态')
  assert.ok(urls.includes('ws://192.168.2.75:8790'), '默认那条也在')
})

test('`autoAdvertisedUrls`：与 describe 同一条判据（成员集合，不含排序）', () => {
  const set = autoAdvertisedUrls(REAL_MACHINE)
  assert.deepEqual([...set].sort(), [
    'ws://192.168.2.75:8790',
    'ws://192.168.235.1:8790',
    'ws://192.168.40.1:8790',
  ])
  const hidden = autoAdvertisedUrls(REAL_MACHINE, new Map([['ws://192.168.2.75:8790', 'hide' as const]]))
  assert.equal(hidden.has('ws://192.168.2.75:8790'), false)
})
