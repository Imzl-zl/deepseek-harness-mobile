/**
 * 中转地址校验的"非公网"判据回归。
 *
 * ## 为什么补这个文件
 *
 * 2026-10-16 想把真机联调**从 USB 引导改成无线引导**：二维码里的 `relay:` 字段
 * 取自连接器配置（`connector/src/pairing.ts:155`），所以只要把配置指向局域网地址
 * （`ws://192.168.2.43:8787`），手机扫码就能拨到局域网的 relay —— 全程不用线。
 *
 * 但 `relayUrlOf` 的明文判据**只认 loopback**（`relay-url.ts:4` 的白名单），
 * 而手机侧 `app/lib/core/endpoint.dart` 的 `isPrivateOrLoopback` 早就扩到
 * "回环 + 私网 + CGNAT + link-local + ULA"（2026-10-14 直连落地时扩的）。
 * 两边漂了一次，症状是插件挂载直接失败：
 * 「中转必须使用 WSS；仅显式开启的本机调试允许明文」。
 *
 * ## 断言从哪来
 *
 * 期望值**不是手抄的常量**，而是手机侧那份实现的语义 —— 所以这里按同一批地址
 * 逐条对齐，谁先改谁先红。IPv4-mapped 与 `::1` 两个坑也来自手机侧注释
 * （安卓会报 `::ffff:192.168.1.1`；`::1` 前两位是 `00 01`，前缀法判不出来）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { relayUrlOf } from '../src/transport/relay-url.js'

/**
 * 非公网：回环 / 私网 / CGNAT / link-local / ULA / IPv4-mapped。
 *
 * IPv6 一律**带方括号**写（URL 规范要求；`ws://::1:8787` 连 URL 都解析不了）。
 * 实现里会把方括号剥掉再判，和手机侧的 `Uri.host` 对齐。
 */
const NON_PUBLIC = [
  'localhost',
  '127.0.0.1',
  '[::1]',
  '10.0.0.5',
  '172.16.0.1',
  '172.31.255.255',
  '192.168.2.43', // ← 手机 WiFi 地址：无线引导就卡在这一条上
  '100.64.0.1',
  '169.254.1.1',
  '[fe80::1]',
  '[fc00::1]',
  '[fd12:3456:789a::1]',
]

/** 公网：必须 wss。后三条是"差一点就进私网"的边界。 */
const PUBLIC = [
  '8.8.8.8',
  '1.1.1.1',
  '203.0.113.7',
  'example.com',
  '[2001:4860:4860::8888]',
  '[::ffff:8.8.8.8]', // mapped 但内层是公网 → 公网
  '172.32.0.1', // 172.16/12 之外
  '172.15.255.255', // 同上
  '192.169.0.1', // 192.168/16 之外
]

test('wss 任何地址都行（生产形态）', () => {
  assert.equal(relayUrlOf('wss://relay.example.com/ws/connector').hostname, 'relay.example.com')
  assert.equal(relayUrlOf('wss://192.168.2.43/ws/connector').hostname, '192.168.2.43')
})

for (const host of NON_PUBLIC) {
  test(`明文放行：${host}`, () => {
    assert.equal(relayUrlOf(`ws://${host}:8787/ws/connector`, true).hostname, host)
  })
}

/**
 * WHATWG `URL` 会归一化地址，所以这两个"另一种写法"拿不到原始形状：
 * - `[0:0:0:0:0:0:0:1]` → `hostname` 归一成 `[::1]`；
 * - `[::ffff:192.168.1.1]` → 归一成 IPv4 `192.168.1.1`。
 *
 * 判据里那两个分支**保留**：手机侧的 `Uri.host` 不做这种归一化，
 * 安卓真会报 mapped 形状（`app/lib/core/endpoint.dart` 的注释写着这件事）。
 * 这里断言的是"无论哪种写法都放行"，而不是"实现走了哪条分支"。
 */
test('IPv6 全展开形式与 IPv4-mapped：归一化之后照样放行', () => {
  assert.doesNotThrow(() => relayUrlOf('ws://[0:0:0:0:0:0:0:1]:8787/ws/connector', true))
  assert.doesNotThrow(() => relayUrlOf('ws://[::ffff:192.168.1.1]:8787/ws/connector', true))
})

for (const host of PUBLIC) {
  test(`明文拒绝：${host}`, () => {
    assert.throws(
      () => relayUrlOf(`ws://${host}:8787/ws/connector`, true),
      /必须使用 WSS/,
    )
  })
}

test('没显式开 allowInsecureLocal 时，连回环都不放行', () => {
  assert.throws(() => relayUrlOf('ws://127.0.0.1:8787/ws/connector'), /必须使用 WSS/)
})

test('地址里不许夹带凭据 / 查询 / 片段', () => {
  assert.throws(() => relayUrlOf('ws://u:p@127.0.0.1:8787/ws/connector', true), /凭据/)
  // `ws://` 不是 WHATWG 的特殊 scheme，带 `?` 且不带端口的写法连 URL 都解析不了 ——
  // 断言的是"它被拒且消息可读"，不是裸 TypeError 冒到调用方面前。
  assert.throws(
    () => relayUrlOf('ws://127.0.0.1:8787/ws/connector?x=1', true),
    /解析失败|凭据|查询|片段/,
  )
  assert.throws(() => relayUrlOf('wss://127.0.0.1:8787/ws/connector#f', true), /片段/)
})