/**
 * 账号 HTTP 面：注册、登录、会话、用户控制台。
 *
 * ## 边界
 *
 * 这一层只认识 `AccountsRequest`/`AccountsReply`，不认识 socket、不写 socket。
 * 路由与判定能脱离网络测；装配在 `server.ts`。
 *
 * ## 认证与 CSRF
 *
 * - 浏览器会话：`dsh_relay_session`（HttpOnly）+ `dsh_relay_csrf`（可读）。
 * - 所有带会话的写请求都要 **Origin 同源 + 双提交 CSRF**。
 * - 登录/注册/发码没有会话，只做 Origin 与限流；它们不是"借已有凭据"的操作。
 *
 * ## 为什么登录失败不区分"邮箱不存在"与"密码错"
 *
 * 两种都回 `bad-credentials`，并且邮箱不存在时也算一次 dummy scrypt ——
 * 否则响应时间与文案都会把"这个邮箱注册过"漏出去。
 *
 * Note: 为什么账号只做"电脑与额度"、为什么令牌首连才绑定 —— 见
 * `.agents/notes/implemented/2026-11-02-relay-accounts-and-connector-binding.md`
 */
import { randomBytes } from 'node:crypto'

import { createRateLimiter, type RateLimiter } from '../rate-limit.ts'
import type { FailureLockout } from '../lockout.ts'
import type { ChannelLogger } from '../logger.ts'
import {
  createCodeStore,
  domainOf,
  emailProblem,
  normalizeEmail,
  verificationMail,
  type CodePurpose,
  type CodeStore,
  type Mailer,
} from './email.ts'
import { hashPassword, dummyHash, passwordProblem, verifyPassword } from './password.ts'
import {
  CSRF_COOKIE,
  SESSION_COOKIE,
  clientIpOf,
  clearCookie,
  csrfOf,
  hashToken,
  newSessionToken,
  originAllowed,
  parseCookies,
  safeEqual,
  serializeCookie,
  type CookieOptions,
} from './session.ts'
import { publicAuthConfig, type AuthConfig } from './config.ts'
import { publicUserOf, type AccountsDb, type PublicUser, type SessionRecord, type UserRecord } from './db.ts'
import { AUTH_PAGE } from '../ui/auth-page.ts'
import { CONSOLE_PAGE } from '../ui/console-page.ts'

export const CODE_TTL_MS = 10 * 60_000

export interface AccountsRequest {
  method: string
  path: string
  search: URLSearchParams
  headers: Record<string, string | string[] | undefined>
  body?: unknown
  remoteAddress?: string
}

export interface AccountsReply {
  status: number
  body?: unknown
  html?: string
  headers?: Record<string, string | string[]>
}

export interface SessionContext {
  user: UserRecord
  session: SessionRecord
  csrf: string
}

export interface ConsoleConnector {
  id: string
  connectorId?: string
  name: string
  online: boolean
  since?: number
  lastPongAt?: number
  devices: number
  revokedAt?: number
  createdAt?: number
}

export interface ConsoleDevice {
  id: string
  name: string
  connectorId?: string
  revokedAt?: number
}

export interface ConsoleState {
  v: 1
  now: number
  user: PublicUser
  limits: { maxConnectors: number; usedConnectors: number }
  quota: { period: string; used: number; limit: number | null; enforce: string }
  connectors: readonly ConsoleConnector[]
  devices: readonly ConsoleDevice[]
}

export interface ConsoleBridge {
  state(user: UserRecord): ConsoleState
  createConnector(user: UserRecord, name: string): Promise<{ token: string; id: string }>
  renameConnector(user: UserRecord, id: string, name: string): Promise<'ok' | 'not-found'>
  setConnectorEnabled(user: UserRecord, id: string, enabled: boolean): Promise<'ok' | 'not-found'>
  removeConnector(user: UserRecord, id: string): Promise<'ok' | 'not-found' | 'revoke-first'>
  resetBinding(user: UserRecord, id: string): Promise<'ok' | 'not-found' | 'online'>
}

export interface AccountsLimiters {
  /** 发码：按 IP 与邮箱。 */
  codeIp: RateLimiter
  codeEmail: RateLimiter
  /** 登录：按 IP 与邮箱。 */
  loginIp: RateLimiter
  loginEmail: RateLimiter
  /** 注册：按 IP。 */
  registerIp: RateLimiter
}

export interface AccountsFaceOptions {
  db: AccountsDb
  config: AuthConfig
  mailer?: Mailer
  log?: ChannelLogger
  console: ConsoleBridge
  limiters: AccountsLimiters
  /**
   * 按来源地址的**连续失败锁定**（与 `/admin` 共用同一份计数）。
   * 不传 = 只限流、不锁（测试里的老用例不受影响）。
   */
  lockout?: FailureLockout
  /** cookie 是否带 Secure（由 `auth.baseUrl` 是 https 决定）。 */
  secureCookies: boolean
  now?: () => number
  codes?: CodeStore
}

export interface AccountsFace {
  handle(request: AccountsRequest): Promise<AccountsReply | undefined>
  /** `/admin` 用：从 cookie 取管理员会话（没有就 `undefined`）。 */
  sessionOf(request: AccountsRequest): SessionContext | undefined
}

/**
 * 认证端点的限流桶。
 *
 * 每个桶都按**键**分桶（IP / 邮箱），不是全局桶 —— 一个人刷坏注册不该把所有人限成 429。
 * 参数是"突发 + 长期平均"：发码 5 封/小时、登录 10 次/15 分钟、注册 5 个/小时。
 */
export function createAccountsLimiters(log?: ChannelLogger): AccountsLimiters {
  const make = (capacity: number, refillPerSecond: number): RateLimiter =>
    createRateLimiter({ capacity, refillPerSecond, ...(log === undefined ? {} : { log }) })
  return {
    codeIp: make(10, 10 / 3600),
    codeEmail: make(5, 5 / 3600),
    loginIp: make(10, 10 / 900),
    loginEmail: make(10, 10 / 900),
    registerIp: make(5, 5 / 3600),
  }
}

const headerValue = (value: string | string[] | undefined): string | undefined =>
  Array.isArray(value) ? value[0] : value

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value)

const json = (status: number, body: unknown, headers?: Record<string, string | string[]>): AccountsReply => ({
  status,
  body,
  headers: { 'cache-control': 'no-store', ...(headers ?? {}) },
})

const failure = (
  status: number,
  code: string,
  message: string,
  extra?: Record<string, unknown>,
): AccountsReply => json(status, { error: code, message, ...(extra ?? {}) })

const html = (status: number, body: string, headers?: Record<string, string | string[]>): AccountsReply => ({
  status,
  html: body,
  headers: {
    'cache-control': 'no-store',
    'content-security-policy': [
      "default-src 'none'",
      "style-src 'unsafe-inline'",
      "script-src 'unsafe-inline'",
      "img-src 'self' data:",
      "connect-src 'self'",
      "form-action 'self'",
      "base-uri 'none'",
      "frame-ancestors 'none'",
    ].join('; '),
    ...(headers ?? {}),
  },
})

const redirect = (location: string): AccountsReply => ({
  status: 302,
  headers: { location, 'cache-control': 'no-store' },
})

export function createAccountsFace(options: AccountsFaceOptions): AccountsFace {
  const { db, config, console: bridge } = options
  const now = options.now ?? (() => Date.now())
  const codes = options.codes ?? createCodeStore({ ttlMs: CODE_TTL_MS })
  const secure = options.secureCookies
  /**
   * cookie 的 `Secure` 跟随**实际 Host**：公网域名（baseUrl 的 host）才带 Secure，
   * 用 127.0.0.1 打开本机中转时不带 —— 否则浏览器会直接拒收，本地登录永远失败。
   * 反代必须保留 Host（Caddy 默认如此）。
   */
  const publicHost = config.baseUrl === undefined ? undefined : new URL(config.baseUrl).host
  const secureFor = (request: AccountsRequest): boolean => {
    if (!secure) return false
    if (publicHost === undefined) return true
    return headerValue(request.headers['host']) === publicHost
  }

  const cookieHeader = (request: AccountsRequest): string | undefined => headerValue(request.headers['cookie'])

  const sessionOf = (request: AccountsRequest): SessionContext | undefined => {
    const raw = parseCookies(cookieHeader(request))[SESSION_COOKIE]
    if (raw === undefined || raw === '') return undefined
    const session = db.sessionByTokenHash(hashToken(raw), now())
    if (session === undefined) return undefined
    const user = db.findById(session.userId)
    if (user === undefined || user.status !== 'active') return undefined
    // 每 5 分钟落一次 last_seen：每个请求都写会把会话表变成写热点。
    if (now() - session.lastSeenAt > 5 * 60_000) db.touchSession(session.id, now())
    return { user, session, csrf: csrfOf(db.secret, session.id) }
  }

  const sessionHeaders = (
    token: string,
    csrf: string,
    secureCookie: boolean,
  ): Record<string, string | string[]> => {
    const cookieOptions: CookieOptions = {
      secure: secureCookie,
      maxAgeSeconds: config.sessionDays * 86_400,
      httpOnly: true,
    }
    return {
      'set-cookie': [
        serializeCookie(SESSION_COOKIE, token, cookieOptions),
        serializeCookie(CSRF_COOKIE, csrf, { ...cookieOptions, httpOnly: false }),
      ],
    }
  }

  const clearSessionHeaders = (secureCookie: boolean): Record<string, string | string[]> => ({
    'set-cookie': [
      clearCookie(SESSION_COOKIE, secureCookie, true),
      clearCookie(CSRF_COOKIE, secureCookie, false),
    ],
  })

  const issueSession = (user: UserRecord, request: AccountsRequest): { token: string; csrf: string; headers: Record<string, string | string[]> } => {
    const sessionId = `s_${randomBytes(9).toString('base64url')}`
    const token = newSessionToken()
    const at = now()
    db.createSession({
      id: sessionId,
      userId: user.id,
      tokenHash: hashToken(token),
      createdAt: at,
      expiresAt: at + config.sessionDays * 86_400_000,
      ip: clientIpOf(request.headers, request.remoteAddress, config.trustProxy),
      userAgent: (headerValue(request.headers['user-agent']) ?? '').slice(0, 300),
    })
    const csrf = csrfOf(db.secret, sessionId)
    return { token, csrf, headers: sessionHeaders(token, csrf, secureFor(request)) }
  }

  const normalizeName = (value: unknown, fallback: string): string | undefined => {
    const raw = typeof value === 'string' ? value.trim() : fallback
    if (raw.length < 1 || raw.length > 40) return undefined
    if (/[\u0000-\u001f\u007f]/.test(raw)) return undefined
    return raw
  }

  const csrfGuard = (request: AccountsRequest, session: SessionContext): AccountsReply | undefined => {
    if (!originAllowed(request.headers, config.baseUrl)) return failure(403, 'origin', '来源不对')
    const header = headerValue(request.headers['x-csrf-token'])
    const cookie = parseCookies(cookieHeader(request))[CSRF_COOKIE]
    if (header === undefined || cookie === undefined) return failure(403, 'csrf', '页面已失效，请刷新后重试')
    if (!safeEqual(header, cookie) || !safeEqual(header, session.csrf)) {
      return failure(403, 'csrf', '页面已失效，请刷新后重试')
    }
    return undefined
  }

  /**
 * 记一次失败；这一下把地址锁上了就直接回 429（带还要等多久）。
 *
 * **不告诉对方"你还剩几次"**：那是给爆破方的进度条。锁上之前一律照旧回 401。
 */
const lockedOutOr = (
  options: AccountsFaceOptions,
  key: string,
  status: number,
  code: string,
  message: string,
): AccountsReply => {
  const after = options.lockout?.fail(key)
  if (after?.blocked === true) {
    options.log?.info('auth.locked-out', { key, failures: after.failures })
    return failure(429, 'locked-out', '连续失败次数过多，稍后再试', { retryAfterMs: after.retryAfterMs })
  }
  return failure(status, code, message)
}

const limited = (limiter: RateLimiter, key: string): AccountsReply | undefined => {
    const decision = limiter.take(key)
    if (decision.allowed) return undefined
    return failure(429, 'rate-limited', '请求太频繁，稍后再试', { retryAfterMs: decision.retryAfterMs })
  }

  const bodyOf = (request: AccountsRequest): Record<string, unknown> =>
    isRecord(request.body) ? request.body : {}

  const emailOf = (body: Record<string, unknown>, policy = { domains: config.registration.emailDomains }): { email: string } | AccountsReply => {
    const raw = typeof body['email'] === 'string' ? body['email'] : ''
    const problem = emailProblem(raw, policy)
    if (problem !== undefined) return failure(400, problem.code, problem.message)
    const email = normalizeEmail(raw)
    if (email === undefined) return failure(400, 'email-invalid', '邮箱格式不对')
    return { email }
  }

  return {
    sessionOf,

    async handle(request) {
      const path = request.path.length > 1 && request.path.endsWith('/')
        ? request.path.slice(0, -1)
        : request.path
      const method = request.method.toUpperCase()
      const ip = clientIpOf(request.headers, request.remoteAddress, config.trustProxy)
      const body = bodyOf(request)

      // ---- 页面 ----
      if (path === '/') {
        if (method !== 'GET') return undefined
        return sessionOf(request) === undefined ? redirect('/login') : redirect('/console')
      }
      if (path === '/login' || path === '/register' || path === '/reset') {
        if (method !== 'GET') return failure(405, 'method-not-allowed', '方法不对')
        if (path !== '/reset' && sessionOf(request) !== undefined) return redirect('/console')
        return html(200, AUTH_PAGE)
      }
      if (path === '/console') {
        if (method !== 'GET') return failure(405, 'method-not-allowed', '方法不对')
        return sessionOf(request) === undefined ? redirect('/login') : html(200, CONSOLE_PAGE)
      }

      // ---- 公共配置 ----
      if (path === '/api/auth/config') {
        if (method !== 'GET') return failure(405, 'method-not-allowed', '方法不对')
        return json(200, { ...publicAuthConfig(config), accounts: true })
      }

      // ---- 发验证码 ----
      if (path === '/api/auth/email-code') {
        if (method !== 'POST') return failure(405, 'method-not-allowed', '方法不对')
        if (!originAllowed(request.headers, config.baseUrl)) return failure(403, 'origin', '来源不对')
        const parsed = emailOf(body)
        if ('status' in parsed) return parsed
        const purpose = body['purpose'] === 'reset' ? 'reset' : 'register'
        // 注册关闭只挡注册；密码重置仍然可用（老用户要能找回密码）。
        if (purpose === 'register' && config.registration.mode === 'closed') {
          return failure(403, 'registration-closed', '注册已关闭')
        }
        const denied = limited(options.limiters.codeIp, `code-ip:${ip}`)
        if (denied !== undefined) return denied
        if (purpose === 'register' && db.findByEmail(parsed.email) !== undefined) {
          return failure(409, 'email-taken', '这个邮箱已经注册过，直接登录即可')
        }
        const byEmail = limited(options.limiters.codeEmail, `code-email:${parsed.email}`)
        if (byEmail !== undefined) return byEmail

        const issued = codes.issue(parsed.email, purpose)
        if (!issued.ok) {
          return failure(429, 'rate-limited', '验证码刚发过，稍等再点', { retryAfterMs: issued.retryAfterMs })
        }
        // 重置密码对"邮箱不存在"保持沉默：仍然 202，但不发信（防枚举）。
        if (purpose === 'reset' && db.findByEmail(parsed.email) === undefined) {
          return json(202, { ok: true, retryAfterMs: issued.issue.cooldownMs })
        }
        if (options.mailer === undefined) {
          codes.clear(parsed.email, purpose)
          return failure(503, 'mail-unavailable', '这台中转没有配置发信')
        }
        try {
          await options.mailer.send(verificationMail({
            email: parsed.email,
            code: issued.issue.code,
            purpose,
            serverName: config.serverName,
            validMinutes: Math.round(CODE_TTL_MS / 60_000),
          }))
        } catch (error) {
          codes.clear(parsed.email, purpose)
          options.log?.warn('auth.mail-failed', { purpose, error })
          return failure(502, 'mail-failed', '验证码邮件没发出去，稍后再试或联系管理员')
        }
        options.log?.info('auth.email-code', { purpose, domain: domainOf(parsed.email), ip })
        return json(202, { ok: true, retryAfterMs: issued.issue.cooldownMs })
      }

      // ---- 注册 ----
      if (path === '/api/auth/register') {
        if (method !== 'POST') return failure(405, 'method-not-allowed', '方法不对')
        if (!originAllowed(request.headers, config.baseUrl)) return failure(403, 'origin', '来源不对')
        if (config.registration.mode === 'closed') {
          return failure(403, 'registration-closed', '注册已关闭')
        }
        const denied = limited(options.limiters.registerIp, `register-ip:${ip}`)
        if (denied !== undefined) return denied
        const parsed = emailOf(body)
        if ('status' in parsed) return parsed
        if (db.findByEmail(parsed.email) !== undefined) {
          return failure(409, 'email-taken', '这个邮箱已经注册过，直接登录即可')
        }
        const password = typeof body['password'] === 'string' ? body['password'] : ''
        const problem = passwordProblem(password)
        if (problem !== undefined) return failure(400, 'password-weak', problem)
        if (config.registration.requireEmailVerification) {
          const code = typeof body['code'] === 'string' ? body['code'] : ''
          const verdict = codes.verify(parsed.email, 'register', code)
          if (verdict === 'too-many') return failure(400, 'code-too-many', '尝试次数太多，重新发一封')
          if (verdict !== 'ok') return failure(400, 'code-invalid', '验证码不对或已过期')
        }
        const local = parsed.email.slice(0, parsed.email.lastIndexOf('@'))
        const displayName = normalizeName(body['displayName'], local)
        if (displayName === undefined) return failure(400, 'name-invalid', '昵称 1–40 个字符')
        const at = now()
        const passwordHash = await hashPassword(password)
        const role = config.adminEmails.includes(parsed.email) ? 'admin' : 'user'
        let user: PublicUser
        try {
          user = db.createUser({
            email: parsed.email,
            passwordHash,
            displayName,
            role,
            emailVerifiedAt: config.registration.requireEmailVerification ? at : null,
            maxConnectors: null,
            // 默认额度在注册时就落成具体值：之后管理员改默认值只影响新账号，
            // 不会把老用户的用量突然按新上限截断。`null` = 不限。
            quotaBytes: config.limits.defaultQuotaBytes,
          })
        } catch (error) {
          options.log?.warn('auth.register-failed', error)
          return failure(409, 'email-taken', '这个邮箱已经注册过，直接登录即可')
        }
        const record = db.findById(user.id)
        if (record === undefined) return failure(500, 'internal', '账号写入后读不回来')
        const session = issueSession(record, request)
        options.log?.info('auth.register', { userId: record.id, role, ip })
        return json(201, { user: publicUserOf(record) }, session.headers)
      }

      // ---- 登录 ----
      if (path === '/api/auth/login') {
        if (method !== 'POST') return failure(405, 'method-not-allowed', '方法不对')
        if (!originAllowed(request.headers, config.baseUrl)) return failure(403, 'origin', '来源不对')
        // **连续失败锁定**先于限流：锁定是"猜错就停"，限流只是变慢（见 `lockout.ts`）。
        // 锁定期内连正确密码也不放行 —— 否则爆破方每 N 次就能试一次。
        const locked = options.lockout?.stateOf(`login:${ip}`)
        if (locked?.blocked === true) {
          return failure(429, 'locked-out', '连续失败次数过多，稍后再试', {
            retryAfterMs: locked.retryAfterMs,
          })
        }
        const denied = limited(options.limiters.loginIp, `login-ip:${ip}`)
        if (denied !== undefined) return denied
        const parsed = emailOf(body, { domains: [] })
        if ('status' in parsed) return parsed
        const byEmail = limited(options.limiters.loginEmail, `login-email:${parsed.email}`)
        if (byEmail !== undefined) return byEmail
        const password = typeof body['password'] === 'string' ? body['password'] : ''
        const user = db.findByEmail(parsed.email)
        // 邮箱不存在也算一次：响应时间不泄露"有没有这个账号"。
        if (user === undefined) {
          await verifyPassword(password, await dummyHash())
          options.log?.info('auth.login-failed', { reason: 'unknown', ip })
          return lockedOutOr(options, `login:${ip}`, 401, 'bad-credentials', '邮箱或密码不对')
        }
        const matched = await verifyPassword(password, user.passwordHash)
        if (!matched) {
          options.log?.info('auth.login-failed', { userId: user.id, ip })
          return lockedOutOr(options, `login:${ip}`, 401, 'bad-credentials', '邮箱或密码不对')
        }
        if (user.status !== 'active') {
          options.log?.info('auth.login-failed', { userId: user.id, reason: 'suspended', ip })
          return failure(403, 'account-suspended', '这个账号已被停用，请联系管理员')
        }
        // 成功一次清零：能成功就说明不是爆破方。
        options.lockout?.clear(`login:${ip}`)
        db.updateLastLogin(user.id, now())
        const fresh = db.findById(user.id) ?? user
        const session = issueSession(fresh, request)
        options.log?.info('auth.login', { userId: user.id, ip })
        return json(200, { user: publicUserOf(fresh) }, session.headers)
      }

      // ---- 当前用户 / 退出 ----
      if (path === '/api/auth/me') {
        if (method !== 'GET') return failure(405, 'method-not-allowed', '方法不对')
        const session = sessionOf(request)
        if (session === undefined) return failure(401, 'unauthorized', '没有登录')
        return json(200, { user: publicUserOf(session.user), csrf: session.csrf })
      }

      if (path === '/api/auth/logout') {
        if (method !== 'POST') return failure(405, 'method-not-allowed', '方法不对')
        const session = sessionOf(request)
        if (session === undefined) return json(200, { ok: true }, clearSessionHeaders(secureFor(request)))
        const denied = csrfGuard(request, session)
        if (denied !== undefined) return denied
        db.revokeSession(session.session.id, now())
        options.log?.info('auth.logout', { userId: session.user.id, ip })
        return json(200, { ok: true }, clearSessionHeaders(secureFor(request)))
      }

      // ---- 改密码 / 重置 ----
      if (path === '/api/auth/password') {
        if (method !== 'POST') return failure(405, 'method-not-allowed', '方法不对')
        const session = sessionOf(request)
        if (session === undefined) return failure(401, 'unauthorized', '没有登录')
        const denied = csrfGuard(request, session)
        if (denied !== undefined) return denied
        const current = typeof body['current'] === 'string' ? body['current'] : ''
        const next = typeof body['next'] === 'string' ? body['next'] : ''
        const problem = passwordProblem(next)
        if (problem !== undefined) return failure(400, 'password-weak', problem)
        const matched = await verifyPassword(current, session.user.passwordHash)
        if (!matched) return failure(400, 'bad-credentials', '当前密码不对')
        db.updatePassword(session.user.id, await hashPassword(next))
        // 其它设备上的会话作废；当前这条留着。
        db.revokeUserSessions(session.user.id, now(), session.session.id)
        options.log?.info('auth.password-changed', { userId: session.user.id, ip })
        return json(200, { ok: true })
      }

      if (path === '/api/auth/password/reset') {
        if (method !== 'POST') return failure(405, 'method-not-allowed', '方法不对')
        if (!originAllowed(request.headers, config.baseUrl)) return failure(403, 'origin', '来源不对')
        const denied = limited(options.limiters.codeIp, `reset-ip:${ip}`)
        if (denied !== undefined) return denied
        const parsed = emailOf(body, { domains: [] })
        if ('status' in parsed) return parsed
        const password = typeof body['password'] === 'string' ? body['password'] : ''
        const problem = passwordProblem(password)
        if (problem !== undefined) return failure(400, 'password-weak', problem)
        const code = typeof body['code'] === 'string' ? body['code'] : ''
        const verdict = codes.verify(parsed.email, 'reset', code)
        if (verdict === 'too-many') return failure(400, 'code-too-many', '尝试次数太多，重新发一封')
        const user = db.findByEmail(parsed.email)
        if (verdict !== 'ok' || user === undefined) {
          return failure(400, 'code-invalid', '验证码不对或已过期')
        }
        db.updatePassword(user.id, await hashPassword(password))
        db.revokeUserSessions(user.id, now())
        options.log?.info('auth.password-reset', { userId: user.id, ip })
        return json(200, { ok: true })
      }

      // ---- 会话管理 ----
      if (path === '/api/auth/sessions') {
        if (method !== 'GET') return failure(405, 'method-not-allowed', '方法不对')
        const session = sessionOf(request)
        if (session === undefined) return failure(401, 'unauthorized', '没有登录')
        const rows = db.listSessions(session.user.id, now()).map((row) => ({
          id: row.id,
          createdAt: row.createdAt,
          lastSeenAt: row.lastSeenAt,
          expiresAt: row.expiresAt,
          ip: row.ip,
          userAgent: row.userAgent,
          current: row.id === session.session.id,
        }))
        return json(200, { sessions: rows })
      }

      if (path === '/api/auth/sessions/revoke') {
        if (method !== 'POST') return failure(405, 'method-not-allowed', '方法不对')
        const session = sessionOf(request)
        if (session === undefined) return failure(401, 'unauthorized', '没有登录')
        const denied = csrfGuard(request, session)
        if (denied !== undefined) return denied
        const id = typeof body['id'] === 'string' ? body['id'] : ''
        const target = db.listSessions(session.user.id, now()).find((row) => row.id === id)
        if (target === undefined) return failure(404, 'not-found', '没这条会话')
        db.revokeSession(target.id, now())
        const headers = target.id === session.session.id ? clearSessionHeaders(secureFor(request)) : undefined
        return json(200, { ok: true, loggedOut: target.id === session.session.id }, headers)
      }

      // ---- 控制台 ----
      if (path === '/api/console/state') {
        if (method !== 'GET') return failure(405, 'method-not-allowed', '方法不对')
        const session = sessionOf(request)
        if (session === undefined) return failure(401, 'unauthorized', '没有登录')
        return json(200, bridge.state(session.user))
      }

      if (path === '/api/console/connectors' || path === '/api/console/connectors/action') {
        if (method !== 'POST') return failure(405, 'method-not-allowed', '方法不对')
        const session = sessionOf(request)
        if (session === undefined) return failure(401, 'unauthorized', '没有登录')
        const denied = csrfGuard(request, session)
        if (denied !== undefined) return denied

        if (path === '/api/console/connectors') {
          const name = normalizeName(body['name'], '')
          if (name === undefined || name === '') return failure(400, 'name-invalid', '电脑名 1–40 个字符')
          try {
            const created = await bridge.createConnector(session.user, name)
            options.log?.info('console.connector-created', { userId: session.user.id, tokenId: created.id, ip })
            return json(201, { id: created.id, token: created.token })
          } catch (error) {
            const code = error instanceof Error ? error.message : 'internal'
            if (code === 'connector-limit') {
              return failure(409, 'connector-limit', `最多 ${session.user.maxConnectors ?? config.limits.defaultMaxConnectors} 台电脑，先删掉一台再添加`)
            }
            options.log?.warn('console.connector-create-failed', error)
            return failure(500, 'internal', '创建失败，稍后再试')
          }
        }

        const action = typeof body['action'] === 'string' ? body['action'] : ''
        const id = typeof body['id'] === 'string' ? body['id'] : ''
        if (id === '') return failure(400, 'id-invalid', '缺少电脑 id')
        if (action === 'rename') {
          const name = normalizeName(body['name'], '')
          if (name === undefined || name === '') return failure(400, 'name-invalid', '电脑名 1–40 个字符')
          const result = await bridge.renameConnector(session.user, id, name)
          return result === 'ok' ? json(200, { ok: true }) : failure(404, 'not-found', '没这台电脑')
        }
        if (action === 'revoke' || action === 'restore') {
          const result = await bridge.setConnectorEnabled(session.user, id, action === 'restore')
          if (result !== 'ok') return failure(404, 'not-found', '没这台电脑')
          options.log?.info('console.connector-enabled', { userId: session.user.id, tokenId: id, enabled: action === 'restore', ip })
          return json(200, { ok: true })
        }
        if (action === 'remove') {
          const result = await bridge.removeConnector(session.user, id)
          if (result === 'revoke-first') return failure(409, 'revoke-first', '先停用，再删除')
          if (result !== 'ok') return failure(404, 'not-found', '没这台电脑')
          options.log?.info('console.connector-removed', { userId: session.user.id, tokenId: id, ip })
          return json(200, { ok: true })
        }
        if (action === 'reset-binding') {
          const result = await bridge.resetBinding(session.user, id)
          if (result === 'online') return failure(409, 'connector-online', '这台电脑在线，先停用它再重置绑定')
          if (result !== 'ok') return failure(404, 'not-found', '没这台电脑')
          options.log?.info('console.binding-reset', { userId: session.user.id, tokenId: id, ip })
          return json(200, { ok: true })
        }
        return failure(400, 'action-invalid', '不认识的操作')
      }

      return undefined
    },
  }
}
