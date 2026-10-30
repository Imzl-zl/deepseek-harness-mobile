/**
 * 最近事件环（`relay/src/events.ts`）。
 *
 * 面板"动态"分区的数据源：**有界**、**最新在前**、与日志同源（镜像得来，不另立口径）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createEventRing, mirrorToRing } from '../src/events.ts'
import type { ChannelLogger } from '../src/logger.ts'

const noop: ChannelLogger = { info() {}, warn() {}, error() {}, debug() {} }

test('环形缓冲：容量封顶，最新在前', () => {
  const ring = createEventRing({ capacity: 3 })
  for (let index = 1; index <= 5; index += 1) {
    ring.push({ at: index, level: 'info', evt: 'e' + index, detail: {} })
  }
  assert.equal(ring.size, 3)
  assert.deepEqual(ring.list().map((event) => event.evt), ['e5', 'e4', 'e3'], '最旧的被覆盖，最新在前')
})

test('日志镜像：info/warn 进环，debug 不进；非对象 detail 收成字符串', () => {
  const ring = createEventRing({ capacity: 10 })
  const log = mirrorToRing(noop, ring, () => 1_700_000_000_000)

  log.info('connector.open', { connectorId: 'home-pc' })
  log.warn('quota.rejected', { subject: 'user:alice', used: 9, limit: 9 })
  log.error('delivery.failed', new Error('socket closed'))
  log.debug('roster.applied', { accepted: 1 })

  const events = ring.list()
  assert.deepEqual(events.map((event) => event.evt), ['delivery.failed', 'quota.rejected', 'connector.open'])
  assert.equal(events[0]?.at, 1_700_000_000_000, '时间由注入的时钟盖')
  assert.deepEqual(events[2]?.detail, { connectorId: 'home-pc' })
  assert.equal(events[0]?.level, 'error')
  assert.match(String(events[0]?.detail['detail']), /socket closed/, '异常收成字符串，不留栈')
})

test('镜像不会改原日志的调用（原 logger 照常收到）', () => {
  const seen: string[] = []
  const base: ChannelLogger = {
    info(evt) { seen.push(evt) }, warn(evt) { seen.push(evt) },
    error(evt) { seen.push(evt) }, debug(evt) { seen.push(evt) },
  }
  const ring = createEventRing()
  const log = mirrorToRing(base, ring)
  log.info('channel.open', { channelId: 'ch-1' })
  assert.deepEqual(seen, ['channel.open'])
  assert.equal(ring.size, 1)
})
