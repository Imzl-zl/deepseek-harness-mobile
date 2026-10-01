/**
 * 中转 HTTP 面的回归（契约 §2 / §12.1）。
 *
 * 断言围着**状态码**：客户端要按它分行为（401 换票/重配、409 让电脑重新出码、
 * 400 是你自己发错了），所以每个码都要有一条用例钉住。
 * 另外两条是安全性质：**配对不可用时不许发票**、**两个端点不接受对方的凭据**。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createRelayCore } from '../src/core.js'
import { createHttpFace, type Authenticated } from '../src/http-face.js'
import { createTicketStore } from '../src/tickets.js'

const TOKENS: Record<string, Authenticated> = {
  'device-token-1': { kind: 'device', id: 'dev-1' },
  'device-token-2': { kind: 'device', id: 'dev-2' },
  'connector-token-1': { kind: 'connector', id: 'conn-1' },
}

function setup() {
  let round = 0
  const core = createRelayCore()
  const tickets = createTicketStore({
    randomBytes: (size) => {
      round += 1
      return Uint8Array.from({ length: size }, (_, i) => (round * 43 + i) % 256)
    },
  })
  const face = createHttpFace({
    tickets,
    core,
    authenticate: (token) => TOKENS[token],
  })
  core.attachConnector('conn-1')
  core.attachDevice('dev-1')
  core.attachDevice('dev-2')
  return { core, tickets, face }
}

const ticket = (token: string, codeHash: string) => ({
  method: 'POST',
  path: '/ws-ticket',
  token,
  body: { codeHash },
})

test('换票：令牌有效 + 配对登记在 → 201，且**票真的能用**（绑到那台设备）', () => {
  const { core, tickets, face } = setup()
  core.registerPairing('conn-1', 'hash-a')

  const response = face.handle(ticket('device-token-1', 'hash-a'))
  assert.equal(response.status, 201)
  const body = response.body as { ticket: string; expiresAt: number }
  assert.match(body.ticket, /^[A-Za-z0-9_-]{22}$/)
  assert.equal(tickets.consume(body.ticket), 'dev-1', '票绑的是换票时认证出的设备')
})

test('令牌不对 / 缺失 → 401（客户端据此换票或重配，而不是拿同一个令牌重试）', () => {
  const { face } = setup()
  assert.equal(face.handle(ticket('', 'hash-a')).status, 401)
  assert.equal(face.handle(ticket('nope', 'hash-a')).status, 401)
  assert.equal(face.handle({ method: 'POST', path: '/ws-ticket', body: { codeHash: 'h' } }).status, 401)
})

test('配对登记不可用 → 409，而且**一张票都不许发**', () => {
  const { core, tickets, face } = setup()
  // 没登记
  assert.equal(face.handle(ticket('device-token-1', 'hash-a')).status, 409)
  assert.deepEqual(tickets.stats, { tickets: 0 }, '拒绝时不许留下任何票')

  // 登记被别的设备认领过（一次性）
  core.registerPairing('conn-1', 'hash-a')
  assert.equal(face.handle(ticket('device-token-1', 'hash-a')).status, 201)
  assert.equal(face.handle(ticket('device-token-2', 'hash-a')).status, 409, '同一登记不能被认领两次')
})

test('两个端点不接受对方的凭据（403，而不是含糊的失败）', () => {
  const { face } = setup()
  assert.equal(face.handle(ticket('connector-token-1', 'hash-a')).status, 403, '连接器不走换票')
  assert.equal(
    face.handle({
      method: 'POST',
      path: '/pairing/register',
      token: 'device-token-1',
      body: { codeHash: 'hash-a' },
    }).status,
    403,
    '设备不能替连接器登记',
  )
})

test('缺 codeHash → 400（"你发错了"与 409"现在没有"是两件事）', () => {
  const { face } = setup()
  assert.equal(face.handle(ticket('device-token-1', '')).status, 400)
  assert.equal(
    face.handle({ method: 'POST', path: '/pairing/register', token: 'connector-token-1' }).status,
    400,
  )
})

test('连接器登记：201，并且登记之后那台设备真的换得到票', () => {
  const { face } = setup()
  const registered = face.handle({
    method: 'POST',
    path: '/pairing/register',
    token: 'connector-token-1',
    body: { codeHash: 'hash-b' },
  })
  assert.equal(registered.status, 201)
  assert.equal(face.handle(ticket('device-token-2', 'hash-b')).status, 201)
})

test('方法与路径：非 POST → 405，未知路径 → 404', () => {
  const { face } = setup()
  assert.equal(face.handle({ method: 'GET', path: '/ws-ticket' }).status, 405)
  assert.equal(face.handle({ method: 'POST', path: '/nope', token: 'device-token-1' }).status, 404)
})
