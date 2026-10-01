/**
 * 接受路径的回归（监听面 accept 之后把 socket 交给连接）。
 *
 * 本轮只验证**两处与拨号不同的生命周期**（它们都不会报错，只会表现成怪现象）：
 *
 * 1. 接受来的 socket **已经 OPEN** —— `onopen` 不会再触发，所以要直接走一次"打开"处理。
 *    少了它，连接永远停在 `connecting`，症状是"连上了但什么都不发生"。
 * 2. 接受来的连接**不自愈** —— 它没有拨号目标。若按拨号那套在断开后 `dial(url)`，
 *    症状是"监听模式下桥接莫名其妙连去中转"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { AddressInfo } from 'node:net'

import { WebSocket, WebSocketServer } from 'ws'

import { createConnection } from '../src/transport/connection.js'

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms))

test('接受路径：已打开的 socket 直接进握手；断开后**不**去拨号', async (t) => {
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
  })

  const accepted = new Promise<WebSocket>((resolve) => {
    server.once('connection', (socket) => resolve(socket as unknown as WebSocket))
  })
  const client = new WebSocket(`ws://127.0.0.1:${port}`)
  const socket = await accepted

  connection.attach(socket as unknown as Parameters<typeof connection.attach>[0])
  assert.equal(
    connection.state,
    'handshake',
    '已打开的 socket 要**直接**进握手 —— 等 onopen 会永远停在 connecting（连上了但什么都不发生）',
  )

  // 等**客户端这一侧**也建立完成：否则 `close()` 会在连接建立前调用（ws 会直接抛）。
  await new Promise<void>((resolve) => client.once('open', () => resolve()))

  // 对端走了：收口，然后**停住**（不接受来的连接自愈）。
  client.close()
  await sleep(80)
  assert.equal(dials, 0, '接受来的连接不许自愈：它会去拨配置里的中转地址')
  const resting = String(connection.state)
  assert.equal(resting !== 'backoff' && resting !== 'connecting', true, `实际停在 ${resting}`)

  connection.stop()
})
