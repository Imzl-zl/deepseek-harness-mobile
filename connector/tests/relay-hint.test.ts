/**
 * 二维码 relay 提示的回归（`pairing.ts` 的 `relayHintFor`）。
 *
 * ## 为什么必须有这个函数（2026-10-17 真机踩到）
 *
 * 配置里的 `relayUrl` 是**拨号地址**（中转就在本机时写环回），二维码里给的必须
 * 是**手机拨得通的地址**。历史上直接拿配置字符串塞进二维码，电脑换一次 WiFi
 * （这台从 192.168.2.43 换到 192.168.110.79）之后，手机拨存量端点全超时，
 * 重新出码也还是那个死地址。用户原话："那我电脑换 WiFi 就不行了？？"
 *
 * 规则只有三条（**不枚举网卡、不认虚拟网卡名** —— 只需要知道局域网，
 * 而局域网地址问内核要：`lan-address.ts` 的默认路由选路）：
 * - 环回 → 换成 hint（默认路由网卡的 IPv4）；
 * - 域名 → 原样（中转部署在服务器上）；
 * - 其它 IP → 原样（用户显式钉的，如中转在另一台机器上）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { relayHintFor } from '../src/pairing.js'

test('环回 → 换成默认路由的局域网地址（端口路径保留）', () => {
  assert.equal(
    relayHintFor('ws://127.0.0.1:8787/ws/connector', '192.168.110.79'),
    'ws://192.168.110.79:8787/ws/connector',
  )
  // IPv6 的 hint 要括起来，否则端口会被当成地址的一部分。
  assert.equal(
    relayHintFor('ws://127.0.0.1:8787/ws/connector', 'fd00::1'),
    'ws://[fd00::1]:8787/ws/connector',
  )
})

test('域名原样返回（中转部署在服务器上，稳定地址）', () => {
  assert.equal(
    relayHintFor('wss://relay.example.com/ws/connector', '192.168.110.79'),
    'wss://relay.example.com/ws/connector',
  )
})

test('显式 IP 原样返回（用户钉的地址，如中转在另一台机器上）', () => {
  assert.equal(
    relayHintFor('ws://192.168.1.9:8787/ws/connector', '192.168.110.79'),
    'ws://192.168.1.9:8787/ws/connector',
  )
})

test('拿不到 hint 就原样返回（不猜）', () => {
  assert.equal(
    relayHintFor('ws://127.0.0.1:8787/ws/connector', null),
    'ws://127.0.0.1:8787/ws/connector',
  )
  assert.equal(
    relayHintFor('ws://127.0.0.1:8787/ws/connector', ''),
    'ws://127.0.0.1:8787/ws/connector',
  )
})

test('不是 URL 就原样返回', () => {
  assert.equal(relayHintFor('这不是地址', '192.168.110.79'), '这不是地址')
})
