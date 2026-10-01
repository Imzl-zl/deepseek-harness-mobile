/**
 * 出码登记的回归（契约 §12.1）。
 *
 * 两条容易写错、又都不会报错的地方各配一条用例：**地址派生**（ws→http）
 * 与**失败必须抛**（静默成功会发出一张配不上的二维码）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createPairingRegistrar, httpBaseOf } from '../src/pairing-register.js'

const TOKEN = 'tok-1'

function fakeFetch(status: number, body = '{}') {
  const calls: { url: string; init: RequestInit | undefined }[] = []
  const impl = ((url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init })
    return Promise.resolve(new Response(body, { status }))
  }) as unknown as typeof fetch
  return { impl, calls }
}

test('地址派生：ws→http、wss→https，并且**丢掉路径**（HTTP 端点不在 WS 那条路径上）', () => {
  assert.equal(httpBaseOf('wss://relay.example/ws'), 'https://relay.example')
  assert.equal(httpBaseOf('ws://127.0.0.1:8787/ws?x=1'), 'http://127.0.0.1:8787')
  // 已经很明确的 http(s) 也照原样（便于本地直连测试）
  assert.equal(httpBaseOf('http://127.0.0.1:9000'), 'http://127.0.0.1:9000')
})

test('成功：POST /pairing/register，带 Bearer 令牌与 codeHash', async () => {
  const { impl, calls } = fakeFetch(201)
  const register = createPairingRegistrar({
    relayUrl: 'wss://relay.example/ws',
    tokenSource: () => Promise.resolve(TOKEN),
    fetchImpl: impl,
  })

  await register('hash-a')
  assert.equal(calls.length, 1)
  assert.equal(calls[0]?.url, 'https://relay.example/pairing/register')
  const init = calls[0]?.init
  assert.equal(init?.method, 'POST')
  assert.deepEqual(init?.headers, {
    authorization: `Bearer ${TOKEN}`,
    'content-type': 'application/json',
  })
  assert.deepEqual(JSON.parse(String(init?.body)), { codeHash: 'hash-a' })
})

test('非 2xx：抛，并且把**状态码**带进消息（401 与 409 的下一步动作不同）', async () => {
  const { impl } = fakeFetch(409, '{"error":"pairing-unavailable"}')
  const register = createPairingRegistrar({
    relayUrl: 'wss://relay.example/ws',
    tokenSource: () => Promise.resolve(TOKEN),
    fetchImpl: impl,
  })

  await assert.rejects(
    () => register('hash-a'),
    (error: unknown) => error instanceof Error && /HTTP 409/.test(error.message),
  )
})

test('网络错误：照原样抛（不吞、不重试 —— 出码是人工触发的一次动作）', async () => {
  const impl = (() => Promise.reject(new Error('connect ECONNREFUSED'))) as unknown as typeof fetch
  const register = createPairingRegistrar({
    relayUrl: 'wss://relay.example/ws',
    tokenSource: () => Promise.resolve(TOKEN),
    fetchImpl: impl,
  })

  await assert.rejects(() => register('hash-a'), /ECONNREFUSED/)
})
