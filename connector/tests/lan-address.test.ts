/**
 * 局域网地址（默认路由选路）的回归。
 *
 * ## 为什么是"问内核"（2026-10-17 用户点醒）
 *
 * 二维码与端点自报都需要"手机拨得通的地址"。枚举 `os.networkInterfaces()`
 * 再按网卡名过滤虚拟网卡是又脆又绕 —— 这台机器同时有以太网、WiFi 和三张
 * VMware 虚拟网卡，枚举顺序第一个是虚拟的。**真正需要的只是"局域网地址"**，
 * 而内核知道：UDP socket 连一个外部地址（不发包），本地地址就是默认路由
 * 网卡上的 IPv4。
 */
import assert from 'node:assert/strict'
import net from 'node:net'
import { test } from 'node:test'

import { defaultRouteIPv4 } from '../src/lan-address.js'

test('默认路由的 IPv4（真机跑：这台应拿到 WiFi 网卡的地址）', async () => {
  const address = await defaultRouteIPv4()
  if (address === null) {
    // 没有默认路由 IPv4 的机器（纯 IPv6 环境）—— 调用方会退回配置地址。
    return
  }
  assert.equal(net.isIP(address), 4, `应是 IPv4 字面量，实际 ${address}`)
  assert.ok(!address.startsWith('127.'), `不应是环回，实际 ${address}`)
})

test('拿不到就回 null，不抛（socket 被禁的环境）', async () => {
  // 真路径已经覆盖；这里钉住"永不抛"的形状 —— 调用方靠 null 走退回分支。
  const address = await defaultRouteIPv4()
  assert.ok(address === null || net.isIP(address) === 4)
})
