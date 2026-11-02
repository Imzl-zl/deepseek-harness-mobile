/**
 * 浏览器会话的"值"这一层：cookie 名、令牌生成、摘要、CSRF 派生、来源地址。
 *
 * 不碰数据库、不碰 HTTP 响应 —— 那些在 `face.ts` 与 `server.ts`。
 * 这样 cookie 的序列化与 CSRF 的派生可以脱离网络测。
 */
import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto'

export const SESSION_COOKIE = 'dsh_relay_session'
export const CSRF_COOKIE = 'dsh_relay_csrf'

/** 会话令牌：256 位随机，base64url。 */
export function newSessionToken(): string {
  return randomBytes(32).toString('base64url')
}

/** 库里只存它。 */
export function hashToken(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex')
}

/**
 * CSRF 值由 `sessionId` + 库里的密钥派生，**不另存一列**。
 *
 * 双提交：cookie 里放一份给 JS 读，请求头里再放同一份；服务端用 sessionId 重算，
 * 两者都要对。这样即使攻击者能让浏览器带上 cookie，也读不到 csrf cookie 的值
 * （跨站读不到同站 cookie），头就补不出来。
 */
export function csrfOf(secret: string, sessionId: string): string {
  return createHmac('sha256', secret).update(`csrf:${sessionId}`, 'utf8').digest('base64url')
}

export function safeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a, 'utf8')
  const right = Buffer.from(b, 'utf8')
  return left.length === right.length && timingSafeEqual(left, right)
}

/** 解析 `Cookie` 头。重复名取第一个（浏览器不会发重复名，除非有人手工构造）。 */
export function parseCookies(header: string | undefined): Record<string, string> {
  const out: Record<string, string> = {}
  if (header === undefined) return out
  for (const part of header.split(';')) {
    const index = part.indexOf('=')
    if (index <= 0) continue
    const name = part.slice(0, index).trim()
    const value = part.slice(index + 1).trim()
    if (name !== '' && out[name] === undefined) out[name] = value
  }
  return out
}

export interface CookieOptions {
  secure: boolean
  maxAgeSeconds: number
  httpOnly: boolean
}

export function serializeCookie(name: string, value: string, options: CookieOptions): string {
  const parts = [
    `${name}=${value}`,
    'Path=/',
    `Max-Age=${Math.max(0, Math.floor(options.maxAgeSeconds))}`,
    'SameSite=Lax',
  ]
  if (options.httpOnly) parts.push('HttpOnly')
  if (options.secure) parts.push('Secure')
  return parts.join('; ')
}

export function clearCookie(name: string, secure: boolean, httpOnly: boolean): string {
  return serializeCookie(name, '', { secure, maxAgeSeconds: 0, httpOnly })
}

/**
 * 真实来源地址。
 *
 * **`trustProxy` 默认关**：反代之后 `socket.remoteAddress` 全是反代地址，按 IP 限流
 * 会把所有人并成一个桶（`rate-limit.ts` 的头注已经写过这个坑）。打开之后只认
 * `X-Real-IP`（推荐，Caddy 用 `header_up X-Real-IP {remote_host}` 覆盖），
 * 没有就取 `X-Forwarded-For` 的第一段。
 *
 * 这里**不自动信任任何头**：信任是部署决定，写进配置，不靠"看起来像代理"。
 */
export function clientIpOf(
  headers: Record<string, string | string[] | undefined>,
  remoteAddress: string | undefined,
  trustProxy: boolean,
): string {
  if (trustProxy) {
    const real = headers['x-real-ip']
    const realValue = Array.isArray(real) ? real[0] : real
    if (typeof realValue === 'string' && realValue.trim() !== '') return realValue.trim()
    const forwarded = headers['x-forwarded-for']
    const forwardedValue = Array.isArray(forwarded) ? forwarded[0] : forwarded
    if (typeof forwardedValue === 'string') {
      const first = forwardedValue.split(',')[0]?.trim()
      if (first !== undefined && first !== '') return first
    }
  }
  return remoteAddress === undefined || remoteAddress === '' ? 'unknown' : remoteAddress
}

/**
 * 同源校验（状态改变请求）。
 *
 * 判据是**请求自己的 Host**：浏览器发来的 `Origin` 必须与 `Host` 同主机，
 * 或者等于配置里的 `baseUrl`。只看 `baseUrl` 会把"用 127.0.0.1 打开本机中转"
 * 判成跨站（本地调试直接登录不了），而 `baseUrl` 在反代后面本来就可能与
 * 浏览器看到的 Host 不同。
 *
 * 反代必须保留 Host（Caddy 默认保留）—— 这是这条判据的前提。
 */
export function originAllowed(
  headers: Record<string, string | string[] | undefined>,
  baseUrl: string | undefined,
): boolean {
  const origin = headers['origin']
  const originValue = Array.isArray(origin) ? origin[0] : origin
  if (typeof originValue === 'string' && originValue !== '') {
    let parsed: URL
    try {
      parsed = new URL(originValue)
    } catch {
      return false
    }
    const host = headers['host']
    const hostValue = Array.isArray(host) ? host[0] : host
    if (typeof hostValue === 'string' && hostValue !== '' && parsed.host === hostValue) return true
    if (baseUrl !== undefined && baseUrl !== '') {
      try {
        return parsed.origin === new URL(baseUrl).origin
      } catch {
        return false
      }
    }
    return false
  }
  // 没有 Origin 时看 Fetch Metadata：跨站表单/脚本会被标成 cross-site。
  const site = headers['sec-fetch-site']
  const siteValue = Array.isArray(site) ? site[0] : site
  if (typeof siteValue === 'string' && siteValue !== 'same-origin' && siteValue !== 'none') return false
  return true
}
