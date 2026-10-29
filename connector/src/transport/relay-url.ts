/**
 * 中转地址校验：生产只用 WSS；本机明文必须由调用方显式允许。
 *
 * ## 明文放行的判据（与手机侧**同一套**）
 *
 * `app/lib/core/endpoint.dart` 的 `isPrivateOrLoopback` 在 2026-10-14 把判据从
 * "仅回环"扩到"回环 + 私网 + CGNAT + link-local + ULA"（那次是为局域网直连铺路）。
 * **这个文件当时没跟着改**，于是两边漂了一次，症状很硬：
 *
 * - 想把二维码里的 `relay:` 指向局域网地址（无线引导，不插线）→
 *   插件在 `validate-config` 直接挂载失败：「中转必须使用 WSS」；
 * - 而手机侧对同一个地址是放行的（它认私网）。
 *
 * 判据一旦分居两处就必然再漂，所以这里的期望值由
 * `tests/relay-url-nonpublic.test.ts` 用**同一批地址**钉住两边对齐。
 * 谁先改判据，谁那边先红。
 *
 * 地址分类不引入 `node:net` / `dns`：那会把"这个域名解析到哪"扯进来，
 * 而校验要判的是**字面量写的是不是非公网**（`localhost` 是唯一被认的主机名）。
 */

/** 主机是不是"非公网"（回环 / 私网 / CGNAT / link-local / ULA）。 */
export function isNonPublicHost(host: string): boolean {
  if (host === '') return false
  // 主机名只有这一个算非公网（其余一概当公网 —— 宁可严一格）。
  if (host === 'localhost') return true

  const v4 = parseIpv4(host)
  if (v4 !== null) return ipv4IsPrivate(v4)

  // IPv4-mapped（`::ffff:192.168.1.1` / `::ffff:c0a8:101`）：按**里面的** IPv4 判。
  // 安卓会报 dotted 形式（手机侧判据吃的就是它）；而 WHATWG `URL` 会把同一地址
  // 归一成十六进制 `::ffff:c0a8:101` —— 两种都得认，否则"私网里的 mapped 端点"会被拒。
  const mapped = /^::ffff:([0-9a-fA-F]{1,4}):([0-9a-fA-F]{1,4})$/.exec(host)
  if (mapped !== null) {
    const hi = Number.parseInt(mapped[1] ?? '', 16)
    const lo = Number.parseInt(mapped[2] ?? '', 16)
    if (Number.isInteger(hi) && Number.isInteger(lo)) {
      const inner: [number, number, number, number] = [
        (hi >> 8) & 0xff,
        hi & 0xff,
        (lo >> 8) & 0xff,
        lo & 0xff,
      ]
      if (ipv4IsPrivate(inner)) return true
    }
  }
  const mappedV4 = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(host)
  if (mappedV4 !== null) {
    const dotted = mappedV4[1] ?? ''
    const inner = parseIpv4(dotted)
    return inner !== null && ipv4IsPrivate(inner)
  }

  // `::1` 的前两位是 `00 01`，前缀法判不出来，所以单独认。
  if (host === '::1' || host === '0:0:0:0:0:0:0:1') return true

  const v6 = parseIpv6Prefix(host)
  if (v6 !== null) return ipv6PrefixIsPrivate(v6)

  return false
}

/** IPv4 四段；不是 IPv4 文本时返回 `null`。 */
function parseIpv4(host: string): [number, number, number, number] | null {
  const parts = host.split('.')
  if (parts.length !== 4) return null
  const out: number[] = []
  for (const part of parts) {
    if (part === '' || part.length > 3) return null
    const value = Number(part)
    if (!Number.isInteger(value) || value < 0 || value > 255) return null
    out.push(value)
  }
  // `noUncheckedIndexedAccess` 下索引读出来是 `number | undefined`；
  // 长度已经数过是 4，所以这里逐个确认（不猜）。
  if (out.length !== 4 || out.some((n) => typeof n !== 'number')) return null
  return [out[0] as number, out[1] as number, out[2] as number, out[3] as number]
}

function ipv4IsPrivate(b: [number, number, number, number]): boolean {
  if (b[0] === 127) return true // 回环 127/8
  if (b[0] === 10) return true // 私网 10/8
  if (b[0] === 172 && b[1] >= 16 && b[1] <= 31) return true // 私网 172.16/12
  if (b[0] === 192 && b[1] === 168) return true // 私网 192.168/16
  if (b[0] === 100 && b[1] >= 64 && b[1] <= 127) return true // CGNAT 100.64/10
  if (b[0] === 169 && b[1] === 254) return true // link-local 169.254/16
  return false
}

/**
 * IPv6 只取前两个字节：我们关心的三个前缀都只看这两位
 * （`fe80::/10` / `fc00::/7`）。`::` 开头时第一段是空的，实际前缀从 `::` 后面那段起。
 */
function parseIpv6Prefix(host: string): [number, number] | null {
  if (!host.includes(':')) return null
  let head = host
  if (head.startsWith('::')) head = head.slice(2)
  const firstGroup = head.split(':')[0] ?? ''
  if (firstGroup === '') return [0, 0]
  const value = Number.parseInt(firstGroup, 16)
  if (!Number.isInteger(value) || value < 0 || value > 0xffff) return null
  return [value >> 8, value & 0xff]
}

function ipv6PrefixIsPrivate([hi, lo]: [number, number]): boolean {
  if (hi === 0 && lo === 0) return true // `::` 未指定地址
  if (hi === 0xfe && (lo & 0xc0) === 0x80) return true // link-local fe80::/10
  if ((hi & 0xfe) === 0xfc) return true // unique-local fc00::/7
  return false
}

/** 默认只用 WSS；明文分两档，必须由调用方显式允许。 */
export function relayUrlOf(
  value: string,
  allowInsecureLocal = false,
  /**
   * 允许**公网明文**（用户自部署中转、暂无域名/证书）。
   *
   * 与手机侧同一条两档判据（`app/lib/core/endpoint.dart` 的 `checkedRelayUri`）：
   * 非公网看 `allowInsecureLocal`，公网明文看这个开关。握手后每帧 AEAD，
   * 所以明文的代价是元数据可见 —— 这一档由用户显式承担。
   */
  allowInsecurePublic = false,
): URL {
  let url: URL
  try {
    url = new URL(value)
  } catch {
    // 解析不了就是配置写错了：别让裸 TypeError 冒出去，那看起来像内部 bug
    // （`ws://` 不是 WHATWG 的特殊 scheme，少写端口/写错斜杠都会走到这）。
    throw new Error(`中转地址解析失败：${value}`)
  }
  // IPv6 字面量在 `hostname` 里带方括号（`[::1]`），而判据与手机侧的
  // `Uri.host` 对齐成"不带方括号"的纯地址 —— 这里剥掉，免得两边形状不一致。
  const host = url.hostname.startsWith('[') && url.hostname.endsWith(']')
      ? url.hostname.slice(1, -1)
      : url.hostname
  if (url.username !== '' || url.password !== '' || url.hash !== '' || url.search !== '') {
    throw new Error('中转地址不能包含凭据、查询参数或片段')
  }
  const plaintextAllowed =
    (allowInsecureLocal && isNonPublicHost(host)) || allowInsecurePublic
  if (url.protocol !== 'wss:' && !(plaintextAllowed && url.protocol === 'ws:')) {
    throw new Error('中转必须使用 WSS；明文仅限非公网地址，或用户确认过的自部署中转')
  }
  return url
}