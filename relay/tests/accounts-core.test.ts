/** 账号底座：密码摘要、邮箱白名单、验证码、SQLite 库。 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createAccountsDb, EmailTakenError } from '../src/accounts/db.ts'
import { createCodeStore, emailProblem, normalizeEmail } from '../src/accounts/email.ts'
import { hashPassword, passwordProblem, verifyPassword } from '../src/accounts/password.ts'

test('密码：正确密码通过，错误密码/坏格式一律 false，长度有下限', async () => {
  const hash = await hashPassword('correct horse battery staple')
  assert.match(hash, /^scrypt\$16384\$8\$1\$/)
  assert.equal(await verifyPassword('correct horse battery staple', hash), true)
  assert.equal(await verifyPassword('wrong password', hash), false)
  assert.equal(await verifyPassword('x', 'not-a-hash'), false)
  // 参数越界不进入大内存计算。
  assert.equal(await verifyPassword('x', 'scrypt$99999999$8$1$AAAA$BBBB'), false)
  assert.equal(passwordProblem('short'), '密码至少 10 位')
})

test('邮箱：规范化、格式、QQ 白名单', () => {
  assert.equal(normalizeEmail('  A@QQ.com '), 'a@qq.com')
  assert.equal(normalizeEmail('bad'), undefined)
  assert.equal(normalizeEmail('a@b'), undefined)
  assert.equal(emailProblem('a@example.com', { domains: ['qq.com'] })?.code, 'email-domain')
  assert.equal(emailProblem('A@QQ.COM', { domains: ['qq.com'] }), undefined)
  assert.equal(emailProblem('a@example.com', { domains: [] }), undefined)
})

test('验证码：冷却、过期、尝试次数上限', () => {
  let clock = 1_000
  const store = createCodeStore({
    now: () => clock,
    ttlMs: 1_000,
    cooldownMs: 100,
    maxAttempts: 2,
    generate: () => '123456',
  })
  const first = store.issue('a@qq.com', 'register')
  assert.equal(first.ok, true)
  const cooling = store.issue('a@qq.com', 'register')
  assert.equal(cooling.ok, false)
  if (!cooling.ok) assert.equal(cooling.retryAfterMs, 100)

  assert.equal(store.verify('a@qq.com', 'register', '000000'), 'invalid')
  assert.equal(store.verify('a@qq.com', 'register', '000000'), 'too-many')

  clock += 200
  const again = store.issue('a@qq.com', 'register')
  assert.equal(again.ok, true)
  assert.equal(store.verify('a@qq.com', 'register', '123456'), 'ok')
  assert.equal(store.verify('a@qq.com', 'register', '123456'), 'invalid', '一次性')

  clock += 200
  store.issue('b@qq.com', 'register')
  clock += 2_000
  assert.equal(store.verify('b@qq.com', 'register', '123456'), 'invalid', '过期即失效')
})

test('账号库：唯一邮箱、会话过期/吊销、限额与角色', () => {
  const db = createAccountsDb(':memory:')
  const user = db.createUser({
    email: 'a@qq.com',
    passwordHash: 'scrypt$x',
    displayName: 'A',
    role: 'user',
    emailVerifiedAt: 1,
    maxConnectors: null,
    quotaBytes: 100,
  })
  assert.equal(db.findByEmail('a@qq.com')?.id, user.id)
  assert.equal(db.countUsers(), 1)
  assert.throws(
    () => db.createUser({
      email: 'a@qq.com', passwordHash: 'x', displayName: 'A2', role: 'user',
      emailVerifiedAt: 1, maxConnectors: null, quotaBytes: null,
    }),
    EmailTakenError,
  )

  db.createSession({
    id: 's1', userId: user.id, tokenHash: 'h1', createdAt: 1_000, expiresAt: 2_000,
    ip: '127.0.0.1', userAgent: 'test',
  })
  assert.equal(db.sessionByTokenHash('h1', 1_500)?.id, 's1')
  assert.equal(db.sessionByTokenHash('h1', 2_500), undefined, '过期即查不到')
  db.revokeSession('s1', 1_600)
  assert.equal(db.sessionByTokenHash('h1', 1_500), undefined, '吊销即查不到')
  assert.equal(db.listSessions(user.id, 1_500).length, 0)

  assert.equal(db.setRole(user.id, 'admin'), true)
  assert.equal(db.findById(user.id)?.role, 'admin')
  assert.equal(db.setStatus(user.id, 'suspended'), true)
  assert.equal(db.findById(user.id)?.status, 'suspended')
  assert.equal(db.setLimits(user.id, { maxConnectors: 2, quotaBytes: null }), true)
  assert.equal(db.findById(user.id)?.maxConnectors, 2)
  assert.equal(db.findById(user.id)?.quotaBytes, null)
  db.close()
})
