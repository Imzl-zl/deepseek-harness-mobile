/**
 * 中转侧的最小替身：一个真的 WebSocket 服务端。
 *
 * 从 `connection.test.ts` 抽出来，因为「连接级握手」那组测试要用同一套东西 ——
 * 两份拷贝会各自漂移，而漂移的症状是"只有某一组测试能过"。
 *
 * 只做协议要求的三件事：收行级 JSON 帧、把收到的帧存进数组、能掐断当前连接。
 * 它**不解析语义**（中转本来就不解 `box`）。
 */
import { WebSocketServer, type WebSocket as ServerSocket } from 'ws'

import type { WireFrame } from '../../src/protocol/frame.js'

/** 等一个条件成立，超时即失败 —— 比固定 sleep 稳，也比 sleep 快。 */
export async function waitFor(
  label: string,
  predicate: () => boolean,
  timeoutMs = 3_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  throw new Error(`等待超时：${label}`)
}

/** 向对端发一帧。**必须带行分隔符** —— 契约 §3 是行级 JSON。 */
export function sendFrame(socket: ServerSocket | undefined, frame: unknown): void {
  socket?.send(`${JSON.stringify(frame)}\n`)
}

export interface Peer {
  url: string
  received: WireFrame[]
  sockets: ServerSocket[]
  /** 掐掉当前连接（模拟网络中断）—— 服务端仍在监听，所以重连会成功。 */
  dropCurrent(): void
  /** 向当前连接发一帧。 */
  send(frame: unknown): void
  close(): Promise<void>
}

export async function startPeer(): Promise<Peer> {
  const server = new WebSocketServer({ port: 0 })
  await new Promise<void>((resolve) => server.once('listening', resolve))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('拿不到端口')

  const received: WireFrame[] = []
  const sockets: ServerSocket[] = []

  server.on('connection', (socket) => {
    sockets.push(socket)
    socket.on('message', (data) => {
      for (const line of data.toString().split('\n')) {
        if (line.trim() !== '') received.push(JSON.parse(line) as WireFrame)
      }
    })
  })

  return {
    url: `ws://127.0.0.1:${address.port}`,
    received,
    sockets,
    dropCurrent() {
      sockets.at(-1)?.terminate()
    },
    send(frame) {
      sendFrame(sockets.at(-1), frame)
    },
    async close() {
      for (const socket of sockets) socket.terminate()
      await new Promise<void>((resolve) => server.close(() => resolve()))
    },
  }
}
