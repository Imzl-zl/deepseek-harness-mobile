/**
 * 「直连开着，但没有一条可报的局域网地址」时**说哪句话**（2026-11-24 收成三档）。
 *
 * ## 为什么单独钉这一组
 *
 * 2026-11-20 用户看到的是一句混账话：
 * 「直连监听已启动，但没有可上报的地址（默认路由不可用，或主地址已被隐藏）」——
 * 他的情形两种都不是（默认路由被 TUN 抢走，主地址也没被藏）。照那句话查不出东西。
 *
 * 修文案时又踩了一次同类错：用"有没有非虚拟候选"判最后一档，于是
 * **只有 Tailscale（CGNAT）或纯 IPv6 的机器**会被告诉「候选地址都被你删掉了」。
 *
 * 现在文案与判据在**同一个函数**里（`endpoints.ts` 的 `noLanAddressReason`），
 * 这里直接调它 —— 不复制一份分档逻辑，否则测试绿着而线上说另一句话。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { autoAdvertisedUrls, isLanAddress, noLanAddressReason } from '../src/endpoints.js'

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

test('一条候选都没有：说"没枚举到网卡地址"', () => {
  assert.match(noLanAddressReason([]), /没有枚举到任何网卡地址/)
})

test('只有组网地址（CGNAT）+ IPv6：说"没有局域网 IPv4"，**不是**"被你删掉了"', () => {
  const urls = [
    { url: 'ws://100.100.1.2:8790', label: 'Tailscale' },
    { url: 'ws://[2408:8220::1]:8790', label: 'WLAN' },
  ]
  assert.deepEqual([...autoAdvertisedUrls(urls)], [], '确实没有可上报的局域网地址')
  const reason = noLanAddressReason(urls)
  assert.match(reason, /没有局域网 IPv4/)
  assert.equal(/删掉/.test(reason), false, '一个都没删过，说"被删掉"是错话')
})

test('只有 TUN 段：同样说"没有局域网 IPv4"（不再有"虚拟网卡"这一档）', () => {
  const urls = [{ url: 'ws://198.18.0.1:8790', label: 'FlClash' }]
  assert.deepEqual([...autoAdvertisedUrls(urls)], [])
  assert.match(noLanAddressReason(urls), /没有局域网 IPv4/)
})

test('有局域网 IPv4 却一条都没上报：只可能是被 `hide` 掉了', () => {
  const urls = [{ url: 'ws://192.168.2.75:8790', label: 'WLAN 2' }]
  assert.match(noLanAddressReason(urls), /「上报给手机的地址」里删掉了/)
  // 证明确实"有局域网地址" —— 否则上面那句就是猜出来的。
  assert.equal(autoAdvertisedUrls(urls).has('ws://192.168.2.75:8790'), true)
})
