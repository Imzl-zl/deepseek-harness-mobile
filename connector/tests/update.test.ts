/**
 * 「有没有新版本」：版本比较 + 一次查询的形状 + 失败不假装"已是最新"。
 *
 * 这一层不碰网络：`fetchImpl` 是注入的。判据只有三条：
 * 1. 比较是**数字段**的比较（`0.1.10 > 0.1.9`），预发布串不算新；
 * 2. npm 回 `version` 才算查到了；查不到时 `latest === null` 且带 `error`；
 * 3. 成功结论有缓存（TTL 内不重复打），失败**不缓存**（下次还能再试）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createUpdateChecker, isNewerVersion } from '../src/admin/update.js'

test('版本比较：按数字段，0.1.10 > 0.1.9；预发布不算新', () => {
  assert.equal(isNewerVersion('0.1.8', '0.1.9'), true)
  assert.equal(isNewerVersion('0.1.9', '0.1.10'), true, '字符串比会错，这里必须是数字段')
  assert.equal(isNewerVersion('0.1.10', '0.1.10'), false)
  assert.equal(isNewerVersion('0.2.0', '0.1.99'), false)
  assert.equal(isNewerVersion('0.1.8', '0.1.8-rc.1'), false, '预发布不比正式版新')
  assert.equal(isNewerVersion('0.1', '0.1.1'), true, '短版本按缺 0 处理')
})

const responseOf = (version: string) => ({
  ok: true,
  status: 200,
  json: async () => ({ version }),
}) as unknown as Response

test('查到新版：hasUpdate + npm 包页链接', async () => {
  const checker = createUpdateChecker({
    current: '0.1.8',
    fetchImpl: (async () => responseOf('0.2.0')) as unknown as typeof fetch,
  })
  const info = await checker.check()
  assert.equal(info.latest, '0.2.0')
  assert.equal(info.hasUpdate, true)
  assert.equal(info.url, 'https://www.npmjs.com/package/dsh-mobile-connector/v/0.2.0')
  assert.equal(info.error, undefined)
})

test('已是最新：hasUpdate 为 false，但仍带 latest', async () => {
  const checker = createUpdateChecker({
    current: '0.1.8',
    fetchImpl: (async () => responseOf('0.1.8')) as unknown as typeof fetch,
  })
  const info = await checker.check()
  assert.equal(info.latest, '0.1.8')
  assert.equal(info.hasUpdate, false)
})

test('查询失败：latest 为 null、带原话，绝不报"已是最新"', async () => {
  const checker = createUpdateChecker({
    current: '0.1.8',
    fetchImpl: (async () => {
      throw new Error('getaddrinfo ENOTFOUND registry.npmjs.org')
    }) as unknown as typeof fetch,
  })
  const info = await checker.check()
  assert.equal(info.latest, null)
  assert.equal(info.hasUpdate, false)
  assert.match(info.error ?? '', /ENOTFOUND/)
})

test('成功结论有缓存，失败不缓存', async () => {
  let calls = 0
  const okChecker = createUpdateChecker({
    current: '0.1.8',
    now: () => 1_000,
    ttlMs: 60_000,
    fetchImpl: (async () => {
      calls += 1
      return responseOf('0.1.9')
    }) as unknown as typeof fetch,
  })
  await okChecker.check()
  await okChecker.check()
  assert.equal(calls, 1, 'TTL 内只打一次网络')

  let failures = 0
  const badChecker = createUpdateChecker({
    current: '0.1.8',
    now: () => 1_000,
    ttlMs: 60_000,
    fetchImpl: (async () => {
      failures += 1
      throw new Error('boom')
    }) as unknown as typeof fetch,
  })
  await badChecker.check()
  await badChecker.check()
  assert.equal(failures, 2, '失败不缓存：用户再点一次就该再试一次')
})
