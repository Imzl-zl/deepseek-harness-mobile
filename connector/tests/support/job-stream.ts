/**
 * 可控的宿主流替身（`jobController.follow` 的测试形态）。
 *
 * 真宿主流是"来了就推"，而这里要能**按需**推一帧、结束、或抛错 ——
 * 否则"旧订阅被替换后那一帧不许再出"、"结算帧之后循环收口"这类行为根本构造不出来。
 * 同时保留真实语义：`signal` 中止即结束迭代（产品的转发循环靠它收工）。
 */
import type { JobOutputFrame } from '../../src/protocol/job-output.js'
import type { JobFollowSource } from '../../src/job-subscriptions.js'

type Item = { kind: 'frame'; frame: JobOutputFrame } | { kind: 'end' } | { kind: 'fail'; error: unknown }

export interface ControllableStream {
  readonly request: { dshSessionId: string; jobId: string; from?: number }
  readonly signal: AbortSignal
  /** 推一帧给消费方。 */
  push(frame: JobOutputFrame): void
  /** 正常结束迭代（宿主在 `status` 之后就是这样）。 */
  end(): void
  /** 让迭代抛错（宿主内部失败的样子）。 */
  fail(error: unknown): void
  /** 消费方取走了多少帧（用来断言"被替换之后不再消费"）。 */
  readonly pulls: () => number
}

export function createControllableSource(): {
  source: JobFollowSource
  streams: ControllableStream[]
} {
  const streams: ControllableStream[] = []

  const source: JobFollowSource = {
    follow(request, signal) {
      const queue: Item[] = []
      let wake: (() => void) | null = null
      let pulls = 0
      signal.addEventListener('abort', () => {
        wake?.()
        wake = null
      })

      const stream: ControllableStream = {
        request,
        signal,
        pulls: () => pulls,
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
          next: async (): Promise<IteratorResult<JobOutputFrame>> => {
            for (;;) {
              if (signal.aborted) return { done: true, value: undefined }
              const item = queue.shift()
              if (item !== undefined) {
                if (item.kind === 'end') return { done: true, value: undefined }
                if (item.kind === 'fail') throw item.error
                pulls += 1
                return { done: false, value: item.frame }
              }
              await new Promise<void>((resolve) => {
                wake = resolve
              })
            }
          },
          return: async (): Promise<IteratorResult<JobOutputFrame>> => ({ done: true, value: undefined }),
        }),
      }
    },
  }

  return { source, streams }
}
