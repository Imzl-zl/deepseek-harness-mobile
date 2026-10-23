/**
 * HTTP 面限流的回归（契约 §12 的"按设备限流"；`docs/subsystems/pairing-v2.md` §3）。
 *
 * 六条：被拒回 **429 + retryAfterMs**、**被拒时不发任何票**、认证过的按**身份**取桶，
 * 以及首配那一跳的两个桶 —— **按来源地址的匿名桶** + 每张公开邀请一个桶。
 *
 * ## 首配为什么这样分桶
 *
 * 限流优先按**身份**取桶（§10 的下一条理由：按 IP 会在反代后面把所有人归成一个，
 * 一个人就能把大家限住）。首配时手机还没有身份 —— v2 有**公开邀请**，形状合法的候选
 * 过 `pairing:offer:<offerId>`；而**解析之前**那一跳没有任何可用身份，
 * 于是按**来源地址**取桶（`pairing:anonymous:<addr>`）：所有人共用一个桶的后果是
 * "一个人刷坏请求就把所有人的首配限成 429"。次序是刻意的：坏请求连"这是不是一个 v2 候选"
 * 都过不了，就不该占用**别人的** per-offer 桶。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { createRelayCore } from '../src/core.ts'
import { createDeviceRegistry } from '../src/device-registry.ts'
import { createHttpFace, type Authenticated } from '../src/http-face.ts'
import { createTicketStore } from '../src/tickets.ts'

const TOKEN = 'device-token-1'
const TOKENS: Record<string, Authenticated> = { 'connector-token-1': { kind: 'connector', id: 'conn-1' } }

const OFFER_A = 'A'.repeat(22)
const OFFER_B = 'B'.repeat(22)
const candidateOf = (offerId: string) => ({
  offerId, devPubEd: 'c'.repeat(64), devPubDh: 'd'.repeat(64), name: '我的手机',
})

function setup(rateLimit?: (key: string) => { allowed: boolean; retryAfterMs: number | null }) {
  const core = createRelayCore()
  const devices = createDeviceRegistry()
  devices.register('conn-1', [
    {
      id: 'dev-1',
      pairingId: 'pair-1',
      devPubEd: 'a'.repeat(64),
      devPubDh: 'b'.repeat(64),
      name: '我的手机',
      tokenHash: createHash('sha256').update(TOKEN, 'utf8').digest('hex'),
    },
  ])
  const tickets = createTicketStore({ randomBytes: (size) => Uint8Array.from({ length: size }, () => 5) })
  core.attachConnector('conn-1')
  core.registerPairing('conn-1', OFFER_A)
  const keys: string[] = []
  const face = createHttpFace({
    core,
    tickets,
    devices,
    authenticate: (token) => TOKENS[token],
    ...(rateLimit === undefined
      ? {}
      : {
          rateLimit: (key: string) => {
            keys.push(key)
            return rateLimit(key)
          },
        }),
  })
  return { core, face, tickets, keys }
}

/** 重连形态：凭设备令牌换票（这条走限流面）。 */
const request = () => ({
  method: 'POST',
  path: '/ws-ticket',
  token: TOKEN,
  body: {},
})

/** 首配形态：凭公开邀请换票（**没有令牌** —— 桶键是邀请，不是 IP）。 */
const bootstrap = (offerId = OFFER_A) => ({
  method: 'POST',
  path: '/ws-ticket',
  body: { v: 2, ...candidateOf(offerId) },
})

test('被限流：429 + retryAfterMs，而且**一张票都不发**', () => {
  const { face, tickets } = setup(() => ({ allowed: false, retryAfterMs: 1_500 }))
  const response = face.handle(request())

  assert.equal(response.status, 429)
  assert.deepEqual(response.body, { error: 'rate-limited', retryAfterMs: 1_500 })
  assert.deepEqual(tickets.stats, { tickets: 0 }, '被拒之后仍然发票 = 凭空发出一份凭据')

  // 首配那一跳同样在限流面上（v2 有公开邀请可以当桶键，不必退回按 IP）。
  assert.equal(face.handle(bootstrap()).status, 429)
  assert.deepEqual(tickets.stats, { tickets: 0 })
})

test('桶键是**身份**（不是 IP）：设备与连接器各是一个命名空间', () => {
  const { face, keys } = setup(() => ({ allowed: true, retryAfterMs: 0 }))
  assert.equal(face.handle(request()).status, 201)
  assert.equal(
    face.handle({
      method: 'POST',
      path: '/pairing/register',
      token: 'connector-token-1',
      body: { v: 2, offerId: OFFER_B },
    }).status,
    201,
  )
  assert.deepEqual(
    keys,
    ['device:dev-1', 'connector:conn-1'],
    '认证过的按身份限流；按 IP 会在代理后面把所有人归成一个，而设备与连接器的同名 id 也不共桶',
  )
})

test('首配的桶键：**来源地址**的匿名桶 + 每张邀请一个桶', () => {
  const { face, keys } = setup(() => ({ allowed: true, retryAfterMs: 0 }))
  assert.equal(face.handle({ ...bootstrap(), remoteAddress: '::ffff:10.0.0.7' }).status, 201)
  assert.deepEqual(keys, ['pairing:anonymous:::ffff:10.0.0.7', `pairing:offer:${OFFER_A}`])

  // 形状不合法的候选：匿名桶都没过 —— 坏请求不该占用**别人的** per-offer 桶。
  keys.length = 0
  assert.equal(
    face.handle({
      method: 'POST', path: '/ws-ticket', remoteAddress: '::ffff:10.0.0.7',
      body: { v: 2, offerId: OFFER_A },
    }).status,
    400,
  )
  assert.deepEqual(keys, ['pairing:anonymous:::ffff:10.0.0.7'], '形状不合法就到不了 per-offer 桶')

  // 取不到来源地址（例如测试里的裸请求）：退到 `unknown`，等价于改动前的全局桶。
  keys.length = 0
  assert.equal(face.handle(bootstrap()).status, 201)
  assert.deepEqual(keys, ['pairing:anonymous:unknown', `pairing:offer:${OFFER_A}`])
})

test('两个来源地址互不牵连：一个人刷坏请求限不住别人的首配', () => {
  // 改动前的形态是单一全局桶（`pairing:anonymous`）：约 6 req/s 就让**所有**新设备 429。
  const { face } = setup(
    (key) => (key === 'pairing:anonymous:::ffff:10.0.0.7'
      ? { allowed: false, retryAfterMs: 9_000 }
      : { allowed: true, retryAfterMs: 0 }),
  )

  const denied = face.handle({ ...bootstrap(), remoteAddress: '::ffff:10.0.0.7' })
  assert.equal(denied.status, 429)
  assert.deepEqual(denied.body, { error: 'rate-limited', retryAfterMs: 9_000 })

  assert.equal(
    face.handle({ ...bootstrap(), remoteAddress: '::ffff:10.0.0.8' }).status,
    201,
    '另一个来源的首配不受影响',
  )
})

test('一张邀请被刷不牵连另一张：per-offer 桶各自独立', () => {
  const { core, face, tickets } = setup(
    (key) => (key === `pairing:offer:${OFFER_A}` ? { allowed: false, retryAfterMs: 2_000 } : { allowed: true, retryAfterMs: 0 }),
  )
  core.attachConnector('conn-2')
  core.registerPairing('conn-2', OFFER_B)

  const denied = face.handle(bootstrap(OFFER_A))
  assert.equal(denied.status, 429)
  assert.deepEqual(denied.body, { error: 'rate-limited', retryAfterMs: 2_000 })
  assert.deepEqual(tickets.stats, { tickets: 0 }, '被拒的那次不许留下票')

  assert.equal(face.handle(bootstrap(OFFER_B)).status, 201, '另一张邀请的桶没被牵连')
  assert.deepEqual(tickets.stats, { tickets: 1 })
})

test('放行时行为与没装限流时一致（201 + 票可用）', () => {
  const { face, tickets } = setup(() => ({ allowed: true, retryAfterMs: 0 }))
  const response = face.handle(request())
  assert.equal(response.status, 201)
  const body = response.body as { ticket: string }
  assert.deepEqual(
    tickets.consume(body.ticket),
    { connectorId: 'conn-1', deviceId: 'dev-1', purpose: 'paired' },
  )
})

test('限流在**认证之后**：凭据不对时回 401，而不是先被限流掩盖', () => {
  const { face, keys } = setup(() => ({ allowed: false, retryAfterMs: 1 }))
  assert.equal(face.handle({ ...request(), token: 'nope' }).status, 401)
  assert.deepEqual(keys, [], '未认证的请求没有身份，桶键无处安放（那属于边缘治理）')
})
