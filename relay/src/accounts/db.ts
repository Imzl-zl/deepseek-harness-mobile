/**
 * 账号库（SQLite，`node:sqlite`）。
 *
 * ## 为什么账号要落库，而令牌仍留在配置里
 *
 * 令牌是"这台机器有哪几把钥匙"，条数由 owner 手工控制；账号是**公开注册**产生的，
 * 条数没有上限，而且每次登录/注册都要写。把它写进 `relay.config.json` 会让
 * "注册一个人"变成"整份凭据表重写一次"——那正是配置当库用的老毛病。
 *
 * 令牌这轮仍留在配置：`token-table.ts` 与 `issue-token.ts` 的 132 条既有用例都盯着它，
 * 先把账号切开，令牌迁移留到有第二个写入方（多实例/管理 API）时再做。
 *
 * ## 三条纪律
 *
 * 1. **密码只存 scrypt 摘要**（`password.ts`），本模块不碰明文。
 * 2. **会话只存 `sha256(令牌)`**；cookie 里的原文从不出现在库里。
 * 3. **schema 版本用 `PRAGMA user_version`**：低版本逐代升，高版本拒绝打开 ——
 *    与 connector 的 `kv:meta.schema` 同一条纪律。
 *
 * Note: 为什么账号落 SQLite、为什么令牌不一起迁 —— 见
 * `.agents/notes/implemented/2026-11-02-relay-accounts-and-connector-binding.md`
 */
import { randomBytes } from 'node:crypto'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { DatabaseSync } from 'node:sqlite'

export type UserRole = 'admin' | 'user'
export type UserStatus = 'active' | 'suspended'

/** 库里的用户行（含摘要；只在 `db.ts` 与密码校验处流转）。 */
export interface UserRecord {
  id: string
  email: string
  emailVerifiedAt: number | null
  passwordHash: string
  displayName: string
  role: UserRole
  status: UserStatus
  createdAt: number
  lastLoginAt: number | null
  maxConnectors: number | null
  quotaBytes: number | null
}

/** 能出库的用户投影（**没有摘要**）。 */
export interface PublicUser {
  id: string
  email: string
  displayName: string
  role: UserRole
  status: UserStatus
  createdAt: number
  lastLoginAt: number | null
  maxConnectors: number | null
  quotaBytes: number | null
  emailVerified: boolean
}

export interface SessionRecord {
  id: string
  userId: string
  tokenHash: string
  createdAt: number
  lastSeenAt: number
  expiresAt: number
  ip: string
  userAgent: string
  revokedAt: number | null
}

export interface CreateUserInput {
  email: string
  passwordHash: string
  displayName: string
  role: UserRole
  emailVerifiedAt: number | null
  maxConnectors: number | null
  quotaBytes: number | null
}

export interface CreateSessionInput {
  id: string
  userId: string
  tokenHash: string
  createdAt: number
  expiresAt: number
  ip: string
  userAgent: string
}

export interface AccountsDb {
  /** 库里那枚 HMAC 密钥（CSRF 派生用）。只在本进程内使用。 */
  readonly secret: string
  createUser(input: CreateUserInput): PublicUser
  findByEmail(email: string): UserRecord | undefined
  findById(id: string): UserRecord | undefined
  listUsers(limit: number): PublicUser[]
  countUsers(): number
  updateLastLogin(id: string, at: number): void
  updatePassword(id: string, passwordHash: string): boolean
  setStatus(id: string, status: UserStatus): boolean
  setRole(id: string, role: UserRole): boolean
  setLimits(id: string, patch: { maxConnectors?: number | null; quotaBytes?: number | null }): boolean

  createSession(input: CreateSessionInput): void
  sessionByTokenHash(tokenHash: string, now: number): SessionRecord | undefined
  touchSession(id: string, at: number): void
  revokeSession(id: string, at: number): boolean
  revokeUserSessions(userId: string, at: number, exceptId?: string): number
  listSessions(userId: string, now: number): SessionRecord[]
  deleteExpiredSessions(now: number): number
  close(): void
}

export class EmailTakenError extends Error {
  constructor(email: string) {
    super(`邮箱已被注册：${email}`)
    this.name = 'EmailTakenError'
  }
}

const SCHEMA_VERSION = 1

const newId = (prefix: string): string => `${prefix}${randomBytes(9).toString('base64url')}`

const numberOrNull = (value: unknown): number | null =>
  typeof value === 'number' ? value : typeof value === 'bigint' ? Number(value) : null

const stringOrEmpty = (value: unknown): string => (typeof value === 'string' ? value : '')

function rowToUser(row: Record<string, unknown>): UserRecord {
  return {
    id: stringOrEmpty(row['id']),
    email: stringOrEmpty(row['email']),
    emailVerifiedAt: numberOrNull(row['email_verified_at']),
    passwordHash: stringOrEmpty(row['password_hash']),
    displayName: stringOrEmpty(row['display_name']),
    role: row['role'] === 'admin' ? 'admin' : 'user',
    status: row['status'] === 'suspended' ? 'suspended' : 'active',
    createdAt: numberOrNull(row['created_at']) ?? 0,
    lastLoginAt: numberOrNull(row['last_login_at']),
    maxConnectors: numberOrNull(row['max_connectors']),
    quotaBytes: numberOrNull(row['quota_bytes']),
  }
}

export function publicUserOf(user: UserRecord): PublicUser {
  return {
    id: user.id,
    email: user.email,
    displayName: user.displayName,
    role: user.role,
    status: user.status,
    createdAt: user.createdAt,
    lastLoginAt: user.lastLoginAt,
    maxConnectors: user.maxConnectors,
    quotaBytes: user.quotaBytes,
    emailVerified: user.emailVerifiedAt !== null,
  }
}

function rowToSession(row: Record<string, unknown>): SessionRecord {
  return {
    id: stringOrEmpty(row['id']),
    userId: stringOrEmpty(row['user_id']),
    tokenHash: stringOrEmpty(row['token_hash']),
    createdAt: numberOrNull(row['created_at']) ?? 0,
    lastSeenAt: numberOrNull(row['last_seen_at']) ?? 0,
    expiresAt: numberOrNull(row['expires_at']) ?? 0,
    ip: stringOrEmpty(row['ip']),
    userAgent: stringOrEmpty(row['user_agent']),
    revokedAt: numberOrNull(row['revoked_at']),
  }
}

/**
 * 打开账号库。路径可以是 `:memory:`（测试）。
 *
 * 目录会先建出来：Docker 里挂的是目录而不是单文件 —— WAL 会生成
 * `-wal` / `-shm` 兄弟文件，单文件 bind mount 会把它们挡在容器外。
 */
export function createAccountsDb(path: string): AccountsDb {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true })
  const db = new DatabaseSync(path)

  // WAL：读不挡写；`busy_timeout` 给 CLI / 备份工具留出等待窗口。
  db.exec('PRAGMA journal_mode = WAL')
  db.exec('PRAGMA synchronous = NORMAL')
  db.exec('PRAGMA busy_timeout = 5000')
  db.exec('PRAGMA foreign_keys = ON')

  const versionRow = db.prepare('PRAGMA user_version').get()
  const version = numberOrNull(versionRow?.['user_version']) ?? 0
  if (version > SCHEMA_VERSION) {
    db.close()
    throw new Error(
      `账号库 schema 版本是 ${version}，本进程只认 ${SCHEMA_VERSION}：拒绝打开，先把中转升级到同一代`,
    )
  }
  if (version < 1) {
    db.exec(`
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      ) STRICT;

      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        email_verified_at INTEGER,
        password_hash TEXT NOT NULL,
        display_name TEXT NOT NULL,
        role TEXT NOT NULL CHECK (role IN ('admin', 'user')),
        status TEXT NOT NULL CHECK (status IN ('active', 'suspended')),
        created_at INTEGER NOT NULL,
        last_login_at INTEGER,
        max_connectors INTEGER,
        quota_bytes INTEGER
      ) STRICT;

      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        token_hash TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        ip TEXT NOT NULL DEFAULT '',
        user_agent TEXT NOT NULL DEFAULT '',
        revoked_at INTEGER
      ) STRICT;

      CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);
      CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions(expires_at);

      PRAGMA user_version = 1;
    `)
  }

  let secretRow = db.prepare('SELECT value FROM meta WHERE key = ?').get('secret')
  if (secretRow === undefined) {
    const secret = randomBytes(32).toString('base64url')
    db.prepare('INSERT INTO meta (key, value) VALUES (?, ?)').run('secret', secret)
    secretRow = { value: secret }
  }
  const secret = stringOrEmpty(secretRow['value'])

  const insertUser = db.prepare(`
    INSERT INTO users (id, email, email_verified_at, password_hash, display_name, role, status,
                       created_at, last_login_at, max_connectors, quota_bytes)
    VALUES (?, ?, ?, ?, ?, ?, 'active', ?, NULL, ?, ?)
  `)
  const selectUserByEmail = db.prepare('SELECT * FROM users WHERE email = ?')
  const selectUserById = db.prepare('SELECT * FROM users WHERE id = ?')
  const selectUsers = db.prepare(`
    SELECT id, email, email_verified_at, password_hash, display_name, role, status,
           created_at, last_login_at, max_connectors, quota_bytes
    FROM users ORDER BY created_at DESC LIMIT ?
  `)
  const countUsers = db.prepare('SELECT COUNT(*) AS n FROM users')
  const updateLastLogin = db.prepare('UPDATE users SET last_login_at = ? WHERE id = ?')
  const updatePassword = db.prepare('UPDATE users SET password_hash = ? WHERE id = ?')
  const updateStatus = db.prepare('UPDATE users SET status = ? WHERE id = ?')
  const updateRole = db.prepare('UPDATE users SET role = ? WHERE id = ?')
  const updateMaxConnectors = db.prepare('UPDATE users SET max_connectors = ? WHERE id = ?')
  const updateQuota = db.prepare('UPDATE users SET quota_bytes = ? WHERE id = ?')

  const insertSession = db.prepare(`
    INSERT INTO sessions (id, user_id, token_hash, created_at, last_seen_at, expires_at, ip, user_agent, revoked_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
  `)
  const selectSessionByHash = db.prepare(`
    SELECT * FROM sessions
    WHERE token_hash = ? AND revoked_at IS NULL AND expires_at > ?
  `)
  const touchSessionStmt = db.prepare('UPDATE sessions SET last_seen_at = ? WHERE id = ?')
  const revokeSessionStmt = db.prepare('UPDATE sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL')
  const revokeAllStmt = db.prepare('UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL')
  const revokeAllExceptStmt = db.prepare(
    'UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND id <> ? AND revoked_at IS NULL',
  )
  const listSessionsStmt = db.prepare(`
    SELECT * FROM sessions WHERE user_id = ? AND revoked_at IS NULL AND expires_at > ?
    ORDER BY created_at DESC
  `)
  const deleteExpired = db.prepare('DELETE FROM sessions WHERE expires_at <= ? OR revoked_at IS NOT NULL')

  const changesOf = (result: { changes: number | bigint }): number => Number(result.changes)

  return {
    secret,

    createUser(input) {
      const id = newId('u_')
      try {
        insertUser.run(
          id,
          input.email,
          input.emailVerifiedAt,
          input.passwordHash,
          input.displayName,
          input.role,
          Date.now(),
          input.maxConnectors,
          input.quotaBytes,
        )
      } catch (error) {
        if (error instanceof Error && error.message.includes('UNIQUE constraint failed: users.email')) {
          throw new EmailTakenError(input.email)
        }
        throw error
      }
      const created = selectUserById.get(id)
      if (created === undefined) throw new Error('账号写入后读不回来')
      return publicUserOf(rowToUser(created))
    },

    findByEmail(email) {
      const row = selectUserByEmail.get(email)
      return row === undefined ? undefined : rowToUser(row)
    },

    findById(id) {
      const row = selectUserById.get(id)
      return row === undefined ? undefined : rowToUser(row)
    },

    listUsers(limit) {
      return selectUsers.all(limit).map((row) => publicUserOf(rowToUser(row)))
    },

    countUsers() {
      return numberOrNull(countUsers.get()?.['n']) ?? 0
    },

    updateLastLogin(id, at) { updateLastLogin.run(at, id) },

    updatePassword(id, passwordHash) { return changesOf(updatePassword.run(passwordHash, id)) > 0 },

    setStatus(id, status) { return changesOf(updateStatus.run(status, id)) > 0 },

    setRole(id, role) { return changesOf(updateRole.run(role, id)) > 0 },

    setLimits(id, patch) {
      let changed = false
      if (patch.maxConnectors !== undefined) {
        changed = changesOf(updateMaxConnectors.run(patch.maxConnectors, id)) > 0 || changed
      }
      if (patch.quotaBytes !== undefined) {
        changed = changesOf(updateQuota.run(patch.quotaBytes, id)) > 0 || changed
      }
      return changed
    },

    createSession(input) {
      insertSession.run(
        input.id,
        input.userId,
        input.tokenHash,
        input.createdAt,
        input.createdAt,
        input.expiresAt,
        input.ip,
        input.userAgent,
      )
    },

    sessionByTokenHash(tokenHash, now) {
      const row = selectSessionByHash.get(tokenHash, now)
      return row === undefined ? undefined : rowToSession(row)
    },

    touchSession(id, at) { touchSessionStmt.run(at, id) },

    revokeSession(id, at) { return changesOf(revokeSessionStmt.run(at, id)) > 0 },

    revokeUserSessions(userId, at, exceptId) {
      return exceptId === undefined
        ? changesOf(revokeAllStmt.run(at, userId))
        : changesOf(revokeAllExceptStmt.run(at, userId, exceptId))
    },

    listSessions(userId, now) {
      return listSessionsStmt.all(userId, now).map((row) => rowToSession(row))
    },

    deleteExpiredSessions(now) { return changesOf(deleteExpired.run(now)) },

    close() { db.close() },
  }
}
