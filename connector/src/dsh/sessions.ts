/**
 * 会话适配：把 DSH 的 `SessionController` 映射成通道的会话面（契约 §5、§8）。
 *
 * **只做映射，不重建投影语义** —— 会话流、历史、发送、取消全部取自 DSH 已有服务；
 * 本层不自己折叠事件、不自己维护条目（那是 `src/protocol/` 的职责）。
 *
 * 三处必须照源码走的语义：
 *
 * 1. **修订号就是 DSH 事件自带的 `seq`，插件不分配**（契约 §5.1）。
 *    `SessionWireEvent.seq`：`packages/api/session-controller/src/types.ts:458-460`。
 * 2. **基线切点来自 `follow` 的开启帧 `cursor`**，`page()` 的 `throughSeq` 用它 ——
 *    这正是契约 §1.3「基线快照用 `page()` 分页构造，**不重开 `follow`**」的落点
 *    （`types.ts:552-561` 的 snapshot 帧；`types.ts:471-474` 的 `throughSeq` 注释
 *    "Inclusive log cut obtained from the corresponding follow opening frame"）。
 * 3. **`assistant-stream` 帧不占会话 `seq`**：它带的是 assistant 流的 `revision` 与 `index`
 *    （`types.ts:507-543`），因此映射成通道的 **`live`** 帧 —— 不推进修订号、不进重放窗口、
 *    恢复时不回带（契约 §3）。
 */
import type { SessionController } from '@deepseek-ai/dsh-api-session-controller'
import type {
  PromptContentPart,
  SessionAddress,
  SessionAssistantStreamFrame,
  SessionFollowFrame,
  SessionHistoryRecord,
  SessionPage,
  SessionPageRequest,
  SessionPromptRequest,
  SessionWireEvent,
  SessionWireHeader,
} from '@deepseek-ai/dsh-api-session-controller/types'

/**
 * DSH 的会话 id 与序号游标都是 branded 类型，定义在 `@deepseek-ai/dsh-session/types` ——
 * 那个包**不是**本插件声明的依赖，直接 import 会变成幽灵依赖。
 * 从已声明依赖的类型里派生，既拿到精确类型又不欠新债。
 */
type DshSessionId = SessionPromptRequest['sessionId']
type SeqCursor = SessionPageRequest['throughSeq']

/** 普通会话的地址（`types.ts:408-415`）。本层对外只说普通 `string`，brand 收在这一行。 */
export function sessionAddress(sessionId: string): SessionAddress {
  return { kind: 'session', sessionId: sessionId as DshSessionId }
}

/** 子代理会话的地址；`mode` 由 catalog 决定，未知时用 `'unknown'`。 */
export function subagentAddress(
  parentSessionId: string,
  childSessionId: string,
  mode: 'one-shot' | 'continuable' | 'unknown' = 'unknown',
): SessionAddress {
  return {
    kind: 'subagent',
    parentSessionId: parentSessionId as DshSessionId,
    childSessionId: childSessionId as DshSessionId,
    mode,
  }
}

/**
 * 会话面上抛给上层的帧。三者对应三种**不同的**序号语义，绝不能混：
 * - `opening`：基线切点（`cursor`），恢复的 `asOfSeq` 就是它；
 * - `event`：持久事件，`seq` 是修订号，进窗口、参与去重；
 * - `live`：流式帧，**没有**修订号，不落盘、不回带。
 */
export type SessionFrame =
  | {
      kind: 'opening'
      /** Inclusive log cut：基线水位，也是 `page()` 的 `throughSeq`。 */
      cursor: number
      header: SessionWireHeader
      records: readonly SessionHistoryRecord[]
      hasMore: boolean
    }
  | { kind: 'event'; event: SessionWireEvent }
  | { kind: 'live'; frame: SessionAssistantStreamFrame }

export interface PageRequest {
  address: SessionAddress
  /** 必填：来自 `follow` 开启帧的 `cursor`。 */
  throughSeq: number
  beforeSeq?: number
  maxMessages?: number
}

/**
 * 会话清单里的一行（契约 §5.7 的 `session.list`）。
 *
 * **刻意不带别名**：别名（`sid`）是**通道的概念**，中继只见 `sid`、手机只见 `sid`，
 * 而本层只做 DSH 的映射 —— 分配别名的动作留给方法面（那里同时握着别名表）。
 *
 * 也**刻意没有标题**：`sessionController.list()` 不带标题（`SessionSummary` 只有
 * `sessionId` / `updatedAt` / `running` / `blank` / `origin` / `cwd` 等），
 * 标题在 `session-title` 那一边，而那个服务读的是**活的 `Session` 对象** ——
 * 对"只存在于落盘里的会话"拿不到。详见 `.agents/notes/implemented/2026-10-01-session-list-wiring.md`。
 */
export interface SessionSummaryRow {
  /**
   * DSH 的会话 id。**不要发给手机**（中继只见 `sid`）；它只在本进程内用来换别名。
   * 方法面必须逐字段构造给手机的行走，不要 spread 这一行。
   */
  dshSessionId: string
  /** 最近活动时间；清单**已按它排序**（权威自己排的，本层不再排一遍）。 */
  updatedAt: number
  /** 当前是否有轮次在跑。 */
  running: boolean
  /** 还没有任何轮次（新建会话）。 */
  blank: boolean
  /** 子代理的子会话（`origin === 'subagent'`）—— 手机可以选择折叠，本层不替它决定。 */
  subagent: boolean
  cwd?: string
}

/**
 * 不参与的取消信号。
 *
 * `SessionController.list` 的签名要求一个 `AbortSignal`，而方法面这一层没有请求级的信号
 * （手机没有"取消这次列表"的方法）。用一个永不中止的信号，比每次现造一个 `AbortController`
 * 再丢掉更直白。
 */
const NEVER_ABORTS = new AbortController().signal

/** 用户消息里的一段内容（文本或内联图片）。**类型留在 `dsh/` 内**，上层只 import 这个名字。 */
export type PromptPart = PromptContentPart

export interface SessionsPort {
  /**
   * 会话清单（按活动排序）。
   *
   * 取自 `SessionController.list`（`packages/api/session-controller/src/index.ts:251-254`，
   * 注释原文「visible Session rows … ordered by activity」）—— **不要去列落盘目录**：
   * 那会绕过 DSH 的可见性判定，还会把子代理会话混进用户的清单。
   */
  list(signal?: AbortSignal): Promise<readonly SessionSummaryRow[]>
  /** 打开实时流。**调用方持有 signal 的生命周期**；中止即关闭订阅。 */
  follow(
    request: { address: SessionAddress; assistantStream?: true },
    signal: AbortSignal,
  ): AsyncIterable<SessionFrame>
  /** 向后翻页取历史；`throughSeq` 必须是开启帧的 `cursor`。 */
  page(request: PageRequest, signal: AbortSignal): Promise<SessionPage>
  /**
   * 发一句话。`requestId` 是**幂等键**：DSH 把它持久在恰好被接受的那条用户消息上
   * （`types.ts:333-335`），所以断线重发不会产生第二条消息（不变量 I8）。
   *
   * 它只等「进入 inbox」并返回 `{ accepted: true }`（`types.ts:343-346`），**不等模型跑完**。
   */
  prompt(
    sessionId: string,
    requestId: string,
    content: readonly PromptContentPart[],
    mode?: 'queue' | 'steer',
  ): Promise<{ accepted: true }>
  /** 取消当前 turn。注意它**不接受 signal**（`index.ts:457`）。 */
  cancel(sessionId: string): { accepted: true }
}

/**
 * `prompt` 的等待上限。只防挂死，**不是生成超时** —— DSH 侧它只负责把消息放进 inbox。
 */
const PROMPT_TIMEOUT_MS = 30_000

/**
 * 把一帧 DSH 的 follow 帧映射成通道语义的帧。
 *
 * 未知帧型返回 `undefined` 而不是抛错：`SessionFollowFrame` 是可扩展联合，
 * 遇到不认识的就该跳过，不该让整条订阅流断掉。
 */
function mapFrame(frame: SessionFollowFrame): SessionFrame | undefined {
  switch (frame.type) {
    case 'snapshot':
      return {
        kind: 'opening',
        cursor: frame.cursor,
        header: frame.header,
        records: frame.records,
        hasMore: frame.hasMore,
      }
    case 'event':
      return { kind: 'event', event: frame.event }
    case 'assistant-stream':
      return { kind: 'live', frame: frame.frame }
    default:
      return undefined
  }
}

export function createSessionsAdapter(controller: SessionController): SessionsPort {
  return {
    async list(signal) {
      const value = await controller.list({}, signal ?? NEVER_ABORTS)
      // 逐字段映射，**不 spread**：将来 DSH 在 `SessionSummary` 上加字段时，
      // 它会自动被挡在门外，而不是悄悄跟着这一行发到中继与手机上。
      return value.items.map((item) => ({
        dshSessionId: item.sessionId,
        updatedAt: item.updatedAt,
        running: item.running,
        blank: item.blank,
        subagent: item.origin === 'subagent',
        ...(item.cwd === undefined ? {} : { cwd: item.cwd }),
      }))
    },

    async *follow(request, signal) {
      // `follow(request, signal): AsyncIterable<SessionFollowFrame>`（`index.ts:480`）。
      const stream = controller.follow(
        {
          address: request.address,
          ...(request.assistantStream === true ? { assistantStream: true as const } : {}),
        },
        signal,
      )
      for await (const frame of stream) {
        const mapped = mapFrame(frame)
        if (mapped !== undefined) yield mapped
      }
    },

    page(request, signal) {
      const pageRequest: SessionPageRequest = {
        address: request.address,
        throughSeq: request.throughSeq as SeqCursor,
        ...(request.beforeSeq === undefined
          ? {}
          : { beforeSeq: request.beforeSeq as SeqCursor }),
        ...(request.maxMessages === undefined ? {} : { maxMessages: request.maxMessages }),
      }
      return controller.page(pageRequest, signal)
    },

    prompt(sessionId, requestId, content, mode = 'queue') {
      const promptRequest: SessionPromptRequest = {
        requestId: requestId as SessionPromptRequest['requestId'],
        sessionId: sessionId as DshSessionId,
        mode,
        content,
      }
      return controller.prompt(promptRequest, AbortSignal.timeout(PROMPT_TIMEOUT_MS))
    },

    cancel(sessionId) {
      return controller.cancel({ sessionId: sessionId as DshSessionId })
    },
  }
}
