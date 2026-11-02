/**
 * 密码摘要（scrypt）。
 *
 * 只做两件事：把明文变成可落库的字符串、把明文与库里的字符串比对。
 * 参数写进字符串本身（`scrypt$N$r$p$salt$key`），这样以后换参数不必迁移旧行 ——
 * 校验读的是那一行自己的参数。
 *
 * ## 为什么是 scrypt 而不是 bcrypt / argon2
 *
 * `node:crypto` 自带，零依赖；bcrypt 要原生模块（alpine 上要编译），argon2 同理。
 * 对这台中转的规模，scrypt 的 N=16384 已经足够；参数上限在 `verify` 里也做了校验，
 * 防止一行被篡改的库记录把进程拖进超大内存计算。
 */
import { randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto'
import type { ScryptOptions } from 'node:crypto'

/** 当前参数。改这里只影响新密码；旧行按自己的参数校验。 */
const N = 16_384
const R = 8
const P = 1
const KEY_BYTES = 64
const MAXMEM = 64 * 1024 * 1024

/** 密码长度下限/上限。只做长度，不猜"弱密码库"。 */
export const PASSWORD_MIN = 10
export const PASSWORD_MAX = 200

function derive(password: string, salt: Buffer, keylen: number, options: ScryptOptions): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scryptCallback(password, salt, keylen, options, (error, key) => {
      if (error !== null) reject(error)
      else resolve(key)
    })
  })
}

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16)
  const key = await derive(password, salt, KEY_BYTES, { N, r: R, p: P, maxmem: MAXMEM })
  return `scrypt$${N}$${R}$${P}$${salt.toString('base64url')}$${key.toString('base64url')}`
}

/** 解析失败 / 参数越界 / 长度不对 → `false`（绝不抛给登录路径）。 */
export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const parts = stored.split('$')
  if (parts.length !== 6 || parts[0] !== 'scrypt') return false
  const n = Number(parts[1])
  const r = Number(parts[2])
  const p = Number(parts[3])
  if (!Number.isInteger(n) || !Number.isInteger(r) || !Number.isInteger(p)) return false
  // 上限：一行被改成 N=2^30 会把进程拖死；这些边界远高于任何正当参数。
  if (n < 1024 || n > 1_048_576 || r < 1 || r > 32 || p < 1 || p > 16) return false
  let salt: Buffer
  let expected: Buffer
  try {
    salt = Buffer.from(parts[4] ?? '', 'base64url')
    expected = Buffer.from(parts[5] ?? '', 'base64url')
  } catch {
    return false
  }
  if (salt.length < 8 || expected.length < 16) return false
  let actual: Buffer
  try {
    actual = await derive(password, salt, expected.length, { N: n, r, p, maxmem: MAXMEM })
  } catch {
    return false
  }
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

/**
 * 登录时"邮箱不存在"也要算一次摘要：否则响应时间会把"有没有这个账号"漏出去。
 * 结果懒惰生成一次，进程内复用。
 */
let dummy: Promise<string> | undefined
export function dummyHash(): Promise<string> {
  dummy ??= hashPassword(randomBytes(24).toString('base64url'))
  return dummy
}

export function passwordProblem(password: string): string | undefined {
  if (password.length < PASSWORD_MIN) return `密码至少 ${PASSWORD_MIN} 位`
  if (password.length > PASSWORD_MAX) return `密码最长 ${PASSWORD_MAX} 位`
  return undefined
}
