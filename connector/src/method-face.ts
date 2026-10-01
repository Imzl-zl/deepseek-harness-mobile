/**
 * 方法面：把入站 `req` 帧接到分发器上，并把结果封成 `res` 帧（契约 §5.7、§9）。
 *
 * ## 这一层只做接线，不做业务
 *
 * - **解析**：`box` 到这一层时已经是**明文载荷**（连接层解箱），这里只解信封；
 * - **分发**：交给 `protocol/methods.ts` 的 `createDispatcher`（方法名封闭集、幂等键强制、
 *   分发器从不抛）；
 * - **回帧**：把信封封回 `box`，并**原样回带 `id` 与 `sid`** —— `id` 是请求与应答的唯一关联，
 *   丢了它手机就永远等不到回应（而症状是"发出去了没反应"，最难查的一类）。
 *
 * ## 两条"绝不"的纪律
 *
 * 1. **绝不抛**。载荷坏、方法不认识、handler 内部炸 —— 一律变成 `res ok:false` 的结构化错误；
 *    只有协议级错误（帧不合法、重放、握手未完成）才该关连接（§9，与 `methods.ts` 同一条纪律）。
 * 2. **绝不自己分配 `fc`、绝不封箱**。那些是连接层的事：`fc` 是 nonce 来源，封箱与它紧挨着
 *    分配（见 `transport/connection.ts` 的第 5 条接线决定）。这一层只产出"待发帧"。
 *
 * 取舍见 `.agents/notes/implemented/2026-10-01-method-face-wiring.md`
 */
import { ProtocolError } from './protocol/errors.js'
import type { WireFrame } from './protocol/frame.js'
import {
  createDispatcher,
  decodeRequest,
  isMethod,
  requiresIdempotencyKey,
  type DispatchContext,
  type MethodHandler,
  type MethodName,
  type ResponseEnvelope,
} from './protocol/methods.js'
import type { Idempotency } from './idempotency.js'
import type { OutboundFrame } from './transport/connection.js'

/**
 * 方法面产出的帧：**只会是 `res`**。
 *
 * 收窄到 `res` 而不是 `OutboundFrame` 联合：这一层不该有能力产出别的帧，
 * 而类型是唯一能在编译期把这条钉住的地方（`fc` 与封箱仍在连接层，所以这里不含 `fc`）。
 */
export type ResFrame = Extract<OutboundFrame, { t: 'res' }>

export interface MethodFaceOptions {
  /** 已实现的方法；表里没有的回 `connector/unsupported`。 */
  handlers: Partial<Record<MethodName, MethodHandler>>
  /**
   * 幂等执行（契约 §5.6）。**只对带幂等键的方法生效**（`IDEMPOTENT_METHODS`）：
   * 只读方法带键也不进表 —— 用一次缓存住的列表去回答第二次读，是拿旧数据糊弄人。
   */
  idempotency?: Idempotency
  /** 分发失败时的留声点。默认静默（测试与无人值守装配用）。 */
  onError?: (message: string, detail?: unknown) => void
}

export interface MethodFace {
  /**
   * 处理一帧。
   *
   * @returns 待发的 `res` 帧（**没分配 `fc`、没封箱**），或 `null` 表示这一帧不归方法面管。
   *   本方法**从不抛**：所有失败都变成 `ok:false` 的信封。
   */
  handle(frame: WireFrame): Promise<ResFrame | null>
  /** 已经实现了哪些方法（`repo.info` 的能力位与自检用）。 */
  readonly implemented: readonly MethodName[]
}

/**
 * 把应答信封装成 `res` 帧。
 *
 * `ok` 在**帧头**与**信封里**各出现一次：帧头那份是给中继与手机路由用的（明文，不解箱就能分支），
 * 信封那份是给应用用的。两处必须同源 —— 所以它们只在这个函数里被同时写一次。
 */
export function resFrame(
  request: { id: string; sid?: string },
  envelope: ResponseEnvelope,
): ResFrame {
  return {
    v: 1,
    t: 'res',
    id: request.id,
    ...(request.sid === undefined ? {} : { sid: request.sid }),
    ok: envelope.ok,
    box: JSON.stringify(envelope),
  }
}

export function createMethodFace(options: MethodFaceOptions): MethodFace {
  const dispatcher = createDispatcher(options.handlers)
  const idempotency = options.idempotency
  const warn = options.onError

  return {
    implemented: dispatcher.implemented,

    async handle(frame) {
      if (frame.t !== 'req') return null
      const context: DispatchContext = frame.sid === undefined ? {} : { sid: frame.sid }

      try {
        const request = decodeRequest(frame.box)
        const execute = (): Promise<ResponseEnvelope> => dispatcher.dispatch(request, context)
        // 幂等只挂**带键的方法**：只有它们承诺"重发不会产生第二次效果"（I8）。
        // 键存在但不是带键方法（比如手机给只读方法塞了一个）→ 不进表，照常执行。
        const envelope =
          idempotency !== undefined &&
          request.requestId !== undefined &&
          isMethod(request.method) &&
          requiresIdempotencyKey(request.method)
            ? await idempotency.run(request.requestId, execute)
            : await execute()
        return resFrame(frame, envelope)
      } catch (error) {
        // 走到这里只可能是**载荷本身**坏了（不是 JSON / 缺 method）—— `dispatch` 从不抛。
        // 它是结构化错误，不是断连理由：回一个错误信封，连接留着。
        const code = error instanceof ProtocolError ? error.code : 'internal'
        warn?.(`请求载荷无法解析（${code}）`, error)
        return resFrame(frame, {
          ok: false,
          code,
          message: error instanceof Error ? error.message : String(error),
        })
      }
    },
  }
}
