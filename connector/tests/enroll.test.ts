/**
 * 连接器自助兑换（`src/enroll.ts`）。
 *
 * 守三件事：
 *
 * 1. **地址派生不丢端口**：`wss://host:8788/ws/connector` → `https://host:8788/connector/enroll`
 *    （自部署常不在 443 上，抹掉端口会变成"地址明明对、永远拨不通"）；
 * 2. **三种失败各有台词**：403 要求管理员发令牌、429 名额满、其它按原文；
 * 3. 201 的响应形状不对就报错，不返回半截结果。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { EnrollError, enrollConnector, enrollUrlOf } from '../src/enroll.js'

const response = (status: number, body: unknown) => ({
  status,
  text: async () => JSON.stringify(body),
})

test('地址派生：wss → https 且保留端口与路径替换', () => {
  assert.equal(
    enrollUrlOf('wss://dsh.example.com/ws/connector'),
    'https://dsh.example.com/connector/enroll',
  )
  assert.equal(
    enrollUrlOf('wss://relay.example.com:8788/ws/connector'),
    'https://relay.example.com:8788/connector/enroll',
  )
  // 明文联调（`allowInsecureLocal`）那一档：ws → http。
  assert.equal(
    enrollUrlOf('ws://127.0.0.1:8787/ws/connector'),
    'http://127.0.0.1:8787/connector/enroll',
  )
})

test('不是 WebSocket 地址：直接拒绝（不猜协议）', () => {
  assert.throws(() => enrollUrlOf('https://relay.example.com/ws/connector'), EnrollError)
})

test('201：返回 token 与 connectorId，请求体带 pcId 与 name', async () => {
  let seenBody = ''
  const result = await enrollConnector({
    relayUrl: 'wss://relay.example.com/ws/connector',
    pcId: 'pc-1',
    name: '我的台式机',
    fetchImpl: async (_url, init) => {
      seenBody = init.body
      return response(201, { token: 'tok-1', connectorId: 'auto-1' })
    },
  })
  assert.deepEqual(result, { token: 'tok-1', connectorId: 'auto-1' })
  assert.deepEqual(JSON.parse(seenBody), { pcId: 'pc-1', name: '我的台式机' })
})

test('name 为空时不进请求体', async () => {
  let seenBody = ''
  await enrollConnector({
    relayUrl: 'wss://relay.example.com/ws/connector',
    pcId: 'pc-1',
    fetchImpl: async (_url, init) => {
      seenBody = init.body
      return response(201, { token: 'tok-1', connectorId: 'auto-1' })
    },
  })
  assert.deepEqual(JSON.parse(seenBody), { pcId: 'pc-1' })
})

test('201 但形状不对：报错，不返回半截结果', async () => {
  await assert.rejects(
    enrollConnector({
      relayUrl: 'wss://relay.example.com/ws/connector',
      pcId: 'pc-1',
      fetchImpl: async () => response(201, { connectorId: 'auto-1' }),
    }),
    (error: unknown) => error instanceof EnrollError && error.status === 201,
  )
})

test('403：台词是"要管理员发令牌"，而不是含糊的重试提示', async () => {
  await assert.rejects(
    enrollConnector({
      relayUrl: 'wss://relay.example.com/ws/connector',
      pcId: 'pc-1',
      fetchImpl: async () => response(403, { error: 'connector-auth-required' }),
    }),
    (error: unknown) =>
      error instanceof EnrollError
      && error.status === 403
      && error.code === 'connector-auth-required'
      && /管理员签发令牌/.test(error.message),
  )
})

test('429 auto-enroll-full：台词是"名额已满"', async () => {
  await assert.rejects(
    enrollConnector({
      relayUrl: 'wss://relay.example.com/ws/connector',
      pcId: 'pc-1',
      fetchImpl: async () => response(429, { error: 'auto-enroll-full' }),
    }),
    (error: unknown) =>
      error instanceof EnrollError && error.status === 429 && /名额已满/.test(error.message),
  )
})

test('429 限流与 500：各自带出状态码，便于现场判断', async () => {
  await assert.rejects(
    enrollConnector({
      relayUrl: 'wss://relay.example.com/ws/connector',
      pcId: 'pc-1',
      fetchImpl: async () => response(429, { error: 'rate-limited', retryAfterMs: 1000 }),
    }),
    (error: unknown) => error instanceof EnrollError && /限流/.test(error.message),
  )
  await assert.rejects(
    enrollConnector({
      relayUrl: 'wss://relay.example.com/ws/connector',
      pcId: 'pc-1',
      fetchImpl: async () => response(500, { error: 'enroll-failed' }),
    }),
    (error: unknown) =>
      error instanceof EnrollError && error.status === 500 && error.code === 'enroll-failed',
  )
})
