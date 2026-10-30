/**
 * 一行一个 JSON 事件（`relay/src/json-logger.ts`）。
 *
 * 这组用例钉的是"能被机器读"：事件名不拼句子、字段能 grep、保留字段不被覆盖、
 * 长字符串会被截断（防止有人把整帧塞进 detail 把日志打爆）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createJsonLogger, MAX_FIELD_BYTES, normalizeLogValue } from '../src/json-logger.ts'

function capture(): { lines: { level: string; value: Record<string, unknown> }[]; logger: ReturnType<typeof createJsonLogger> } {
  const lines: { level: string; value: Record<string, unknown> }[] = []
  const logger = createJsonLogger({
    debug: true,
    now: () => Date.UTC(2026, 9, 30, 12, 0, 0),
    write: (line, level) => { lines.push({ level, value: JSON.parse(line) as Record<string, unknown> }) },
  })
  return { lines, logger }
}

test('一行一个 JSON 事件：ts/level/evt 固定，detail 的字段平铺进来', () => {
  const { lines, logger } = capture()
  logger.info('channel.open', { channelId: 'ch-1', deviceId: 'dev-1', purpose: 'paired' })
  assert.equal(lines.length, 1)
  assert.deepEqual(lines[0]?.value, {
    ts: '2026-10-30T12:00:00.000Z',
    level: 'info',
    evt: 'channel.open',
    channelId: 'ch-1',
    deviceId: 'dev-1',
    purpose: 'paired',
  })
})

test('非对象 detail 落到 detail 字段（不丢信息，也不假装是字段）', () => {
  const { lines, logger } = capture()
  logger.warn('delivery.failed', new Error('socket closed'))
  assert.equal(lines[0]?.value['evt'], 'delivery.failed')
  assert.equal(lines[0]?.value['detail'], 'socket closed', '异常只留消息，不留栈（一行一条）')
})

test('保留字段不被 detail 覆盖（否则事件名会被数据改写）', () => {
  const { lines, logger } = capture()
  logger.info('quota.rejected', { evt: '伪造', level: 'debug', ts: 'x', subject: 'user:alice' })
  assert.equal(lines[0]?.value['evt'], 'quota.rejected')
  assert.equal(lines[0]?.value['level'], 'info')
  assert.notEqual(lines[0]?.value['ts'], 'x')
  assert.equal(lines[0]?.value['subject'], 'user:alice')
})

test('长字符串截断到上限（防止整帧/整份名册进日志）', () => {
  const { lines, logger } = capture()
  const huge = '帧'.repeat(2_000)
  logger.info('frame.rejected', { payload: huge })
  const value = lines[0]?.value['payload'] as string
  assert.ok(Buffer.byteLength(value, 'utf8') <= MAX_FIELD_BYTES + 8, '截断后仍在量级内')
  assert.ok(value.endsWith('…'))
  assert.equal(normalizeLogValue(huge), value, '归一化是纯函数，可单独断言')
})

test('debug 默认关（生产不刷屏），显式打开才输出', () => {
  const out: string[] = []
  const quiet = createJsonLogger({ write: (line) => { out.push(line) } })
  quiet.debug('channel.open', { channelId: 'ch-1' })
  assert.equal(out.length, 0)
  const noisy = createJsonLogger({ debug: true, write: (line) => { out.push(line) } })
  noisy.debug('channel.open', { channelId: 'ch-1' })
  assert.equal(out.length, 1)
})

test('undefined 字段被丢掉（不写 null，也不写 "undefined"）', () => {
  const { lines, logger } = capture()
  logger.info('connector.open', { connectorId: 'conn-1', owner: undefined })
  assert.deepEqual(Object.keys(lines[0]?.value ?? {}).sort(), ['connectorId', 'evt', 'level', 'ts'])
})
