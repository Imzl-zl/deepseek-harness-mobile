/**
 * 中转路由核心的回归（契约 §2 / §5.5 / **I10**）。
 *
 * 断言围着三件事：**只按路由元数据转发**（载荷根本不进这一层）、
 * **sid 归属只能从电脑侧学**（设备侧说了不算）、以及**裁剪要等这台设备自己的确认**。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createRouting, type RoutedFrame } from '../src/routing.ts'
import { routingViewOf } from '../src/protocol-view.ts'

const frame = (raw: string): RoutedFrame => {
  const view = routingViewOf(raw)
  if (view === undefined) throw new Error(`不是合法帧：${raw}`)
  return { view, raw }
}

const ev = (sid: string, seq: number, payload = 'x'): RoutedFrame =>
  frame(JSON.stringify({ v: 1, t: 'ev', sid, seq, fc: seq, box: payload }))

test('路由视图只取 t / sid / seq —— 载荷与方法名进不了这一层（I10）', () => {
  const raw = JSON.stringify({
    v: 1,
    t: 'req',
    id: 'r1',
    sid: 'sid_1',
    seq: 7,
    fc: 3,
    box: JSON.stringify({ method: 'session.prompt', params: { text: '机密' } }),
  })

  const view = routingViewOf(raw)
  // `id` 在可见字段里（契约 §1 的 I10 扩容）：配对帧没有 `sid`，回执只能靠它找回来。
  assert.deepEqual(view, { t: 'req', sid: 'sid_1', seq: 7, id: 'r1' })
  assert.equal(JSON.stringify(view).includes('session.prompt'), false, '方法名不许进路由视图')
  assert.equal(JSON.stringify(view).includes('机密'), false, '载荷不许进路由视图')
})

test('sid 归属只从**电脑侧**发来的帧里学；设备侧指向未学过的 sid 就丢弃', () => {
  const routing = createRouting()
  assert.equal(
    routing.fromDevice('dev-1', ev('sid_1', 1)),
    undefined,
    '还没学过这个 sid —— 丢弃，不自己造错误帧',
  )

  routing.fromConnector('conn-1', ev('sid_1', 1))
  assert.equal(routing.fromDevice('dev-1', ev('sid_1', 2)), 'conn-1', '学到的归属用于回程')
})

test('窗口按设备分：谁在听就记谁的，没有听众就不记（不白占内存）', () => {
  const routing = createRouting()
  routing.fromConnector('conn-1', ev('sid_1', 1))
  assert.deepEqual(routing.stats, { sessions: 1, windows: 0, frames: 0 }, '没有听众：只记归属')

  routing.fromDevice('dev-1', ev('sid_1', 1))
  routing.fromConnector('conn-1', ev('sid_1', 2))
  routing.fromConnector('conn-1', ev('sid_1', 3))
  assert.equal(routing.stats.windows, 1)
  assert.deepEqual(routing.replayFor('dev-1', 'sid_1', 1), [
    JSON.stringify({ v: 1, t: 'ev', sid: 'sid_1', seq: 2, fc: 2, box: 'x' }),
    JSON.stringify({ v: 1, t: 'ev', sid: 'sid_1', seq: 3, fc: 3, box: 'x' }),
  ])
})

test('裁剪要等**这台设备自己的** persisted：别的设备确认了不算', () => {
  const routing = createRouting()
  routing.fromDevice('dev-1', ev('sid_1', 0))
  routing.fromDevice('dev-2', ev('sid_1', 0))
  for (const seq of [1, 2, 3]) {
    routing.fromConnector('conn-1', ev('sid_1', seq))
  }

  assert.equal(routing.ack('dev-1', 'sid_1', 2), 2, 'dev-1 确认到 2：裁它自己的两条')
  assert.equal(
    routing.replayFor('dev-2', 'sid_1', 0)?.length,
    3,
    'dev-2 一条都没确认 —— 它的窗口不许被别人的确认裁掉',
  )
})

test('覆盖率判据：中间有洞或已被裁过头，都要求快照而不是给残缺增量', () => {
  const routing = createRouting()
  routing.fromDevice('dev-1', ev('sid_1', 0))
  routing.fromConnector('conn-1', ev('sid_1', 1))
  routing.fromConnector('conn-1', ev('sid_1', 3)) // 2 缺了（比如电脑侧没发）

  assert.equal(routing.replayFor('dev-1', 'sid_1', 0), undefined, '有洞 → 要求快照')
  // `since = 2` 时设备手里已经有 2（它自己报的水位）：我们只要给 3 就够 ——
  // 洞落在"它已经有的区间"里，与它无关。
  assert.deepEqual(routing.replayFor('dev-1', 'sid_1', 2), [
    JSON.stringify({ v: 1, t: 'ev', sid: 'sid_1', seq: 3, fc: 3, box: 'x' }),
  ])

  routing.ack('dev-1', 'sid_1', 3)
  assert.deepEqual(routing.replayFor('dev-1', 'sid_1', 3), [], '正好接着 → 空增量（不是 undefined）')
})

test('窗口超限：丢最旧的（封顶），而不是无限增长', () => {
  const routing = createRouting({ windowFrames: 2 })
  routing.fromDevice('dev-1', ev('sid_1', 0))
  for (const seq of [1, 2, 3]) routing.fromConnector('conn-1', ev('sid_1', seq))

  assert.equal(routing.stats.frames, 2, '窗口封顶在 2 条')
  assert.equal(routing.replayFor('dev-1', 'sid_1', 0), undefined, '丢过最旧的 → 从 0 恢复已不可行')
  assert.deepEqual(routing.replayFor('dev-1', 'sid_1', 1)?.length, 2, '从 1 恢复仍然可行')
})

test('设备断开：窗口与订阅关系一并失效（重连是一次新的订阅）', () => {
  const routing = createRouting()
  routing.fromDevice('dev-1', ev('sid_1', 0))
  routing.fromConnector('conn-1', ev('sid_1', 1))
  assert.equal(routing.stats.windows, 1)

  routing.forgetDevice('dev-1')
  assert.deepEqual(routing.stats, { sessions: 1, windows: 0, frames: 0 })
  assert.equal(routing.replayFor('dev-1', 'sid_1', 0), undefined)
})
