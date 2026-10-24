/**
 * `trajectory` 投影的回归。
 *
 * ## 为什么这些用例走**真注册表 + 真 SessionStore**，而不是手搓事件数组
 *
 * 投影的契约有两条只有真宿主才能证明：
 *
 * 1. **`session.projections` 的 `values` 里真的出现了这个键** —— 那要
 *    `ctx.sessionProjections.snapshot(session)` 真的折过一遍
 *    （`packages/session/session-projection/src/index.ts:181-291` 的注册表
 *    与 `:603-631` 的懒建 cell）。手搓一个假注册表只会复述"我们以为它长这样"。
 * 2. **事件形状** —— 每条事件都由 DSH 自己的 `Session.append` 校验并落盘
 *    （`packages/core/session/src/index.ts:798-827` 的
 *    `snapshotJsonValue` + `validateSessionEventData` + surface 契约）。
 *    手写的字面量只会复述我们读源码时的假设 ——
 *    2026-10-15 那次"替身形状不对、生产里全空态而单测全绿"就是这一类。
 *
 * 唯一的例外是 `compaction/*`：那两个事件由 `@deepseek-ai/dsh-compaction`
 * 合并进 `SessionEventMap`（`packages/compaction/compaction/src/types.ts:24,72`），
 * 而**装那个包会把 `@deepseek-ai/cordis` 从钉死的 4.0.4 顶到 4.0.5**
 * （它的 peer 范围是 `workspace:~`，实测一次），所以这里按那两行**就地补声明**。
 *
 * ## 时间的可控性
 *
 * `append` 的 `time` 取 `Date.now()`（`packages/core/session/src/index.ts:820`），
 * 所以"用时"要在受控时钟下才断得出具体数字 —— 见 `clock()`。
 */
import assert from 'node:assert/strict'
import { test, mock } from 'node:test'

import { Context } from '@deepseek-ai/cordis'
import SessionStore, { SessionId, SessionLogOffset, SessionSeq } from '@deepseek-ai/dsh-session'
import type { Session, SessionEvent, SessionEventMap } from '@deepseek-ai/dsh-session'
import SessionProjectionRegistry from '@deepseek-ai/dsh-session-projection'

import {
  MAX_STEPS_PER_TURN,
  MAX_STEPS_TOTAL,
  MAX_TURNS,
  registerTrajectoryProjection,
} from '../src/dsh/trajectory.js'
import type { TrajectoryView } from '../src/dsh/trajectory.js'

declare module '@deepseek-ai/dsh-session/types' {
  interface SessionEventMap {
    'compaction/start': { compactionId: string; turn: number | null }
    'compaction/end': { compactionId: string; turn: number | null; error?: string }
  }
}

/**
 * 品牌串（`MessageId` / `ToolCallId`）在测试里直接造：形状由 `append` 在运行时校验
 * （`packages/core/session/src/index.ts:808-824` 的 `snapshotJsonValue` +
 * `validateSessionEventData`）。类型从 DSH 自己的事件表里取，
 * 不为了两个类型名再引一个 `@deepseek-ai/dsh-llm`。
 */
type ToolCallId = SessionEventMap['tool/call']['callId']
type MessageId = SessionEventMap['assistant/message']['message']['id']
const toolCallId = (value: string): ToolCallId => value as ToolCallId
const messageId = (value: string): MessageId => value as MessageId

/** 受控时钟：`append` 的 `time` 就取 `Date.now()`，推进它才能断出具体用时。 */
function clock(epoch: number): { advance: (ms: number) => void } {
  let now = epoch
  mock.timers.enable({ apis: ['Date'], now })
  return {
    advance(ms) {
      now += ms
      mock.timers.setTime(now)
    },
  }
}

interface Harness {
  ctx: Context
  session: Session
}

/** 让出一拍：`ctx.inject` 的回调由 fiber 调度，不是同步跑的。 */
async function tick(): Promise<void> {
  await new Promise<void>((resolve) => {
    setImmediate(resolve)
  })
}

/**
 * 真注册表 + 真会话：`registerTrajectoryProjection` 走的正是生产里那一条路。
 *
 * **注册之后必须让出一拍再开会话**：`ctx.inject(['sessionProjections'], …)` 的回调
 * 不是同步执行的（实测：不让出的话 `snapshot().values` 里连键都没有，
 * 于是这一组用例会集体变成"投影不存在"的假红/假绿）。
 */
async function harness(seed?: readonly SessionEvent[]): Promise<Harness> {
  const ctx = new Context()
  await ctx.plugin(SessionStore)
  await ctx.plugin(SessionProjectionRegistry)
  registerTrajectoryProjection(ctx)
  await tick()
  const session = seed === undefined
    ? ctx.sessions.create()
    : ctx.sessions.create(SessionId('trajectory-fork'), {
        seed,
        inheritedEventCount: SessionLogOffset(seed.length),
        meta: { isSeeded: true },
      })
  return { ctx, session }
}

/** 读手机拿到的那一份：`session.projections` 的 `values.trajectory`。 */
function viewOf({ ctx, session }: Harness): TrajectoryView {
  const value = ctx.sessionProjections.snapshot(session).values.trajectory
  assert.ok(value !== undefined, 'values 里必须有 trajectory 这个键')
  return value
}

/** `tool/result` 的载荷（`packages/core/session/src/types.ts:376-386`）。 */
function toolResult(callId: string, isError: boolean): SessionEvent<'tool/result'>['data'] {
  return {
    turn: 1,
    step: 1,
    message: {
      id: messageId(`msg-${callId}`),
      role: 'tool',
      content: [{ type: 'text', text: isError ? 'boom' : 'ok' }],
      source: { kind: 'tool', callId: toolCallId(callId) },
      toolCallId: toolCallId(callId),
      ...(isError ? { isError: true } : {}),
    },
    ...(isError ? { error: { name: 'ToolError', code: 'E_FAIL' } } : {}),
  } as SessionEvent<'tool/result'>['data']
}

/** `assistant/message` 的载荷（同文件 `:342-350`）。 */
function assistant(
  turn: number,
  step: number,
  id: string,
  usage?: Record<string, number>,
): SessionEvent<'assistant/message'>['data'] {
  return {
    turn,
    step,
    message: {
      id: messageId(id),
      role: 'assistant',
      content: [{ type: 'text', text: 'ok' }],
      source: { kind: 'model', provider: 'test', model: 'test' },
    },
    stream: [],
    // 宿主把**这一次请求**的用量挂在消息上（`usage-projection.ts:83` 读的就是它），
    // 于是"每轮多少 token"能在同一条事件流上算出来。
    ...(usage === undefined ? {} : { usage }),
  } as SessionEvent<'assistant/message'>['data']
}

/** 一轮里"模型请求 → 工具调用 → 工具结果"的最小合法序列。 */
function oneStep(session: Session, turn: number, callId: string, tool: string): void {
  session.append('step/start', { turn, step: 1 })
  session.append('assistant/message', assistant(turn, 1, `a-${callId}`), { surfaceOp: 'append' })
  session.append('tool/call', { turn, step: 1, callId: toolCallId(callId), name: tool, arguments: '{}' })
  session.append('tool/result', toolResult(callId, false), { surfaceOp: 'append' })
  session.append('step/end', { turn, step: 1 })
}

test('注册后 session.projections 的 values 里出现 trajectory 这个键', async () => {
  const harnessed = await harness()
  const { session } = harnessed
  session.append('turn/start', { turn: 1 })
  session.append('tool/call', { turn: 1, step: 1, callId: toolCallId('c1'), name: 'read', arguments: '{}' })
  session.append('tool/result', toolResult('c1', false), { surfaceOp: 'append' })
  session.append('turn/end', { turn: 1, reason: { kind: 'completed' } })

  const view = viewOf(harnessed)
  // **形状**也要钉：`viewSchema` 是 `.strict()`，多一个字段就抛 ——
  // 手机侧按这些键取值，键名漂了就是"时间轴永远空态"。
  assert.deepEqual(Object.keys(view).sort(), ['droppedSteps', 'droppedTurns', 'truncated', 'turns'])
  assert.equal(view.turns.length, 1)
  assert.deepEqual(Object.keys(view.turns[0] ?? {}).sort(), [
    // `tokens` 是 2026-10-24 加的：`usage.summary` 要按天汇总用量，而宿主的
    // `tokenUsage` 只有会话累计；`assistant/message` 自带 `usage`，这里顺手累进本轮。
    'durationMs', 'endTime', 'outcome', 'startSeq', 'startTime', 'steps', 'stepsTruncated',
    'tokens', 'turn',
  ])
  // 步的键同样钉住：`offsetMs` 是**画 x 轴唯一要的几何**（手机不做 epoch 相减）。
  assert.deepEqual(Object.keys(view.turns[0]?.steps[0] ?? {}).sort(), [
    'durationMs', 'endTime', 'isError', 'kind', 'label', 'offsetMs', 'seq', 'startTime',
  ])
})

test('每轮的 token：assistant/message 的 usage 累进本轮；没有 usage 就是 0', async () => {
  const harnessed = await harness()
  const { session } = harnessed

  // 第 1 轮：两次模型请求，各带一份 usage ⇒ 累加。
  session.append('turn/start', { turn: 1 })
  session.append('step/start', { turn: 1, step: 1 })
  session.append(
    'assistant/message',
    assistant(1, 1, 'a1', { inputTokens: 100, outputTokens: 40, cacheReadTokens: 7, cacheWriteTokens: 3 }),
    { surfaceOp: 'append' },
  )
  session.append('step/end', { turn: 1, step: 1 })
  session.append('step/start', { turn: 1, step: 2 })
  session.append(
    'assistant/message',
    assistant(1, 2, 'a2', { inputTokens: 10, outputTokens: 2 }),
    { surfaceOp: 'append' },
  )
  session.append('step/end', { turn: 1, step: 2 })
  session.append('turn/end', { turn: 1, reason: { kind: 'completed' } })

  // 第 2 轮：没有 usage（老事件 / 不计量）⇒ 0，而不是"用了 0"的编造。
  session.append('turn/start', { turn: 2 })
  session.append('step/start', { turn: 2, step: 1 })
  session.append('assistant/message', assistant(2, 1, 'a3'), { surfaceOp: 'append' })
  session.append('step/end', { turn: 2, step: 1 })
  session.append('turn/end', { turn: 2, reason: { kind: 'completed' } })

  const turns = viewOf(harnessed).turns
  assert.equal(turns[0]?.tokens, 100 + 40 + 7 + 3 + 10 + 2)
  assert.equal(turns[1]?.tokens, 0)
})

test('宿主没有 sessionProjections 服务时：不注册、也不报错', () => {
  const bare = new Context()
  // 注册是 effect，服务缺席时回调永不激活 —— 那是"这台电脑没给时间轴"这条
  // 能力缺失，不是错误。抛出去会让整个插件挂不上。
  registerTrajectoryProjection(bare)
  assert.equal(bare.get('sessionProjections'), undefined)
})

test('起止：助手段的 step/start→assistant/message、工具段的 call→result 都由电脑侧算好', async () => {
  const time = clock(1_700_000_000_000)
  const harnessed = await harness()
  const { session } = harnessed

  session.append('turn/start', { turn: 1 })
  time.advance(1_500)
  session.append('step/start', { turn: 1, step: 1 })
  time.advance(250)
  session.append('assistant/message', assistant(1, 1, 'a1'), { surfaceOp: 'append' })
  time.advance(100)
  session.append('tool/call', { turn: 1, step: 1, callId: toolCallId('c1'), name: 'read', arguments: '{}' })
  time.advance(2_000)
  session.append('tool/result', toolResult('c1', false), { surfaceOp: 'append' })
  time.advance(50)
  session.append('step/end', { turn: 1, step: 1 })
  time.advance(5_000)
  session.append('turn/end', { turn: 1, reason: { kind: 'completed' } })

  const turn = viewOf(harnessed).turns[0]
  assert.ok(turn !== undefined)
  assert.equal(turn.durationMs, 8_900, '一轮 = turn/start → turn/end')
  assert.equal(turn.outcome, 'completed')
  assert.equal(turn.steps.length, 2)

  const [assistantStep, toolStep] = turn.steps
  assert.ok(assistantStep !== undefined && toolStep !== undefined)
  assert.equal(assistantStep.kind, 'assistant')
  assert.equal(assistantStep.startTime, turn.startTime + 1_500)
  assert.equal(assistantStep.durationMs, 250, '助手段的用时 = assistant/message − step/start')
  assert.equal(assistantStep.offsetMs, 1_500, 'x 轴位置：相对本轮起点，由电脑侧算好')
  assert.equal(toolStep.kind, 'tool')
  assert.equal(toolStep.label, 'read', '工具段带工具名（手机按它给颜色/文案）')
  assert.equal(toolStep.durationMs, 2_000, '工具段的用时 = tool/result − tool/call')
  assert.equal(toolStep.offsetMs, 1_500 + 250 + 100)
  assert.equal(toolStep.endTime, turn.startTime + 1_500 + 250 + 100 + 2_000)
  // 几何的自证：位置 + 长度不超出这一轮的跨度（否则手机画到轴外面）。
  for (const segment of turn.steps) {
    assert.ok(segment.offsetMs + (segment.durationMs ?? 0) <= (turn.durationMs ?? 0))
  }

  mock.timers.reset()
})

test('进行中：只留起点，endTime 与 durationMs 都是 null', async () => {
  const harnessed = await harness()
  const { session } = harnessed
  session.append('turn/start', { turn: 1 })
  session.append('step/start', { turn: 1, step: 1 })
  session.append('tool/call', { turn: 1, step: 1, callId: toolCallId('c1'), name: 'shell', arguments: '{}' })

  const turn = viewOf(harnessed).turns[0]
  assert.ok(turn !== undefined)
  assert.equal(turn.endTime, null)
  assert.equal(turn.durationMs, null, '进行中的轮不编时长')
  assert.equal(turn.outcome, null)
  const toolStep = turn.steps.at(-1)
  assert.ok(toolStep !== undefined)
  assert.equal(toolStep.endTime, null)
  assert.equal(toolStep.durationMs, null)
})

test('结局：turn/end 的 reason.kind 原样过线；工具失败标在那一段上', async () => {
  const harnessed = await harness()
  const { session } = harnessed
  session.append('turn/start', { turn: 1 })
  session.append('step/start', { turn: 1, step: 1 })
  session.append('tool/call', { turn: 1, step: 1, callId: toolCallId('c1'), name: 'shell', arguments: '{}' })
  session.append('tool/result', toolResult('c1', true), { surfaceOp: 'append' })
  session.append('step/end', { turn: 1, step: 1 })
  session.append('turn/end', {
    turn: 1,
    reason: { kind: 'error', error: { message: 'provider exploded', code: 'UNKNOWN' } },
  })

  const turn = viewOf(harnessed).turns[0]
  assert.ok(turn !== undefined)
  assert.equal(turn.outcome, 'error', 'outcome 是 DSH 的 kind 原样，不是我们翻译过的词')
  assert.equal(turn.steps[0]?.isError, true)
})

test('被打断：边界（step/end）收口的未完成段按"被打断"记', async () => {
  const harnessed = await harness()
  const { session } = harnessed
  session.append('turn/start', { turn: 1 })
  session.append('step/start', { turn: 1, step: 1 })
  session.append('tool/call', { turn: 1, step: 1, callId: toolCallId('c1'), name: 'shell', arguments: '{}' })
  // 工具没有结果就来了 step/end —— 那一次调用是被打断的（Web 在边界处
  // 同样合成一条 isError 的结果，`trajectory-tool-definition.ts:171-213`）。
  session.append('step/end', { turn: 1, step: 1 })

  const steps = viewOf(harnessed).turns[0]?.steps ?? []
  assert.equal(steps.length, 2)
  assert.equal(steps[0]?.isError, true, '没等到 assistant/message 的助手请求也是被打断')
  assert.equal(steps[1]?.isError, true)
  for (const step of steps) {
    assert.notEqual(step.endTime, null)
    assert.equal(step.durationMs, (step.endTime ?? 0) - step.startTime)
  }
})

test('压缩段：compaction/start→compaction/end 成一段；不属于任何一轮的不进时间轴', async () => {
  const harnessed = await harness()
  const { session } = harnessed
  session.append('turn/start', { turn: 1 })
  session.append('compaction/start', { compactionId: 'k1', turn: 1 })
  session.append('compaction/end', { compactionId: 'k1', turn: 1 })
  session.append('turn/end', { turn: 1, reason: { kind: 'completed' } })
  // 轮次之间的手动压缩（`turn: null`）：没有能画它的 x 轴，如实不进时间轴。
  session.append('compaction/start', { compactionId: 'k2', turn: null })
  session.append('compaction/end', { compactionId: 'k2', turn: null })

  const view = viewOf(harnessed)
  assert.equal(view.turns.length, 1, 'turn: null 的压缩不新开一轮')
  assert.equal(view.turns[0]?.steps.length, 1)
  assert.equal(view.turns[0]?.steps[0]?.kind, 'compaction')
})

test('fork 继承前缀：继承的轮带真实时刻，cut 处未收口的段按边界收口', async () => {
  // 一个"切在轮中间"的 fork 种子：turn/start 与一条还没结果的 tool/call。
  const inherited: SessionEvent[] = [
    { type: 'turn/start', seq: SessionSeq(0), time: 1_000, data: { turn: 1 } },
    {
      type: 'tool/call',
      seq: SessionSeq(1),
      time: 1_500,
      data: { turn: 1, step: 1, callId: toolCallId('c1'), name: 'read', arguments: '{}' },
    },
  ]
  const harnessed = await harness(inherited)
  const { session } = harnessed
  // 子会话自己的收口（fork seed 构造时补的）：`reason.kind === 'forked'`
  // （`packages/core/session/src/types.ts:223-229`）。
  session.append('turn/end', { turn: 1, reason: { kind: 'forked' } })

  const view = viewOf(harnessed)
  assert.equal(view.turns.length, 1, '继承前缀只折一次，不重复开轮')
  const turn = view.turns[0]
  assert.ok(turn !== undefined)
  assert.equal(turn.startTime, 1_000, '继承事件的时刻原样保留')
  assert.equal(turn.outcome, 'forked')
  assert.equal(turn.steps[0]?.startTime, 1_500)
  assert.equal(turn.steps[0]?.endTime, turn.endTime, 'cut 处未收口的段按边界收口，不留"永远进行中"')
})

test('上限：单轮步数超限时只留最近的，并如实报 truncated', async () => {
  const harnessed = await harness()
  const { session } = harnessed
  session.append('turn/start', { turn: 1 })
  const overflow = 5
  for (let index = 0; index < MAX_STEPS_PER_TURN + overflow; index += 1) {
    session.append('tool/call', {
      turn: 1,
      step: 1,
      callId: toolCallId(`c${index}`),
      name: 'shell',
      arguments: '{}',
    })
  }

  const view = viewOf(harnessed)
  const turn = view.turns[0]
  assert.ok(turn !== undefined)
  assert.equal(turn.steps.length, MAX_STEPS_PER_TURN, '留最近的 MAX_STEPS_PER_TURN 步')
  assert.equal(turn.stepsTruncated, true, '这一轮的步数不全，界面要说出来')
  assert.equal(turn.steps[0]?.label, 'shell')
  assert.equal(view.truncated, true)
  assert.equal(view.droppedSteps, overflow)
  assert.equal(view.droppedTurns, 0)
})

test('上限：总步数超限时从最旧的轮整轮丢，并如实报 droppedTurns', async () => {
  const harnessed = await harness()
  const { session } = harnessed
  // 每轮**顶到单轮上限**：轮数远低于 MAX_TURNS，所以先撞的是总步数上限
  // （每轮 1 步的话先撞的是轮数上限 —— 两条上限各有一条用例盯着）。
  const turns = Math.floor(MAX_STEPS_TOTAL / MAX_STEPS_PER_TURN) + 1
  for (let turn = 1; turn <= turns; turn += 1) {
    session.append('turn/start', { turn })
    for (let index = 0; index < MAX_STEPS_PER_TURN; index += 1) {
      session.append('tool/call', {
        turn,
        step: 1,
        callId: toolCallId(`c${turn}-${index}`),
        name: 'shell',
        arguments: '{}',
      })
    }
    session.append('turn/end', { turn, reason: { kind: 'completed' } })
  }

  const view = viewOf(harnessed)
  assert.equal(view.truncated, true)
  assert.equal(view.droppedTurns, 1, '只丢了最旧的那一轮')
  assert.equal(view.droppedSteps, MAX_STEPS_PER_TURN)
  assert.equal(view.turns.length, turns - 1)
  assert.equal(view.turns.at(-1)?.turn, turns, '留下的是最近那一端')
  assert.equal(view.turns[0]?.turn, 2, '丢的是最旧那一轮')
})

test('上限：轮数超限时也从最旧的轮丢', async () => {
  const harnessed = await harness()
  const { session } = harnessed
  for (let turn = 1; turn <= MAX_TURNS + 1; turn += 1) {
    session.append('turn/start', { turn })
    session.append('step/start', { turn, step: 1 })
    session.append('turn/end', { turn, reason: { kind: 'completed' } })
  }

  const view = viewOf(harnessed)
  assert.equal(view.turns.length, MAX_TURNS)
  assert.equal(view.droppedTurns, 1)
  assert.equal(view.turns[0]?.turn, 2, '丢的是最旧那一轮')
})
