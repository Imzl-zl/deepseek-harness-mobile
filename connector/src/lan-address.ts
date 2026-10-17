/**
 * 本机的**局域网地址**（默认路由那张网卡的 IPv4）。
 *
/// ## 为什么是"问内核"而不是枚举网卡（2026-10-17 用户点醒）
///
/// 二维码与端点自报都需要一个"手机拨得通的地址"。我第一反应是枚举
/// `os.networkInterfaces()` 再按网卡名过滤虚拟网卡（VMware/Docker…）——
/// 又脆又绕。**真正的问题只有一个：手机和电脑在同一局域网**，而"局域网
/// 地址"内核本来就知道：把一个 UDP socket 连到任意外部地址（**不发包**，
/// 只是让内核选路），它的本地地址就是默认路由网卡上的 IPv4。
///
/// 一台机器两张网时（这台：以太网 192.168.2.x + WiFi 192.168.110.x），
/// 默认路由就是"主要那张网"—— 手机连的通常正是它。枚举 + 猜网卡名反而
/// 会抓到 VMware 虚拟网卡（手机拨不通，每个超时 10 秒）。
///
/// 拿不到（没有默认路由的 IPv4、 socket 被禁）就回 `null` —— 调用方
/// 退回"把配置里的地址原样用"，那至少是用户写的，比猜诚实。
 */
import dgram from 'node:dgram'
import net from 'node:net'

/**
 * 默认路由网卡上的 IPv4；拿不到回 `null`。
 *
 * **不发真实流量**：UDP `connect` 只做选路，`8.8.8.8:80` 不可达也不影响
 * 本地地址的读取（socket 立即关掉）。
 */
export function defaultRouteIPv4(): Promise<string | null> {
  return new Promise((resolve) => {
    let socket: dgram.Socket
    try {
      socket = dgram.createSocket('udp4')
    } catch {
      resolve(null)
      return
    }
    let settled = false
    const done = (value: string | null): void => {
      if (settled) return
      settled = true
      try {
        socket.close()
      } catch {
        // 关失败无所谓：地址已经读到了
      }
      resolve(value)
    }
    socket.once('error', () => done(null))
    socket.connect(80, '8.8.8.8', () => {
      const address = socket.address()?.address
      done(net.isIP(address ?? '') === 4 ? (address as string) : null)
    })
  })
}
