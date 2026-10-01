/**
 * 幂等执行（契约 §5.6、不变量 I8）。
 *
 * 语义只有一句：**同一个幂等键只生效一次**。但把它做对要回答三个问题，
 * 三个答案都在这里，且都不是"顺手写的"：
 *
 * ## 一、只记成功，失败不记
 *
 * 命中"已完成"就回上次的结果；但**失败不进表**。理由：需要被记住的是
 * 「这次操作**已经生效**，只是应答可能在路上丢了」—— 那才是重复执行会出事的形状。
 * 失败意味着"没有确认生效"，把它缓存 24 小时等于把一次瞬时故障变成死路；
 * 而重新执行对我们带键的方法都是安全的（下游各自兜着，见下）。
 *
 * ## 二、崩溃窗口里**重新执行**，而不是 fail-closed
 *
 * 桥接进程在"执行到一半"时挂掉，表里不会留下成功记录，重发就会再执行一次。
 * 这个选择之所以成立，是因为带键的方法**每一个**都有下游保障：
 *
 * | 方法 | 重复执行为什么安全 |
 * |---|---|
 * | `session.prompt` | DSH 把 `requestId` 持久在恰好被接受的那条用户消息上，自己会去重（`dsh/sessions.ts` 的注释、`types.ts:333-335`） |
 * | `settings.update` / `credentials.set\|unset` | 同一个字段写同一个值，end state 相同（天然幂等） |
 * | `interaction.respond` | 已经决定过的交互再答一次会被 DSH 拒（`interaction/not-pending`，§3.1） |
 *
 * 所以这里**不写 `pending` 行**：它是"崩溃窗口"的标记，而既然崩溃窗口里的动作就是
 * 重新执行，那一行就永远不会被读 —— 白写一次盘、还要靠 TTL 清掉。
 * （表结构里的 `pending` 档保留：真要改 fail-closed 时它才需要被写。）
 *
 * ## 三、同键并发**合流**，不是拒绝
 *
 * 手机重发时前一次可能还在飞行中。成熟做法（Stripe 的 idempotency key）会给一个 409，
 * 因为它们的键跨机器、无法知道对端状态；而这里的执行就在本进程里，
 * 所以直接**把两个调用接到同一个 promise 上**：只执行一次，两边拿到同一个应答。
 * 对手机来说，"重发"永远得到一个确定的结果，而不是一个要它自己判断的错误码。
 *
 * 取舍见 `.agents/notes/implemented/2026-10-01-idempotency-wiring.md`
 */
import type { DedupeEntry } from './store/index.js'
import type { ChannelLogger } from './observability.js'
import { ProtocolError, isErrorCode } from './protocol/errors.js'
import type { ResponseEnvelope } from './protocol/methods.js'

/** 去重表容量上界（契约 §8.1 / §10）。 */
export const DEDUPE_CAPACITY = 10_000
/** 去重表 TTL（契约 §8.1 / §10：24 小时）。 */
export const DEDUPE_TTL_MS = 24 * 60 * 60 * 1000
/**
 * 单次收敛最多清多少条。
 *
 * 必要性来自介质：域表的写入走**单写链**（`store/index.ts` 的说明），一次一万条删除就是
 * 一万次串行落盘 —— 挂载会因此卡住几十秒。所以收敛是"每次有界、需要就再来一次"，
 * 而**过期语义不靠它兜底**（见 `run` 里的惰性过期）。
 */
export const DEDUPE_SWEEP_LIMIT = 500

/**
 * 幂等表落盘面 —— 收窄成这一层真正用到的方法。
 *
 * 结构上 `store/` 的 `dedupe` 表天然满足它（`get` / `put` / `delete` / `entries` / `size`），
 * 于是本文件不需要 DSH 运行时也能测。
 */
export interface DedupeRows {
  get(key: string): DedupeEntry | undefined
  put(key: string, value: DedupeEntry): Promise<void>
  delete(key: string): Promise<boolean>
  entries(): IterableIterator<[string, DedupeEntry]>
  readonly size: number
}

export interface IdempotencyOptions {
  rows: DedupeRows
  now?: () => number
  capacity?: number
  ttlMs?: number
  log?: ChannelLogger
}

export interface Idempotency {
  /**
   * 带幂等键地执行一次。
   *
   * @param execute - 真正干活的闭包。**只在需要时被调用一次**（命中缓存或合流时不会被调用）。
   */
  run(requestId: string, execute: () => Promise<ResponseEnvelope>): Promise<ResponseEnvelope>
  /** 按 TTL 与容量收敛表。返回清掉的条数。 */
  prune(): Promise<number>
  /** 当前在飞的执行数（指标与测试用）。 */
  readonly inFlight: number
}

/** 把存下来的应答读回来。形状不对就当没命中 —— 坏行不该让通道不可用。 */
function parseEnvelope(resultRef: string): ResponseEnvelope | undefined {
  let parsed: unknown
  try {
    parsed = JSON.parse(resultRef)
  } catch {
    return undefined
  }
  if (typeof parsed !== 'object' || parsed === null) return undefined
  const record = parsed as Record<string, unknown>
  if (record['ok'] === true) return { ok: true, result: record['result'] }
  if (record['ok'] === false) {
    const code = record['code']
    return {
      ok: false,
      // 未知码归一成 `internal`：与 `ProtocolError` 同一条纪律（§3.1 的表是封闭的）。
      code: isErrorCode(code) ? code : 'internal',
      ...(typeof record['message'] === 'string' ? { message: record['message'] } : {}),
    }
  }
  return undefined
}

export function createIdempotency(options: IdempotencyOptions): Idempotency {
  const { rows } = options
  const now = options.now ?? (() => Date.now())
  const capacity = options.capacity ?? DEDUPE_CAPACITY
  const ttlMs = options.ttlMs ?? DEDUPE_TTL_MS
  const log = options.log

  /** 同键并发合流：**执行只发生一次**，两边拿到同一个应答。 */
  const inFlight = new Map<string, Promise<ResponseEnvelope>>()

  /**
   * ① 先落盘 `pending` 标记（契约 §5.6 的两阶段写入）。
   *
   * **写不进去就拒绝这次写操作**：不进入执行阶段。理由很直接 ——
   * 一次"执行了但没记下"的写操作，在崩溃之后没有任何痕迹能证明它发生过，
   * 而重发就会变成第二条消息。
   */
  const begin = async (requestId: string): Promise<void> => {
    await rows.put(requestId, { at: now(), status: 'pending' })
  }

  /** ③ 成功后改写为 `done` + 结果。 */
  const remember = async (requestId: string, envelope: ResponseEnvelope): Promise<void> => {
    try {
      await rows.put(requestId, {
        at: now(),
        status: 'done',
        resultRef: JSON.stringify(envelope),
      })
      // 超容量才收敛：每次写都扫一遍 10000 行不值得。
      if (rows.size > capacity) await prune()
    } catch (error) {
      // 执行已经生效，改不回去：应答照回，但**这一行会停在 `pending`** ——
      // 于是手机重发时会拿到"结果未知"而不是被再执行一次（宁可让它刷新，也不制造第二条消息）。
      log?.warn('幂等表结果写入失败：应答照回，但该键会停在 pending（重发将被拒绝）', error)
    }
  }

  /** 执行**已知没有生效**（handler 回了失败）：清掉 pending，让重发可以真的重来。 */
  const abandon = async (requestId: string): Promise<void> => {
    try {
      await rows.delete(requestId)
    } catch (error) {
      // 删不掉只是留一个 pending：重发会被拒（安全方向的降级），留声即可。
      log?.warn('幂等表 pending 清理失败（重发会被拒绝，直到 TTL 过期）', error)
    }
  }

  const prune = async (): Promise<number> => {
    const deadline = now() - ttlMs
    // 先按 TTL 清，再按容量清最旧的；两次都受单次上限约束。
    const alive: [string, DedupeEntry][] = []
    let removed = 0
    for (const [key, entry] of rows.entries()) {
      if (entry.at < deadline && removed < DEDUPE_SWEEP_LIMIT) {
        await rows.delete(key)
        removed += 1
      } else {
        alive.push([key, entry])
      }
    }
    if (alive.length > capacity && removed < DEDUPE_SWEEP_LIMIT) {
      alive.sort((a, b) => a[1].at - b[1].at)
      const room = Math.min(alive.length - capacity, DEDUPE_SWEEP_LIMIT - removed)
      for (const [key] of alive.slice(0, room)) {
        await rows.delete(key)
        removed += 1
      }
    }
    if (removed >= DEDUPE_SWEEP_LIMIT) {
      log?.warn(`幂等表一次最多收敛 ${DEDUPE_SWEEP_LIMIT} 条，余量留给下一次（写入超容量时会再触发）`)
    } else if (removed > 0) {
      log?.debug(`幂等表收敛：清掉 ${removed} 条`)
    }
    return removed
  }

  return {
    get inFlight() {
      return inFlight.size
    },

    prune,

    async run(requestId, execute) {
      const cached = rows.get(requestId)
      if (cached !== undefined && cached.status === 'done' && cached.resultRef !== undefined) {
        if (cached.at < now() - ttlMs) {
          // **惰性过期**：TTL 是语义，不是"什么时候清"。清扫是有界的（见 `prune`），
          // 所以不能指望它兜住正确性 —— 过期条目必须在被读到的这一刻就作废。
          log?.debug(`幂等条目已过期：${requestId} 按未命中处理`)
          await rows.delete(requestId)
        } else {
          const envelope = parseEnvelope(cached.resultRef)
          if (envelope !== undefined) {
            log?.debug(`幂等命中：${requestId} 不再执行`)
            return envelope
          }
          // 坏行当成没命中：清掉它，免得每次重发都撞同一行坏数据。
          log?.warn(`幂等条目无法解析，按未命中处理并清除`, { requestId })
          await rows.delete(requestId)
        }
      }

      const running = inFlight.get(requestId)
      if (running !== undefined) {
        log?.debug(`同键执行在路上：${requestId} 合流`)
        return running
      }

      /**
       * 行停在 `pending` 且本进程没有在飞 = **上一次执行的结果未知**（进程崩在②与③之间）。
       *
       * 这时**不能重发**：那条写操作可能已经生效，而我们没有任何痕迹能区分。
       * 契约 §5.6 说这种情况要向 DSH 核对（该 requestId 是否已随 `user/message`
       * 落在会话日志里）—— 那是下一步；在核对落地之前，这里**拒绝**（fail-closed）：
       * 宁可让手机刷新一次，也不制造第二条消息。
       */
      if (cached !== undefined && cached.status === 'pending' && cached.at >= now() - ttlMs) {
        log?.warn(`幂等键停在 pending：上一次执行结果未知，拒绝重发（请刷新会话）`, { requestId })
        throw new ProtocolError('internal', '上一次写操作的结果未知：请刷新会话后再试')
      }

      const promise = (async (): Promise<ResponseEnvelope> => {
        // 两阶段的顺序**不得调换**（§5.6）：先落盘，再执行。
        await begin(requestId)
        const envelope = await execute()
        if (envelope.ok) await remember(requestId, envelope)
        else await abandon(requestId)
        return envelope
      })()
      inFlight.set(requestId, promise)
      try {
        return await promise
      } finally {
        inFlight.delete(requestId)
      }
    },
  }
}
