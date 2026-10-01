/**
 * 可观测性的回归（契约 §1.2）。
 *
 * 这里钉的是两件容易在重构里悄悄退化的事：printf 适配是否真的把 detail 带出去
 * （丢了的话日志看起来正常、只是永远没有上下文），以及指标名是否真的唯一
 * （重复的话两个含义会共用一格计数器，读出来的数没人敢用）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  METRIC,
  createChannelLogger,
  createMetrics,
  silentLogger,
  type PrintfLogger,
} from '../src/observability.js'

interface Call {
  method: string
  args: unknown[]
}

function recorder(): { logger: PrintfLogger; calls: Call[] } {
  const calls: Call[] = []
  const make =
    (method: string) =>
    (...args: unknown[]): void => {
      calls.push({ method, args })
    }
  return {
    calls,
    logger: { error: make('error'), info: make('info'), warn: make('warn'), debug: make('debug') },
  }
}

test('printf 适配：无 detail 时不追加参数，有 detail 时用 %O 带出去', () => {
  const { logger, calls } = recorder()
  const channel = createChannelLogger(logger)

  channel.info('已挂载')
  // 不带 detail 时**不能**追加参数 —— 否则日志里会多出一个 undefined。
  assert.deepEqual(calls[0], { method: 'info', args: ['%s', '已挂载'] })

  const detail = { sid: 's1', code: 'protocol/replay' }
  channel.warn('收帧被拒', detail)
  assert.deepEqual(calls[1], { method: 'warn', args: ['%s %O', '收帧被拒', detail] })
  // detail 必须真的传下去：丢了的话日志看着正常，只是永远没有上下文。
  assert.equal(calls[1]?.args[2], detail)

  channel.error('挂载失败', new Error('relayUrl 未配置'))
  assert.equal(calls[2]?.method, 'error')
  assert.equal(calls[2]?.args.length, 3)

  channel.debug('连接状态 idle → connecting')
  assert.equal(calls[3]?.method, 'debug')
})

test('silentLogger 什么都不做', () => {
  assert.doesNotThrow(() => {
    silentLogger.info('a')
    silentLogger.warn('b', { x: 1 })
    silentLogger.error('c')
    silentLogger.debug('d')
  })
})

test('指标：计数累加、仪表覆盖、快照是普通对象', () => {
  const metrics = createMetrics()
  metrics.increment(METRIC.connects)
  metrics.increment(METRIC.connects)
  metrics.increment(METRIC.rejectedFrames, 5)
  metrics.gauge(METRIC.pairedDevices, 3)
  metrics.gauge(METRIC.pairedDevices, 1)

  const snapshot = metrics.snapshot()
  assert.equal(snapshot[METRIC.connects], 2)
  assert.equal(snapshot[METRIC.rejectedFrames], 5)
  assert.equal(snapshot[METRIC.pairedDevices], 1, '仪表是覆盖不是累加')

  // 快照是普通对象：健康上报要能直接 JSON 序列化。
  assert.equal(Object.getPrototypeOf(snapshot), Object.prototype)
  assert.doesNotThrow(() => JSON.stringify(snapshot))
})

test('指标名必须唯一：同一格计数器不能被两个含义共用', () => {
  const names = Object.values(METRIC)
  assert.equal(new Set(names).size, names.length, `指标名有重复：${names.join(', ')}`)
  // 命名空间前缀统一，便于健康上报按前缀过滤。
  for (const name of names) assert.match(name, /^connector\./, `${name} 缺少 connector. 前缀`)
})
