/**
 * 报错文案必须**按事实分档**，不能靠"真实候选数 > 0"猜。
 *
 * ## 为什么单独钉这一组
 *
 * 2026-11-20 的原始故障里，用户看到的是一句混账话：
 * 「直连监听已启动，但没有可上报的地址（默认路由不可用，或主地址已被隐藏）」——
 * 他的情形两种都不是（默认路由被 TUN 抢走，主地址也没被藏）。照那句话查不出东西。
 *
 * 修文案时又踩了一次同一类错：第一版用"有没有非虚拟候选"判最后一档，
 * 于是**一台只有 Tailscale（CGNAT）或纯 IPv6 的机器**会被告诉
 * 「候选地址都被你删掉了」—— 同样是一句与事实相反的话。
 *
 * 所以这里钉的是：**文案的分档判据必须与 `defaultDirectUrls` 同源**
 * （都用 `isLanAddress`），且每一种候选形态都有各自的说法。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { defaultDirectUrls, isLanAddress } from '../src/endpoints.js'

/** `defaultDirectUrls` 为空时，"该说哪句"的那一档（与 `index.ts` 同一条判据）。 */
function reasonFor(urls: { url: string; label: string; virtual?: boolean }[]): string {
  if (urls.length === 0) return 'no-nic'
  if (urls.every((entry) => entry.virtual === true)) return 'virtual-only'
  if (urls.some((entry) => isLanAddress(entry.url))) return 'hidden'
  return 'no-lan-ipv4'
}

test('`isLanAddress`：只认 RFC1918 三段', () => {
  assert.equal(isLanAddress('ws://192.168.2.75:8790'), true)
  assert.equal(isLanAddress('ws://10.0.0.2:8790'), true)
  assert.equal(isLanAddress('ws://172.16.0.1:8790'), true)
  assert.equal(isLanAddress('ws://172.31.255.254:8790'), true)
  assert.equal(isLanAddress('wss://192.168.1.4:8790/x'), true)
  // 不是局域网的几类（每一类都曾经被误当成"可拨"）
  assert.equal(isLanAddress('ws://198.18.0.1:8790'), false, 'TUN 段')
  assert.equal(isLanAddress('ws://100.100.1.2:8790'), false, 'CGNAT / Tailscale')
  assert.equal(isLanAddress('ws://172.32.0.1:8790'), false, '172.32 出了 172.16/12')
  assert.equal(isLanAddress('ws://127.0.0.1:8790'), false, '回环')
  assert.equal(isLanAddress('ws://[2408:8220::1]:8790'), false, 'IPv6')
  assert.equal(isLanAddress('wss://relay.example/x'), false, '域名')
})

test('只有组网地址（CGNAT）+ IPv6：文案说"没有局域网 IPv4"，**不是**"被你删掉了"', () => {
  const urls = [
    { url: 'ws://100.100.1.2:8790', label: 'Tailscale' },
    { url: 'ws://[2408:8220::1]:8790', label: 'WLAN' },
  ]
  assert.deepEqual([...defaultDirectUrls(urls, null)], [], '确实选不出可上报地址')
  assert.equal(
    reasonFor(urls),
    'no-lan-ipv4',
    '真实候选在、但一条都不是局域网 IPv4 —— 说"被删掉了"是错话',
  )
})

test('候选全是虚拟网卡：文案走"虚拟网卡"那一档', () => {
  const urls = [
    { url: 'ws://198.18.0.1:8790', label: 'FlClash', virtual: true },
    { url: 'ws://192.168.40.1:8790', label: 'VMware', virtual: true },
  ]
  assert.deepEqual([...defaultDirectUrls(urls, null)], [])
  assert.equal(reasonFor(urls), 'virtual-only')
})

test('有局域网 IPv4 却选不出来：只可能是被 hide 掉了', () => {
  // `defaultDirectUrls` 不读 advertise（hide 在 `describeEndpoints` 里生效），
  // 所以这里模拟"过滤之后已无可用项"的输入形态。
  const urls = [{ url: 'ws://192.168.2.75:8790', label: 'WLAN 2' }]
  assert.equal(reasonFor(urls), 'hidden', '有局域网 IPv4 时不说"没有局域网 IPv4"')
  // 单候选本来会被报出来，所以这条断言的是"分档判据"，不是"没选出来"。
  assert.deepEqual([...defaultDirectUrls(urls, null)], ['ws://192.168.2.75:8790'])
})

test('一条候选都没有：文案走"没枚举到网卡"', () => {
  assert.equal(reasonFor([]), 'no-nic')
})
