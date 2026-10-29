/**
 * 「配置热改 → 重建哪条通道」与重建队列的回归。
 *
 * ## 这条网补的是什么
 *
 * 2026-10-29 那轮的「连接」卡让面板能热改 `relayUrl` / `listenPort`，生效路径是
 * loader 的 `loader/volatile-update` → 我们按**键集合**决定重建哪条通道。
 * 三件事当时**全靠隔离实例手工 e2e**（起实例 → 面板改地址 → 看日志里有没有重建）：
 *
 * 1. 哪些键归哪条通道（`relayUrl` 改了不该重启直连监听面，反之亦然）；
 * 2. 手改 yml 连点两次时**两次重建必须串行**（并发 stop/start 会互踩：
 *    第二次 stop 可能落在第一次 start 的半途）；
 * 3. 重建失败要**落成界面上的原因**（`「连接」卡` 的 `relayError`），而不是只进日志。
 *
 * 所以这三条抽成纯函数/纯状态机放这里钉住，装配层（`index.ts`）只做接线。
 * 线上那条路是否真的用上了本模块，由 `tests/assembly-wiring.test.ts` 盯
 * （否则抽出来的东西可以永远是死代码）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  REBUILD_CHANNELS,
  REBUILD_KEYS,
  channelsToRebuild,
  createRebuildQueue,
  type RebuildChannel,
} from '../src/transport/rebuild.js'

/** 把 `loader/volatile-update` 的载荷写成它给的样子：每格是路径**段**数组。 */
const paths = (...keys: string[]): string[][] => keys.map((key) => key.split('.'))

test('channelsToRebuild：键集合与通道的对应关系（这张表就是全部判据）', () => {
  // 表本身钉一次：改动它等于改"哪些改动会让通道重启"，那是有代价的行为（掉线）。
  assert.deepEqual(REBUILD_CHANNELS, ['relay', 'direct'])
  assert.deepEqual([...REBUILD_KEYS.relay], ['relayUrl', 'allowInsecureLocal', 'allowInsecurePublic', 'relayTokenRef'])
  assert.deepEqual([...REBUILD_KEYS.direct], ['listenPort', 'listenHost'])
})

test('channelsToRebuild：中转那四格只重建中转', () => {
  for (const key of REBUILD_KEYS.relay) {
    assert.deepEqual(channelsToRebuild(paths(key)), ['relay'], `${key} 应只重建中转`)
  }
})

test('channelsToRebuild：直连那两格只重建直连（不能让中转跟着掉线）', () => {
  for (const key of REBUILD_KEYS.direct) {
    assert.deepEqual(channelsToRebuild(paths(key)), ['direct'], `${key} 应只重建直连`)
  }
})

test('channelsToRebuild：没列进来的 volatile 字段不重建任何通道', () => {
  // 这些改完"下次读写时自然生效"，没有"已建立的连接还握着旧值"这回事 ——
  // 顺手重启通道只会白掉一次线（`REBUILD_KEYS` 的注释写了这条判断）。
  for (const key of ['deviceLimit', 'frameLimitBytes', 'windowFrames', 'sweepIntervalMs']) {
    assert.deepEqual(channelsToRebuild(paths(key)), [], `${key} 不该触发重建`)
  }
})

test('channelsToRebuild：一次改两条通道的键，两条都排，顺序稳定（relay 在前）', () => {
  assert.deepEqual(channelsToRebuild(paths('listenPort', 'relayUrl')), ['relay', 'direct'])
  // 同一条通道多个键命中只排一次。
  assert.deepEqual(channelsToRebuild(paths('relayUrl', 'relayTokenRef')), ['relay'])
})

test('channelsToRebuild：空事件（或全是无关键）回空数组', () => {
  assert.deepEqual(channelsToRebuild([]), [])
  assert.deepEqual(channelsToRebuild(paths('someOtherField')), [])
})

test('channelsToRebuild：路径按「段拼点」比较，不是前缀匹配', () => {
  // `loader/volatile-update` 给的是段数组；`relayUrlFoo` 与 `relayUrl` 不是同一格。
  assert.deepEqual(channelsToRebuild([['relayUrlFoo']]), [])
  assert.deepEqual(channelsToRebuild([['relayUrl']]), ['relay'])
})

test('重建队列：两次排队串行执行，绝不同时在跑（手改 yml 连点两次的形状）', async () => {
  const events: string[] = []
  let inside = 0
  let maxInside = 0
  const queue = createRebuildQueue(async (channel) => {
    inside += 1
    maxInside = Math.max(maxInside, inside)
    events.push(`start:${channel}`)
    // 让出两个微任务：若两次重建并发，第二次一定挤进这段里。
    await Promise.resolve()
    await Promise.resolve()
    events.push(`stop:${channel}`)
    inside -= 1
  })

  const first = queue.enqueue('relay')
  const second = queue.enqueue('direct')
  await Promise.all([first, second])

  assert.equal(maxInside, 1, '同时最多只有一次重建在跑')
  assert.deepEqual(events, ['start:relay', 'stop:relay', 'start:direct', 'stop:direct'])
})

test('重建队列：失败被记成一句原因，settle 等得到它（「连接」卡据此报 relayError）', async () => {
  const failures: Array<[RebuildChannel, unknown]> = []
  const queue = createRebuildQueue(
    async (channel) => {
      if (channel === 'relay') throw new Error('listen EADDRINUSE: 8790')
    },
    (channel, error) => { failures.push([channel, error]) },
  )

  // **排队的 promise 自己不 reject**：失败是界面上的一个原因，不是装配层的异常
  // （否则 `void enqueueRebuild(...)` 会变成 unhandled rejection）。
  await queue.enqueue('relay')
  await queue.settle()

  assert.equal(queue.failure(), 'listen EADDRINUSE: 8790')
  assert.deepEqual(failures.map(([channel]) => channel), ['relay'])
})

test('重建队列：下一次重建一开始就清掉上一次的原因，成功之后原因不残留', async () => {
  let failNext = true
  const queue = createRebuildQueue(async () => {
    if (failNext) throw new Error('端口被占')
  })

  await queue.enqueue('direct')
  assert.equal(queue.failure(), '端口被占')

  failNext = false
  await queue.enqueue('direct')
  assert.equal(queue.failure(), undefined, '后来成功了就不该还挂着上一次的原因')
})

test('重建队列：settle 在排队期间被调用也能等到最后落地的那个（保存回执读的是重建后的真值）', async () => {
  const done: string[] = []
  const queue = createRebuildQueue(async (channel) => {
    await Promise.resolve()
    done.push(channel)
  })

  void queue.enqueue('relay')
  void queue.enqueue('relay')
  // 不 await enqueue 的返回值，只等 settle —— 与 `connection-card.ts` 的 `settle()` 同形。
  await queue.settle()
  assert.deepEqual(done, ['relay', 'relay'])
})

test('重建队列：非 Error 的抛出也归一成一句可显示的原因', async () => {
  const queue = createRebuildQueue(async () => { throw 'not-an-error' })
  await queue.enqueue('relay')
  assert.equal(queue.failure(), 'not-an-error')
})
