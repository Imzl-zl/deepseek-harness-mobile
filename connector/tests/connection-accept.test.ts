/**
 * 接受路径的回归（监听面 accept 之后把 socket 交给连接）。
 *
 * 本轮验证**三处与拨号不同的生命周期**（它们都不会报错，只会表现成怪现象）：
 *
 * 1. 接受来的 socket **已经 OPEN** —— `onopen` 不会再触发，所以要直接走一次"打开"处理。
 *    少了它，连接永远停在 `connecting`，症状是"连上了但什么都不发生"。
 * 2. 接受来的连接**不自愈** —— 它没有拨号目标。若按拨号那套在断开后 `dial(url)`，
 *    症状是"监听模式下桥接莫名其妙连去中转"。
 * 3. **定时器要跟着起** —— `start()` 起的两个周期任务（攒批 flush、保活判定）原本只在
 *    `start()` 里起，而接受路径不走 `start()`。少了它们，可攒批的帧（`ev` / `live` / `job`）
 *    **永远留在 batcher 里**（`send()` 照样回 `true`），且半开永远判不出来 ——
 *    症状是"连上了、握手也过了，但事件一条都收不到"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { AddressInfo } from 'node:net'

import { WebSocket, WebSocketServer } from 'ws'

import { createConnection } from '../src/transport/connection.js'
import { waitFor } from './support/peer.js'

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms))

/** 起一个服务端 + 一条接受来的连接，返回客户端与它收到的行。 */
async function acceptOne(
  t: { after(fn: () => void | Promise<void>): void },
  options: { batchMs?: number; heartbeatMs?: number } = {},
) {
  const server = new WebSocketServer({ port: 0 })
  t.after(() => server.close())
  await new Promise<void>((resolve) => server.once('listening', () => resolve()))
  const port = (server.address() as AddressInfo).port

  let dials = 0
  const connection = createConnection({
    // 这个地址**绝不该被用到**：接受路径没有拨号目标。
    url: 'ws://127.0.0.1:1/never-dial',
    dial: () => {
      dials += 1
      throw new Error('接受路径不该拨号')
    },
    onFrame: () => {},
    // 明文通道模式：本轮只验证生命周期，不牵扯握手密码学。
    ...options,
  })

  const accepted = new Promise<WebSocket>((resolve) => {
    server.once('connection', (socket) => resolve(socket as unknown as WebSocket))
  })
  const client = new WebSocket(`ws://127.0.0.1:${port}`)
  const lines: string[] = []
  client.on('message', (data) => lines.push(data.toString()))
  const socket = await accepted

  connection.attach(socket as unknown as Parameters<typeof connection.attach>[0])
  // 等**客户端这一侧**也建立完成：否则 `close()` 会在连接建立前调用（ws 会直接抛）。
  await new Promise<void>((resolve) => client.once('open', () => resolve()))

  t.after(() => connection.stop())
  return { connection, client, lines, dials: () => dials }
}

test('接受路径：已打开的 socket 直接进握手；断开后**不**去拨号', async (t) => {
  const f = await acceptOne(t)
  assert.equal(
    f.connection.state,
    'handshake',
    '已打开的 socket 要**直接**进握手 —— 等 onopen 会永远停在 connecting（连上了但什么都不发生）',
  )

  // 对端走了：收口，然后**停住**（不接受来的连接自愈）。
  f.client.close()
  await sleep(80)
  assert.equal(f.dials(), 0, '接受来的连接不许自愈：它会去拨配置里的中转地址')
  const resting = String(f.connection.state)
  assert.equal(resting !== 'backoff' && resting !== 'connecting', true, `实际停在 ${resting}`)
})

test('接受路径：可攒批的帧真的发得出去（定时器要跟着起）', async (t) => {
  const f = await acceptOne(t, { batchMs: 20 })
  f.connection.markHandshakeDone()
  assert.equal(f.connection.state, 'serving')

  // `ev` 是可攒批的帧：`send()` 收下它（回 true），真正出线要等 flush 周期。
  assert.equal(f.connection.send({ v: 1, t: 'ev', sid: 'sid_1', seq: 1, box: 'x' }), true)
  await waitFor('攒批的 ev 出线', () => f.lines.some((line) => line.includes('"t":"ev"')))
})

test('接受路径：半开判得出来（保活判定要跟着起）', async (t) => {
  // 心跳 40 ms ⇒ 判定周期 10 ms、半开阈值 80 ms。对端一帧不发。
  const f = await acceptOne(t, { heartbeatMs: 40 })
  f.connection.markHandshakeDone()
  assert.equal(f.connection.state, 'serving')

  // 客户端连上就不说话：两个空闲周期之后必须判半开并关掉 socket（随后停在 closed，
  // 且**不**重连 —— 接受路径不自愈）。
  await waitFor('判出半开并离开服务态', () => f.connection.state !== 'serving', 3_000)
  assert.equal(f.dials(), 0, '半开关闭之后也不许自愈')
})

