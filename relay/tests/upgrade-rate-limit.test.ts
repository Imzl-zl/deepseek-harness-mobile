/**
 * WS 升级也要限流（契约 §12 的"按设备限流"）。
 *
 * 为什么单独一条：升级比换票**贵得多**（一条长连、一份内存状态、一次密码学握手），
 * 而它此前完全没走限流 —— 换票被限住了，转手猛刷升级即可绕过。
 *
 * **观察点必须隔离**：设备侧换票与升级吃**同一个身份**的桶，所以"三次里出现 429"可能只是
 * 换票被限住了（我第一版就栽在这里：用例变绿，但绿的是一条与升级无关的路径）。
 * 连接器走**令牌**、不需要票，于是"三次连接器升级里出现的 429"只可能来自升级路径本身。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { WebSocket } from 'ws'

import { startRelay } from '../src/server.ts'
import type { Authenticated } from '../src/http-face.ts'

const TOKENS: Record<string, Authenticated> = {
  'connector-token-1': { kind: 'connector', id: 'conn-1' },
}

/** 升级一次连接器连接；返回 HTTP 状态码（101 → 用 0 表示成功）。 */
const attemptConnectorUpgrade = (wsBase: string) =>
  new Promise<number>((resolve, reject) => {
    const ws = new WebSocket(`${wsBase}/ws/connector?id=conn-1`, {
      headers: { authorization: 'Bearer connector-token-1' },
    })
    ws.on('open', () => {
      ws.close()
      resolve(0)
    })
    ws.on('unexpected-response', (_request, response) => {
      ws.terminate()
      resolve(response.statusCode ?? -1)
    })
    ws.on('error', (error) => {
      if (ws.readyState !== WebSocket.CLOSED) reject(error)
    })
  })

test('升级也限流：容量用尽后升级本身被拒（429），而不是"换票限住了、升级绕过"', async (t) => {
  const relay = await startRelay({
    port: 0,
    authenticate: (token) => TOKENS[token],
    // 容量 2、零补充：第三次升级必须被挡（连接器不吃票，所以消耗只可能来自升级）。
    rateLimit: { capacity: 2, refillPerSecond: 0 },
  })
  t.after(() => relay.close())
  const wsBase = `ws://127.0.0.1:${relay.port}`

  const statuses: number[] = []
  for (let i = 0; i < 3; i += 1) statuses.push(await attemptConnectorUpgrade(wsBase))

  assert.deepEqual(
    statuses,
    [0, 0, 429],
    `前两次成功、第三次必须 429（实际 ${JSON.stringify(statuses)}）—— ` +
      '否则升级是一条绕过限流的路：换票被限住，转手猛刷升级即可',
  )
})
