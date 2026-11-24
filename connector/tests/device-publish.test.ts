/**
 * 名册一行的形状（`device-publish.ts` 的 `rosterEntry`）。
 *
 * 这一篇只钉三条，但每条都有事故背景：
 *
 * 1. **停用的行照样上报**（带 `revokedAt`）—— 它是中转说 `device-revoked` 的
 *    唯一来源。报漏了，手机侧收到的就是 `device-unknown`（"名册还没同步"那一档），
 *    于是它一直重试，用户看不到"你被停用了"，停用功能在他那边等于没发生。
 * 2. **没有 `tokenHash` 的行不报**：缺摘要 = 换不到票，报了只会让中转留一份
 *    过期的归属（`device-registry` 的纪律 4 会按差集删，但没必要先塞进去）。
 * 3. **形状逐字**：名册字段名就是中转 `DeviceRegistration` 的字段名，多一个少一个
 *    都算契约漂移（中转的 `parseRegistrations` 对未知字段是忽略，所以这里靠测试钉）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createDevicePublisher, rosterEntry } from '../src/device-publish.js'
import { silentLogger } from '../src/observability.js'

/** `devices` 表里的一行（与 `store/index.ts` 的 `DeviceRecord` 同形）。 */
const record = {
  edPub: 'a'.repeat(64),
  dhPub: 'b'.repeat(64),
  name: '我的手机',
  pairedAt: 1760000000000,
  pairingId: 'pair-1',
  tokenHash: 'c'.repeat(64),
}

test('未停用的行：不含 revokedAt 这个键（不是 undefined 值）', () => {
  const entry = rosterEntry('dev-1', record)
  assert.deepEqual(entry, {
    id: 'dev-1',
    pairingId: 'pair-1',
    devPubEd: record.edPub,
    devPubDh: record.dhPub,
    name: '我的手机',
    tokenHash: record.tokenHash,
  })
  assert.equal('revokedAt' in (entry ?? {}), false, 'JSON 里不该出现 revokedAt:null/undefined')
})

test('停用的行照样上报，带 revokedAt（device-revoked 的唯一来源）', () => {
  const entry = rosterEntry('dev-1', { ...record, revokedAt: 1760000500000 })
  assert.equal(entry?.revokedAt, 1760000500000)
  assert.equal(entry?.tokenHash, record.tokenHash, '停用不摘摘要：中转要靠它认出这枚令牌')
})

test('没有 tokenHash 的行报不进名册（换不到票，报了也没用）', () => {
  const { tokenHash: _omit, ...withoutHash } = record
  assert.equal(rosterEntry('dev-1', withoutHash), undefined)
})

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (error: unknown) => void
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}

const afterTurn = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))
const entry = (revokedAt?: number) => {
  const result = rosterEntry('dev-1', { ...record, ...(revokedAt === undefined ? {} : { revokedAt }) })
  assert.ok(result !== undefined)
  return result
}
const success = (): Response => new Response(null, { status: 201 })

test('发布 FIFO：旧 tokenSource 等待不能让旧名册越过新的停用快照', { timeout: 60_000 }, async () => {
  const token = deferred<string>()
  let reads = 0
  const applied: unknown[] = []
  const publisher = createDevicePublisher({
    relayUrl: () => 'wss://relay.example.com/ws/connector',
    tokenSource: () => ++reads === 1 ? token.promise : Promise.resolve('synthetic-connector-token'),
    fetchImpl: async (_url, init) => {
      applied.push((JSON.parse(String(init?.body)) as { devices: unknown[] }).devices)
      return success()
    },
  })
  const oldRows = [entry()]
  const nextRows = [entry(17)]
  const old = publisher(oldRows)
  const next = publisher(nextRows)
  try {
    await afterTurn()
    assert.equal(reads, 1, '第二份快照必须在同一条发布链上，不能抢先读取 token/发送')
  } finally {
    token.resolve('synthetic-connector-token')
    await Promise.all([old, next])
  }
  assert.deepEqual(applied, [oldRows, nextRows], '中转最后收到的必须是新停用快照')
})

test('发布快照：入队后调用者改行不能改变这次上报内容', { timeout: 60_000 }, async () => {
  const token = deferred<string>()
  const source = entry()
  const expected = { ...source }
  let received: unknown
  const publisher = createDevicePublisher({
    relayUrl: () => 'wss://relay.example.com/ws/connector',
    tokenSource: () => token.promise,
    fetchImpl: async (_url, init) => { received = JSON.parse(String(init?.body)); return success() },
  })
  const pending = publisher([source])
  source.name = 'caller-mutated-after-enqueue'
  token.resolve('synthetic-connector-token')
  await pending
  assert.deepEqual(received, { devices: [expected] })
})

test('schedule：本地调用不等 HTTP，pending 直到名册真正上报成功', { timeout: 60_000 }, async () => {
  const response = deferred<Response>()
  let sent = 0
  const publisher = createDevicePublisher({
    relayUrl: () => 'wss://relay.example.com/ws/connector',
    tokenSource: async () => 'synthetic-connector-token',
    fetchImpl: async () => { sent += 1; return response.promise },
  })
  assert.equal(typeof publisher.schedule, 'function', '必须提供非等待调度入口')
  assert.equal(publisher.schedule([entry(17)]), undefined)
  assert.equal(publisher.state().status, 'pending', '入队不是乐观成功')
  try {
    await afterTurn()
    assert.equal(sent, 1)
    assert.equal(publisher.state().status, 'pending')
  } finally {
    response.resolve(success())
    await afterTurn()
  }
  assert.deepEqual(publisher.state(), { status: 'synced' })
})

test('schedule：未连接即 deferred，不读令牌/不发 HTTP，也不私自重试', { timeout: 60_000 }, async () => {
  let available = false
  let reads = 0
  let sent = 0
  const publisher = createDevicePublisher({
    relayUrl: () => 'wss://relay.example.com/ws/connector',
    available: () => available,
    tokenSource: async () => { reads += 1; return 'synthetic-connector-token' },
    fetchImpl: async () => { sent += 1; return success() },
  })
  assert.equal(typeof publisher.schedule, 'function')
  publisher.schedule([entry(17)])
  assert.deepEqual(publisher.state(), { status: 'deferred' })
  await afterTurn()
  assert.equal(reads, 0)
  assert.equal(sent, 0)
  available = true
  await afterTurn()
  assert.equal(sent, 0, '通道恢复由既有 onConnected 主动报全量，不创建私有重试器')
  await publisher([entry(17)])
  assert.equal(sent, 1)
  assert.deepEqual(publisher.state(), { status: 'synced' })
})

test('schedule：排队时在线、轮到它时离线，也不得读取令牌/发 HTTP', { timeout: 60_000 }, async () => {
  const firstResponse = deferred<Response>()
  let available = true
  let reads = 0
  let sent = 0
  const publisher = createDevicePublisher({
    relayUrl: () => 'wss://relay.example.com/ws/connector',
    available: () => available,
    tokenSource: async () => { reads += 1; return 'synthetic-connector-token' },
    fetchImpl: async () => { sent += 1; return firstResponse.promise },
  })
  const first = publisher([entry()])
  try {
    assert.equal(typeof publisher.schedule, 'function')
    publisher.schedule([entry(17)])
    await afterTurn()
    assert.equal(sent, 1)
    available = false
  } finally {
    firstResponse.resolve(success())
    await first
    await afterTurn()
  }
  assert.equal(reads, 1)
  assert.equal(sent, 1)
  assert.deepEqual(publisher.state(), { status: 'deferred' })
})

test('schedule：等令牌期间断开时不继续发 HTTP，保持 deferred', { timeout: 60_000 }, async () => {
  const token = deferred<string>()
  let available = true
  let sent = 0
  const publisher = createDevicePublisher({
    relayUrl: () => 'wss://relay.example.com/ws/connector',
    available: () => available,
    tokenSource: () => token.promise,
    fetchImpl: async () => { sent += 1; return success() },
  })
  assert.equal(typeof publisher.schedule, 'function')
  publisher.schedule([entry(17)])
  await afterTurn()
  available = false
  token.resolve('synthetic-connector-token')
  await afterTurn()
  assert.equal(sent, 0)
  assert.deepEqual(publisher.state(), { status: 'deferred' })
})

test('schedule：后台失败同时留下 error 原因与日志，不吞错成 synced/不自行重试', { timeout: 60_000 }, async () => {
  const error = new Error('synthetic relay unavailable')
  const logged: Array<{ message: string; detail: unknown }> = []
  let sent = 0
  const publisher = createDevicePublisher({
    relayUrl: () => 'wss://relay.example.com/ws/connector',
    tokenSource: async () => 'synthetic-connector-token',
    fetchImpl: async () => { sent += 1; throw error },
    log: { ...silentLogger, error: (message, detail) => logged.push({ message, detail }) },
  })
  assert.equal(typeof publisher.schedule, 'function')
  publisher.schedule([entry(17)])
  await afterTurn()
  assert.deepEqual(publisher.state(), { status: 'error', error: error.message })
  assert.equal(logged.length, 1)
  assert.equal(logged[0]?.detail, error, '保留原因，不翻译成假的本地失败')
  assert.match(logged[0]?.message ?? '', /名册.*失败/)
  await afterTurn()
  assert.equal(sent, 1, '没有私有重试循环')
})

test('发布状态：旧任务成功不能把仍在排队的新快照冒充 synced', { timeout: 60_000 }, async () => {
  const firstResponse = deferred<Response>()
  const nextResponse = deferred<Response>()
  let sent = 0
  const publisher = createDevicePublisher({
    relayUrl: () => 'wss://relay.example.com/ws/connector',
    tokenSource: async () => 'synthetic-connector-token',
    fetchImpl: async () => ++sent === 1 ? firstResponse.promise : nextResponse.promise,
  })
  const first = publisher([entry()])
  try {
    assert.equal(typeof publisher.schedule, 'function')
    publisher.schedule([entry(17)])
    await afterTurn()
    firstResponse.resolve(success())
    await first
    await afterTurn()
    assert.equal(sent, 2)
    assert.deepEqual(publisher.state(), { status: 'pending' })
  } finally {
    firstResponse.resolve(success())
    nextResponse.resolve(success())
    await afterTurn()
  }
  assert.deepEqual(publisher.state(), { status: 'synced' })
})

test('原可调用 API：失败仍 reject 原因，之后的空名册能继续发布且清掉旧错误', { timeout: 60_000 }, async () => {
  const error = new Error('synthetic first publish failed')
  let sent = 0
  let received: unknown
  const publisher = createDevicePublisher({
    relayUrl: () => 'wss://relay.example.com/ws/connector',
    tokenSource: async () => 'synthetic-connector-token',
    fetchImpl: async (_url, init) => {
      if (++sent === 1) throw error
      received = JSON.parse(String(init?.body))
      return success()
    },
  })
  await assert.rejects(publisher([entry()]), (actual) => actual === error)
  assert.equal(typeof publisher.state, 'function')
  assert.deepEqual(publisher.state(), { status: 'error', error: error.message })
  await publisher([])
  assert.deepEqual(received, { devices: [] })
  assert.deepEqual(publisher.state(), { status: 'synced' })
  assert.equal(sent, 2)
})

test('发布热改：排队任务轮到时才现取 relay 地址和令牌', { timeout: 60_000 }, async () => {
  const firstResponse = deferred<Response>()
  let url = 'wss://old-relay.example.com/ws/connector'
  let token = 'synthetic-old-token'
  const sent: Array<{ url: string; authorization: string | null; rows: unknown[] }> = []
  const publisher = createDevicePublisher({
    relayUrl: () => url,
    tokenSource: async () => token,
    fetchImpl: async (endpoint, init) => {
      sent.push({
        url: String(endpoint),
        authorization: new Headers(init?.headers).get('authorization'),
        rows: (JSON.parse(String(init?.body)) as { devices: unknown[] }).devices,
      })
      return sent.length === 1 ? firstResponse.promise : success()
    },
  })
  const oldRows = [entry()]
  const nextRows = [entry(17)]
  const first = publisher(oldRows)
  await afterTurn()
  const next = publisher(nextRows)
  // 已入队还没执行，随后配置/凭据热改；第二个槽必须读新的两格。
  url = 'wss://new-relay.example.com/ws/connector'
  token = 'synthetic-new-token'
  firstResponse.resolve(success())
  await Promise.all([first, next])

  assert.deepEqual(sent, [
    { url: 'https://old-relay.example.com/devices', authorization: 'Bearer synthetic-old-token', rows: oldRows },
    { url: 'https://new-relay.example.com/devices', authorization: `Bearer ${token}`, rows: nextRows },
  ])
  assert.deepEqual(publisher.state(), { status: 'synced' })
})

test('发布状态：旧在途成功不能覆盖后来离线调度的 deferred', { timeout: 60_000 }, async () => {
  const firstResponse = deferred<Response>()
  let available = true
  let sent = 0
  const publisher = createDevicePublisher({
    relayUrl: () => 'wss://relay.example.com/ws/connector',
    available: () => available,
    tokenSource: async () => 'synthetic-connector-token',
    fetchImpl: async () => { sent += 1; return firstResponse.promise },
  })
  const first = publisher([entry()])
  try {
    await afterTurn()
    available = false
    publisher.schedule([entry(17)])
    assert.deepEqual(publisher.state(), { status: 'deferred' })
  } finally {
    firstResponse.resolve(success())
    await first
  }
  assert.equal(sent, 1, '未连接的新调度没有发 HTTP')
  assert.deepEqual(publisher.state(), { status: 'deferred' }, '旧请求的成功不是新快照的成功')
})
