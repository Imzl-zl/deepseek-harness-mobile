/**
 * `auth` 配置段的解析与校验。
 *
 * 一条纪律与 `main.ts` 现有的其它段一致：**配错就启动失败**，而且说出是哪一格。
 * 一个"起来了但验证码永远发不出去"的中转，比一开始就说"`auth.smtp.from` 没填"
 * 难查得多。
 */
import { join } from 'node:path'

import type { SmtpConfig } from './smtp.ts'
import { normalizeEmail } from './email.ts'

export type RegistrationMode = 'open' | 'closed'

export interface AuthConfig {
  readonly mode: 'accounts'
  /** 外部可访问的根地址（cookie 的 Secure、同源校验、邮件里的链接都用它）。 */
  readonly baseUrl?: string
  readonly dbPath: string
  readonly serverName: string
  readonly registration: {
    readonly mode: RegistrationMode
    readonly requireEmailVerification: boolean
    /** 空数组 = 不限制。 */
    readonly emailDomains: readonly string[]
  }
  readonly limits: {
    readonly defaultMaxConnectors: number
    readonly defaultQuotaBytes: number | null
  }
  readonly adminEmails: readonly string[]
  readonly smtp?: SmtpConfig
  readonly trustProxy: boolean
  readonly sessionDays: number
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value)

const stringOf = (value: unknown): string | undefined => (typeof value === 'string' ? value : undefined)
const boolOf = (value: unknown, fallback: boolean): boolean => (typeof value === 'boolean' ? value : fallback)
const intOf = (value: unknown): number | undefined =>
  typeof value === 'number' && Number.isInteger(value) ? value : undefined

function fail(message: string): never {
  throw new Error(`配置里的 auth 段不合法：${message}`)
}

function resolveSecret(value: string | undefined): string | undefined {
  if (value === undefined) return undefined
  if (!value.startsWith('env:')) return value
  const name = value.slice('env:'.length)
  if (name === '') fail('smtp.pass 写了 env: 但没给变量名')
  const resolved = process.env[name]
  if (resolved === undefined || resolved === '') fail(`smtp.pass 指向的环境变量 ${name} 不存在或为空`)
  return resolved
}

function domainsOf(value: unknown): string[] {
  if (value === undefined) return []
  const raw = typeof value === 'string' ? value.split(',') : Array.isArray(value) ? value : fail('registration.emailDomains 必须是数组或逗号分隔的字符串')
  const out: string[] = []
  for (const item of raw) {
    if (typeof item !== 'string') fail('registration.emailDomains 里每一项都必须是字符串')
    const domain = item.trim().toLowerCase().replace(/^@/, '')
    if (domain === '') continue
    if (!/^[a-z0-9.-]+\.[a-z]{2,}$/.test(domain)) fail(`registration.emailDomains 里的域名不认识：${item}`)
    out.push(domain)
  }
  return out
}

function smtpOf(value: unknown, requireFrom: boolean): SmtpConfig | undefined {
  if (value === undefined) {
    if (requireFrom) fail('开了邮箱验证就必须配 auth.smtp（host / from / 账号）')
    return undefined
  }
  if (!isRecord(value)) fail('auth.smtp 必须是对象')
  const host = stringOf(value['host'])?.trim()
  if (host === undefined || host === '') fail('auth.smtp.host 必须是非空字符串')
  const port = intOf(value['port']) ?? 587
  if (port < 1 || port > 65_535) fail('auth.smtp.port 必须在 1–65535 之间')
  const secure = boolOf(value['secure'], port === 465)
  const starttls = boolOf(value['starttls'], !secure)
  if (!secure && !starttls) fail('auth.smtp 的 secure 与 starttls 不能同时为 false（明文发信没有意义）')
  const user = stringOf(value['user'])?.trim()
  const pass = resolveSecret(stringOf(value['pass']))
  const fromRaw = stringOf(value['from'])?.trim()
  const from = fromRaw === undefined ? undefined : normalizeEmail(fromRaw)
  if (requireFrom && (from === undefined || from === '')) {
    fail('auth.smtp.from 必须是合法邮箱（AhaSend 要求发件域名已校验）')
  }
  const fromName = stringOf(value['fromName'])?.trim()
  const timeoutMs = intOf(value['timeoutMs'])
  if (timeoutMs !== undefined && (timeoutMs < 1_000 || timeoutMs > 60_000)) {
    fail('auth.smtp.timeoutMs 必须在 1000–60000 之间')
  }
  return {
    host,
    port,
    secure,
    starttls,
    ...(user === undefined || user === '' ? {} : { user }),
    ...(pass === undefined || pass === '' ? {} : { pass }),
    ...(from === undefined ? { from: '' } : { from }),
    ...(fromName === undefined || fromName === '' ? {} : { fromName }),
    ...(timeoutMs === undefined ? {} : { timeoutMs }),
  }
}

export interface ParseAuthOptions {
  /** 配置文件所在目录；`dbPath` 的默认值按它算。 */
  configDir: string
}

export function parseAuthConfig(raw: unknown, options: ParseAuthOptions): AuthConfig {
  if (!isRecord(raw)) fail('必须是一个对象')
  const mode = stringOf(raw['mode'])
  if (mode !== undefined && mode !== 'accounts') fail('mode 只能是 "accounts"')
  const baseUrlRaw = stringOf(raw['baseUrl'])?.trim()
  let baseUrl: string | undefined
  if (baseUrlRaw !== undefined && baseUrlRaw !== '') {
    let url: URL
    try {
      url = new URL(baseUrlRaw)
    } catch {
      fail(`baseUrl 不是合法 URL：${baseUrlRaw}`)
    }
    if (url.protocol !== 'https:' && url.protocol !== 'http:') fail('baseUrl 只能是 http:// 或 https://')
    baseUrl = url.origin
  }
  const dbPathRaw = stringOf(raw['dbPath'])?.trim()
  const dbPath = dbPathRaw === undefined || dbPathRaw === ''
    ? join(options.configDir, 'data', 'relay.db')
    : dbPathRaw
  const serverName = (stringOf(raw['serverName'])?.trim() || 'DSH 中转').slice(0, 60)

  const registrationRaw = raw['registration']
  if (registrationRaw !== undefined && !isRecord(registrationRaw)) fail('registration 必须是对象')
  const registration = isRecord(registrationRaw) ? registrationRaw : {}
  const registrationMode = stringOf(registration['mode']) ?? 'open'
  if (registrationMode !== 'open' && registrationMode !== 'closed') {
    fail('registration.mode 只能是 "open" 或 "closed"')
  }
  const requireEmailVerification = boolOf(registration['requireEmailVerification'], true)
  const emailDomains = domainsOf(registration['emailDomains'])

  const limitsRaw = raw['limits']
  if (limitsRaw !== undefined && !isRecord(limitsRaw)) fail('limits 必须是对象')
  const limits = isRecord(limitsRaw) ? limitsRaw : {}
  const defaultMaxConnectors = intOf(limits['defaultMaxConnectors']) ?? 2
  if (defaultMaxConnectors < 1 || defaultMaxConnectors > 100) {
    fail('limits.defaultMaxConnectors 必须在 1–100 之间')
  }
  const defaultQuotaRaw = limits['defaultQuotaBytes']
  let defaultQuotaBytes: number | null = 5 * 1024 ** 3
  if (defaultQuotaRaw === null) defaultQuotaBytes = null
  else if (defaultQuotaRaw !== undefined) {
    const value = intOf(defaultQuotaRaw)
    if (value === undefined || value < 1) fail('limits.defaultQuotaBytes 必须是正整数，或 null（不限制）')
    defaultQuotaBytes = value
  }

  const adminEmailsRaw = raw['adminEmails']
  const adminEmails: string[] = []
  if (adminEmailsRaw !== undefined) {
    if (!Array.isArray(adminEmailsRaw)) fail('adminEmails 必须是数组')
    for (const item of adminEmailsRaw) {
      if (typeof item !== 'string') fail('adminEmails 里每一项都必须是邮箱字符串')
      const email = normalizeEmail(item)
      if (email === undefined) fail(`adminEmails 里的邮箱不合法：${item}`)
      if (!adminEmails.includes(email)) adminEmails.push(email)
    }
  }

  const smtp = smtpOf(raw['smtp'], requireEmailVerification)
  const sessionDays = intOf(raw['sessionDays']) ?? 30
  if (sessionDays < 1 || sessionDays > 365) fail('sessionDays 必须在 1–365 之间')

  return {
    mode: 'accounts',
    ...(baseUrl === undefined ? {} : { baseUrl }),
    dbPath,
    serverName,
    registration: {
      mode: registrationMode,
      requireEmailVerification,
      emailDomains,
    },
    limits: { defaultMaxConnectors, defaultQuotaBytes },
    adminEmails,
    ...(smtp === undefined ? {} : { smtp }),
    trustProxy: boolOf(raw['trustProxy'], false),
    sessionDays,
  }
}

/** 前端只需要的部分（不含任何密钥）。 */
export function publicAuthConfig(config: AuthConfig): {
  serverName: string
  registration: { mode: RegistrationMode; requireEmailVerification: boolean; emailDomains: readonly string[] }
} {
  return {
    serverName: config.serverName,
    registration: {
      mode: config.registration.mode,
      requireEmailVerification: config.registration.requireEmailVerification,
      emailDomains: config.registration.emailDomains,
    },
  }
}
