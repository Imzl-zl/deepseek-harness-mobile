/**
 * 中转 ⇄ 连接器 的传输缝（契约 §2.2 升级鉴权）。
 *
 * 这一段跨越两个工程（`relay/` 起真服务器，`connector/` 用**真连接层**拨号），
 * 所以它只能在这里测 —— 而它恰好是最近几轮改动最集中、又最没有测试覆盖的地方：
 *
 * - 令牌走**升级头**（不是 URL、不是查询串），这是第 38 轮实测 undici 扩展才敢用的写法；
 * - 中转的**路径分流**（`/ws/connector`）与 `authenticate` 端口的连接；
 * - 连上之后连接层应当**进入握手态**（说明升级真的成功了，而不是"连上又立刻被拒"）。
 *
 * 它不验证握手本身（那需要另一侧有人说话）—— 那属于下一步的三方 e2e。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createConnection } from '../src/transport/connection.js'
import { startRelay } from '../../relay/src/server.ts'
import type { Authenticated } from '../../relay/src/http-face.ts'

const TOKENS: Record<string, Authenticated> = {
  'connector-token-1': { kind: 'connector', id: 'conn-1' },
}

const waitFor = async (what: string, check: () => boolean, timeoutMs = 3_000): Promise<void> => {
  const started = Date.now()
  while (!check()) {
    if (Date.now() - started > timeoutMs) throw new Error(`等待超时：${what}`)
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
}

test('连接器带令牌拨号到中转：升级成功、中转认得它、连接层进入握手态', async (t) => {
  const relay = await startRelay({ port: 0, authenticate: (token) => TOKENS[token] })
  t.after(() => relay.close())

  const states: string[] = []
  const connection = createConnection({
    url: `ws://127.0.0.1:${relay.port}/ws/connector`,
    // 与产品同一个写法：令牌走升级头（`index.ts` 里有同样的注释与 `as never`）。
    dial: (url) =>
      new WebSocket(url, {
        headers: { authorization: 'Bearer connector-token-1' },
      } as never) as never,
    onFrame: () => {},
    onStateChange: (state) => states.push(state),
  })
  t.after(() => connection.stop())
  connection.start()

  await waitFor('连接层进入握手态', () => connection.state === 'handshake')
  assert.equal(relay.core.stats.connectors, 1, '中转认得这条连接器连接')
  assert.equal(states.includes('connecting'), true, '状态机确实走过 connecting')

  // 断开要双向收口：连接层停掉之后，中转那边也要把连接器从在线集合里去掉。
  connection.stop()
  await waitFor('中转清掉这条连接器', () => relay.core.stats.connectors === 0)
})

test('令牌不对：升级被拒，连接层不会停在"看起来连上了"的状态', async (t) => {
  const relay = await startRelay({ port: 0, authenticate: (token) => TOKENS[token] })
  t.after(() => relay.close())

  const connection = createConnection({
    url: `ws://127.0.0.1:${relay.port}/ws/connector`,
    dial: (url) =>
      new WebSocket(url, { headers: { authorization: 'Bearer wrong' } } as never) as never,
    onFrame: () => {},
  })
  t.after(() => connection.stop())
  connection.start()

  // 401 之后连接层会走它自己的重连退避（backoff），而不是停在一个假的"已连接"状态。
  await waitFor('进入退避重连', () => connection.state === 'backoff')
  assert.equal(relay.core.stats.connectors, 0, '中转一条都没接受')
})
