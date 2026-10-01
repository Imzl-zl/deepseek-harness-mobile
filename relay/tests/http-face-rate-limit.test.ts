/**
 * HTTP 面限流的回归（契约 §12 的"按设备限流"）。
 *
 * 三条：被拒回 **429 + retryAfterMs**、**被拒时不发任何票**、桶键是**身份**（不是 IP）。
 * 第二条是安全性的：429 之后仍然发出去的票本身就是凭据，而它会被记进客户端日志。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createRelayCore } from '../src/core.ts'
import { createHttpFace, type Authenticated } from '../src/http-face.ts'
import { createTicketStore } from '../src/tickets.ts'

const TOKEN = 'device-token-1'
const TOKENS: Record<string, Authenticated> = { [TOKEN]: { kind: 'device', id: 'dev-1' } }

function setup(rateLimit?: (key: string) => { allowed: boolean; retryAfterMs: number }) {
  const core = createRelayCore()
  const tickets = createTicketStore({ randomBytes: (size) => Uint8Array.from({ length: size }, () => 5) })
  core.attachConnector('conn-1')
  core.attachDevice('dev-1')
  core.registerPairing('conn-1', 'hash-a')
  const keys: string[] = []
  const face = createHttpFace({
    core,
    tickets,
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
  return { face, tickets, keys }
}

const request = () => ({
  method: 'POST',
  path: '/ws-ticket',
  token: TOKEN,
  body: { codeHash: 'hash-a' },
})

test('被限流：429 + retryAfterMs，而且**一张票都不发**', () => {
  const { face, tickets } = setup(() => ({ allowed: false, retryAfterMs: 1_500 }))
  const response = face.handle(request())

  assert.equal(response.status, 429)
  assert.deepEqual(response.body, { error: 'rate-limited', retryAfterMs: 1_500 })
  assert.deepEqual(tickets.stats, { tickets: 0 }, '被拒之后仍然发票 = 凭空发出一份凭据')
})

test('桶键是**身份**（不是 IP）', () => {
  const { face, keys } = setup(() => ({ allowed: true, retryAfterMs: 0 }))
  assert.equal(face.handle(request()).status, 201)
  assert.deepEqual(keys, ['dev-1'], '按身份限流；按 IP 会在代理后面把所有人归成一个')
})

test('放行时行为与没装限流时一致（201 + 票可用）', () => {
  const { face, tickets } = setup(() => ({ allowed: true, retryAfterMs: 0 }))
  const response = face.handle(request())
  assert.equal(response.status, 201)
  const body = response.body as { ticket: string }
  assert.equal(tickets.consume(body.ticket), 'dev-1')
})

test('限流在**认证之后**：令牌不对时回 401，而不是先被限流掩盖', () => {
  const { face, keys } = setup(() => ({ allowed: false, retryAfterMs: 1 }))
  assert.equal(face.handle({ ...request(), token: 'nope' }).status, 401)
  assert.deepEqual(keys, [], '未认证的请求没有身份，桶键无处安放（那属于边缘治理）')
})
