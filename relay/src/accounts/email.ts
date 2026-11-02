/**
 * 邮箱校验、验证码与邮件正文。
 *
 * ## 验证码为什么只放内存
 *
 * 它 10 分钟就过期，重启丢掉最多让用户再点一次"发送验证码"；放进库反而多一张
 * 要清理的表、多一条会被备份带走的短期凭据。进程内 `Map` + 惰性删除就够。
 *
 * ## 域名白名单是"注册门槛"的一部分
 *
 * 默认只允许 `qq.com`（用户定的）。它不做二次校验：`emailProblem` 是唯一判据，
 * 注册与发码都走它 —— 两处各写一遍迟早不一致。
 */
import { createHash, randomInt, timingSafeEqual } from 'node:crypto'

export type CodePurpose = 'register' | 'reset'

export interface EmailPolicy {
  /** 允许的域名（小写，不带 `@`）。**空数组 = 不限制**。 */
  domains: readonly string[]
}

export interface EmailProblem {
  code: 'email-invalid' | 'email-domain'
  message: string
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

/** 去空格、转小写。合法就返回规范形式。 */
export function normalizeEmail(raw: string): string | undefined {
  const email = raw.trim().toLowerCase()
  if (email.length === 0 || email.length > 254) return undefined
  if (!EMAIL_RE.test(email)) return undefined
  const at = email.lastIndexOf('@')
  const local = email.slice(0, at)
  const domain = email.slice(at + 1)
  if (local.length === 0 || local.length > 64 || domain.length === 0) return undefined
  if (/[\u0000-\u001f\u007f]/.test(email)) return undefined
  return email
}

export function domainOf(email: string): string {
  const at = email.lastIndexOf('@')
  return at === -1 ? '' : email.slice(at + 1).toLowerCase()
}

/** 注册/发码共用的唯一判据。 */
export function emailProblem(raw: string, policy: EmailPolicy): EmailProblem | undefined {
  const email = normalizeEmail(raw)
  if (email === undefined) {
    return { code: 'email-invalid', message: '邮箱格式不对' }
  }
  if (policy.domains.length > 0) {
    const domain = domainOf(email)
    if (!policy.domains.includes(domain)) {
      return {
        code: 'email-domain',
        message: `只接受 ${policy.domains.map((item) => `@${item}`).join('、')} 邮箱`,
      }
    }
  }
  return undefined
}

export interface CodeIssue {
  code: string
  expiresAt: number
  /** 这封邮件发出后的冷却时间（毫秒）。 */
  cooldownMs: number
}

export type CodeIssueResult =
  | { ok: true; issue: CodeIssue }
  | { ok: false; retryAfterMs: number }

export type CodeVerdict = 'ok' | 'invalid' | 'too-many'

export interface CodeStore {
  issue(email: string, purpose: CodePurpose): CodeIssueResult
  verify(email: string, purpose: CodePurpose, code: string): CodeVerdict
  clear(email: string, purpose: CodePurpose): void
  /** 观测：当前有几条（测试用）。 */
  readonly size: number
}

export interface CodeStoreOptions {
  ttlMs?: number
  maxAttempts?: number
  cooldownMs?: number
  now?: () => number
  /** 测试注入。默认 6 位十进制。 */
  generate?: () => string
}

interface CodeRow {
  codeHash: string
  expiresAt: number
  sentAt: number
  attempts: number
}

const hashOf = (email: string, purpose: CodePurpose, code: string): string =>
  createHash('sha256').update(`${purpose}:${email}:${code}`, 'utf8').digest('hex')

export function createCodeStore(options: CodeStoreOptions = {}): CodeStore {
  const ttlMs = options.ttlMs ?? 10 * 60_000
  const maxAttempts = options.maxAttempts ?? 5
  const cooldownMs = options.cooldownMs ?? 60_000
  const now = options.now ?? (() => Date.now())
  const generate = options.generate ?? (() => String(randomInt(0, 1_000_000)).padStart(6, '0'))
  const rows = new Map<string, CodeRow>()
  const keyOf = (email: string, purpose: CodePurpose): string => `${purpose}:${email}`

  const trim = (at: number): void => {
    for (const [key, row] of rows) if (row.expiresAt <= at) rows.delete(key)
  }

  return {
    get size() { return rows.size },

    issue(email, purpose) {
      const at = now()
      trim(at)
      const key = keyOf(email, purpose)
      const existing = rows.get(key)
      if (existing !== undefined && at - existing.sentAt < cooldownMs) {
        return { ok: false, retryAfterMs: cooldownMs - (at - existing.sentAt) }
      }
      const code = generate()
      rows.set(key, {
        codeHash: hashOf(email, purpose, code),
        expiresAt: at + ttlMs,
        sentAt: at,
        attempts: 0,
      })
      return { ok: true, issue: { code, expiresAt: at + ttlMs, cooldownMs } }
    },

    verify(email, purpose, code) {
      const at = now()
      const key = keyOf(email, purpose)
      const row = rows.get(key)
      if (row === undefined) return 'invalid'
      if (row.expiresAt <= at) { rows.delete(key); return 'invalid' }
      if (row.attempts >= maxAttempts) { rows.delete(key); return 'too-many' }
      const expected = Buffer.from(row.codeHash, 'hex')
      const actual = Buffer.from(hashOf(email, purpose, code.trim()), 'hex')
      const matched = expected.length === actual.length && timingSafeEqual(expected, actual)
      if (!matched) {
        row.attempts += 1
        if (row.attempts >= maxAttempts) rows.delete(key)
        return row.attempts >= maxAttempts ? 'too-many' : 'invalid'
      }
      rows.delete(key)
      return 'ok'
    },

    clear(email, purpose) { rows.delete(keyOf(email, purpose)) },
  }
}

export interface MailMessage {
  to: string
  subject: string
  text: string
  html: string
}

export interface Mailer {
  send(message: MailMessage): Promise<void>
}

const escapeHtml = (value: string): string =>
  value.replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char] ?? char))

export interface VerificationMailInput {
  email: string
  code: string
  purpose: CodePurpose
  serverName: string
  validMinutes: number
}

export function verificationMail(input: VerificationMailInput): MailMessage {
  const subject = input.purpose === 'register'
    ? `${input.serverName} · 注册验证码`
    : `${input.serverName} · 重置密码验证码`
  const action = input.purpose === 'register' ? '注册账号' : '重置密码'
  const text = [
    `你正在${action}。`,
    '',
    `验证码：${input.code}`,
    `${input.validMinutes} 分钟内有效，只能使用一次。`,
    '',
    '如果不是你本人操作，忽略这封邮件即可。',
  ].join('\n')
  const name = escapeHtml(input.serverName)
  const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"></head>
<body style="margin:0;background:#0b0f14;padding:32px 16px;font-family:-apple-system,'Segoe UI',Roboto,'Noto Sans SC',sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;margin:0 auto;background:#11161d;border:1px solid #232c38;border-radius:16px">
<tr><td style="padding:28px 28px 8px;color:#e8eef6;font-size:18px;font-weight:600">${name}</td></tr>
<tr><td style="padding:0 28px;color:#9aa7b8;font-size:14px;line-height:1.7">你正在${action}。请在页面里填入下面的验证码：</td></tr>
<tr><td style="padding:20px 28px 4px">
  <div style="font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:30px;letter-spacing:8px;color:#3dd6c0;background:#0b0f14;border:1px solid #232c38;border-radius:12px;padding:16px 20px;text-align:center">${input.code}</div>
</td></tr>
<tr><td style="padding:8px 28px 24px;color:#68758a;font-size:12.5px;line-height:1.7">${input.validMinutes} 分钟内有效，只能使用一次。<br>如果不是你本人操作，忽略这封邮件即可。</td></tr>
</table></body></html>`
  return { to: input.email, subject, text, html }
}
