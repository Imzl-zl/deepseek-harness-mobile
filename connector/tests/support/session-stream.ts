/**
 * 可控的会话流替身（`sessionController.follow` 的测试形态）。
 *
 * 与 `job-stream.ts` 同形，但帧类型是 `SessionFrame`（开启快照 / 事件 / assistant 流）。
 * 「按需推一帧」是必需的：快照展开、`rev` 递增、换尝试换流号这些行为都要能逐步构造。
 */
import type { SessionFrame } from '../../src/dsh/sessions.js'
import type { SessionFollowSource } from '../../src/session-subscriptions.js'

type Item = { kind: 'frame'; frame: SessionFrame } | { kind: 'end' } | { kind: 'fail'; error: unknown }

export interface ControllableSessionStream {
  readonly request: Parameters<SessionFollowSource['follow']>[0]
  readonly signal: AbortSignal
  push(frame: SessionFrame): void
  end(): void
  fail(error: unknown): void
}

export function createControllableSessionSource(): {
  source: SessionFollowSource
  streams: ControllableSessionStream[]
} {
  const streams: ControllableSessionStream[] = []

  const source: SessionFollowSource = {
    follow(request, signal) {
      const queue: Item[] = []
      let wake: (() => void) | null = null
      signal.addEventListener('abort', () => {
        wake?.()
        wake = null
      })

      const stream: ControllableSessionStream = {
        request,
        signal,
        push: (frame) => {
          queue.push({ kind: 'frame', frame })
          wake?.()
          wake = null
        },
        end: () => {
          queue.push({ kind: 'end' })
          wake?.()
          wake = null
        },
        fail: (error) => {
          queue.push({ kind: 'fail', error })
          wake?.()
          wake = null
        },
      }
      streams.push(stream)

      return {
        [Symbol.asyncIterator]: () => ({
          next: async (): Promise<IteratorResult<SessionFrame>> => {
            for (;;) {
              if (signal.aborted) return { done: true, value: undefined }
              const item = queue.shift()
              if (item !== undefined) {
                if (item.kind === 'end') return { done: true, value: undefined }
                if (item.kind === 'fail') throw item.error
                return { done: false, value: item.frame }
              }
              await new Promise<void>((resolve) => {
                wake = resolve
              })
            }
          },
          return: async (): Promise<IteratorResult<SessionFrame>> => ({ done: true, value: undefined }),
        }),
      }
    },
  }

  return { source, streams }
}
