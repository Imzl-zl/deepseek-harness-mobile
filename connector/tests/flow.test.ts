/**
 * 连接层两处纯逻辑的回归：流控窗口（契约 §4.3）与封闭错误码表（契约 §3.1）。
 *
 * 这两块没有 `protocol/` 的参考校验器可对照（向量只覆盖密码学），所以断言直接对着
 * 契约条文写：额度规则、窗口算术、以及「错误表是满射且封闭」。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  ERROR_CODES,
  ERROR_TABLE,
  ProtocolError,
  clientActionOf,
  isErrorCode,
} from '../src/protocol/errors.js'
import {
  SEND_WINDOW_FRAMES,
  consumesCredit,
  createSendWindow,
  decodeCredit,
  elicitsCredit,
  encodeCredit,
  pausable,
} from '../src/protocol/flow.js'

test('流控窗口：额度规则、优先级与 unacked 算术', () => {
  // 保活帧不占额度 —— 否则满窗时双方互等超时，走进假的半开故障。
  assert.equal(consumesCredit('ping'), false)
  assert.equal(consumesCredit('pong'), false)
  for (const t of ['req', 'res', 'ev', 'live', 'credit', 'persisted'] as const) {
    assert.equal(consumesCredit(t), true, `${t} 应占额度`)
  }

  // 满窗时只压可补的两类；应答与水位不该被压住（压住会死锁：手机在等 res）。
  assert.equal(pausable('ev'), true)
  assert.equal(pausable('live'), true)
  assert.equal(pausable('res'), false)
  assert.equal(pausable('credit'), false)
  assert.equal(pausable('persisted'), false)

  // `credit` 自己不再被确认 —— 否则两端互相刷 ack 停不下来。
  assert.equal(elicitsCredit('credit'), false)
  for (const t of ['ev', 'req', 'res', 'persisted', 'ping', 'pong'] as const) {
    assert.equal(elicitsCredit(t), true, `${t} 应触发 credit`)
  }

  const window = createSendWindow(4)
  assert.equal(window.unacked, 0)
  for (let fc = 0; fc < 4; fc += 1) window.onSent(fc, 'ev')
  assert.equal(window.unacked, 4)
  assert.equal(window.canSend('ev'), false, '满窗后不该再发可补帧')
  assert.equal(window.canSend('live'), false, 'live 同样可补，同样该压')
  assert.equal(window.canSend('ping'), true, '保活帧不受窗口限制')
  // 优先级规则：满窗时 res / credit / persisted 照发。
  assert.equal(window.canSend('res'), true, '压住 res 会死锁')
  assert.equal(window.canSend('credit'), true)
  assert.equal(window.canSend('persisted'), true)

  // credit { ack } 确认的是 [0, ack]；窗口随之松开。
  window.onCredit(1)
  assert.equal(window.unacked, 2)
  assert.equal(window.canSend('ev'), true)

  // 迟到的低 credit 不得把窗口"放大"回一个已确认过的状态。
  window.onCredit(0)
  assert.equal(window.unacked, 2, 'credit 只能前进')
})

test('流控窗口：不可暂停的帧照发，但仍计入 unacked', () => {
  const window = createSendWindow(2)
  window.onSent(0, 'ev')
  window.onSent(1, 'ev')
  assert.equal(window.canSend('ev'), false)

  // 满窗时 res 照发 —— 它是被压住的对端在等的东西；但它同样占额度（契约 §4.3）。
  window.onSent(2, 'res')
  assert.equal(window.unacked, 3, 'res 也该计入已发未确认')
  assert.equal(window.canSend('ev'), false, '窗口不会因为发了 res 而松开')
})

test('credit 载荷：累计确认编解码，坏值一律 protocol/bad-frame', () => {
  assert.equal(decodeCredit(encodeCredit(0)), 0)
  assert.equal(decodeCredit(encodeCredit(12345)), 12345)

  for (const bad of ['not json', '[]', '{}', '{"ack":"7"}', '{"ack":-1}', '{"ack":1.5}']) {
    assert.throws(
      () => decodeCredit(bad),
      (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/bad-frame',
      `${bad} 应被拒`,
    )
  }
})

test('流控窗口：默认上限与契约一致', () => {
  assert.equal(SEND_WINDOW_FRAMES, 128)
  const window = createSendWindow()
  for (let fc = 0; fc < SEND_WINDOW_FRAMES; fc += 1) window.onSent(fc, 'ev')
  assert.equal(window.unacked, SEND_WINDOW_FRAMES)
  assert.equal(window.canSend('ev'), false)
})

test('错误码表：封闭、满射、未知码归一成 internal', () => {
  // 契约 §3.1 的表有 36 个码(16 个协议层 + 16 个 DSH 宿主层 + 4 个文件预览面)；
  // 数量变化必须是有意的。2026-10-30 多机第 4 步加了 `device/busy`(独占 1:1)。
  assert.equal(ERROR_CODES.length, 36)

  // 每个码都有客户端行为 —— 表是满射，手机侧的分支不会漏。
  for (const code of ERROR_CODES) {
    assert.ok(clientActionOf(code).length > 0, `${code} 缺少客户端行为`)
  }

  assert.equal(isErrorCode('session/not-found'), true)
  assert.equal(isErrorCode('session/typo'), false)
  assert.equal(isErrorCode(undefined), false)

  // 未知码**不得原样透传**：透传一个手机端不认识的码等于逼它走 default 分支。
  assert.equal(new ProtocolError('made/up').code, 'internal')
  assert.equal(new ProtocolError('protocol/replay').code, 'protocol/replay')
  assert.equal(Object.keys(ERROR_TABLE).length, ERROR_CODES.length)
})
