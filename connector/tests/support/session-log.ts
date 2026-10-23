/**
 * 用**真 `Session`** 造会话日志的测试替身。
 *
 * 为什么不是手搓 `{ type, data }` 数组：本仓关于提问身份的判据全长在 DSH 的真实事件形状上
 * （`tool/call` 的 `callId` / `name`，`tool/result` 的 `message.toolCallId`），手搓一个形状
 * 只会复述我们对它的假设 —— 正是"替身复述的不是真形状"那类事故。`@deepseek-ai/dsh-session`
 * 是连接器的 devDependency，真类就在手边（`Session.create` 是它的 detached 构造器）。
 *
 * 顺序照 DSH 的循环：`tool/call` 在 execute **之前**追加
 * （`packages/core/agent-loop/src/tool-calls.ts:168` 调 `appendToolCall`，`:263-266`），
 * `tool/result` 在 execute **之后**（`:156` 调 `appendToolResult`）。所以"应答者被调用时"
 * 这一格 = 只追加了 call、还没追加 result。
 */
import { Session, type SessionSeq } from '@deepseek-ai/dsh-session'

/** 一个刚开过 turn/step 的空会话。 */
export function emptySession(id = 's-test'): Session {
  const created = Session.create(id as never)
  created.append('turn/start', { turn: 1 })
  created.append('step/start', { turn: 1, step: 1 })
  return created
}

/** 照 `appendToolCall` 追加一次调用，返回它的 seq（结算时要引用它）。 */
export function openCall(session: Session, callId: string, name = 'ask_user_question'): SessionSeq {
  return session.append('tool/call', {
    turn: 1,
    step: 1,
    callId: callId as never,
    name,
    arguments: '{"questions":[]}',
  }).seq
}

/** 照 `appendToolResult` 结算一次调用（`surfaceOp: 'append'` + 引用 call 的 seq）。 */
export function settleCall(session: Session, callId: string, callSeq: SessionSeq): void {
  session.append(
    'tool/result',
    {
      turn: 1,
      step: 1,
      // 手写载荷：品牌类型（MessageId / ToolCallId）在测试边界统一放行。
      message: {
        id: `m-${callId}`,
        time: 0,
        role: 'tool',
        source: { kind: 'tool', callId },
        toolCallId: callId,
        content: [{ type: 'text', text: '{"answers":[]}' }],
        isError: false,
      } as never,
    },
    { surfaceOp: 'append', sourceEventSeqs: [callSeq] },
  )
}
