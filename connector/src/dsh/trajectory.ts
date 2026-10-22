/**
 * 轨迹投影（`trajectory`）：把**整条日志**折成"每轮 / 每步的起止"，
 * 随 `session.projections`（契约 §5.7）一次下发给手机。
 *
 * ## 为什么算在电脑侧，而不是手机拿事件自己算
 *
 * Web 的时间轴确实是**客户端现算**的：`ui-trajectory/src/client/layout.ts:145,166`
 * 的 `startedAt: finiteTime(node.time)`、`:190-196` 的工具调用起点
 * （`callStartById` 取 `tool/call` 的时刻）、`:471-503` 的工具段
 * （`startedAt: node.callTime` + `timeSeconds: durationSeconds(node.time, node.callTime)`）、
 * `trajectory-assistant-definition.ts:308-309` 的请求起止
 * （`startedAt: state.startTime` / `completedAt: node?.time`）。
 *
 * 但 Web 只算**已加载窗口**里的那些轮 —— 它的节点表来自分页。手机同理：
 * 条目表是分页来的，`turn/start` 落在更早一页时那一轮就没有起点，
 * 于是"用时"退化成"不到 1 秒"（`app/lib/data/projection.dart` 曾经就是这么算的，
 * 跨批即失真）。投影的 fold 跑在电脑侧的**完整日志**上，于是：
 *
 * - 窗口外的轮也有时间轴（手机不必先翻到那一页）；
 * - 每个数字只有一个来源，手机一个时间减法都不做。
 *
 * ## 与 Web 逐条对齐的口径
 *
 * | 这一段 | 起点 | 终点 | 出处 |
 * |---|---|---|---|
 * | 助手（一次模型请求） | `step/start` 的 time | `assistant/message` 的 time | `layout.ts:305-319`、`trajectory-assistant-definition.ts:308-309` |
 * | 工具（一次调用） | `tool/call` 的 time | `tool/result` 的 time | `layout.ts:493-494`、`trajectory-tool-definition.ts:52-73` |
 * | 压缩 | `compaction/start` 的 time | `compaction/end` 的 time | `layout.ts:382-385` |
 * | 一轮 | `turn/start` 的 time | `turn/end` 的 time | `packages/core/session/src/types.ts:289,298` |
 *
 * **进行中的段只留起点**（`endTime` / `durationMs` 为 `null`）—— 不虚构耗时，
 * 与 `ui-trajectory/README.zh.md` 的「已知限制」同一条。被边界（`step/end` /
 * `turn/end`）收口的未完成段按**被打断**收：`endTime` = 边界时刻、`isError: true`
 * （Web 的 `projectCall` 同样在边界处合成一条 `isError: true` 的结果，
 * `trajectory-tool-definition.ts:171-213`）。
 *
 * ## 字段语义（过线的形状）
 *
 * - `startTime` / `endTime`：毫秒 epoch。**只作记录**（排查与 tooltip），
 *   界面上的几何不读它们。
 * - `offsetMs`（仅步）：这一段相对**本轮开始**的偏移。x 轴位置 = `offsetMs / turn.durationMs`，
 *   于是手机连一次 epoch 相减都不需要。
 * - `durationMs`：**电脑侧算好的用时**（`endTime - startTime`）；`null` = 还在跑。
 *   界面上显示的每一个时长都读它，手机不做减法。
 * - `outcome`：`turn/end.reason.kind` 原样（`completed` / `aborted` / `error` /
 *   `interrupted` / `forked` / `blocked` / `max-tokens`，
 *   `packages/core/session/src/types.ts:202-233`）；`null` = 这一轮还没收口。
 * - `label`：**来源标识**，工具段 = 工具名；助手段与压缩段是空串
 *   （"模型" / "压缩"这类词属于界面，由手机给，不在数据面里编词）。
 * - `isError`：工具结果 `isError` / 被打断 / 压缩失败
 *   （Web 同处：`layout.ts:317` 的请求 `status === 'error'`、`:381` 的压缩失败）。
 *
 * ## 上限与 `truncated`
 *
 * 投影随 `session.projections` **整包**下发（几十 KB 起），所以状态必须有界。
 * 三个上限见 {@link MAX_TURNS} / {@link MAX_STEPS_PER_TURN} / {@link MAX_STEPS_TOTAL}；
 * 超了**从最旧的丢**（最近的才是用户要看的那一端），并把丢掉的量如实报出来：
 * `truncated`（有没有丢）、`droppedTurns` / `droppedSteps`（丢了多少）、
 * 每轮的 `stepsTruncated`（这一轮只留了最近的若干步）。
 * **不是静默截断**：手机据此在界面上明说被截断。
 *
 * ## 折叠的纯度与引用复用
 *
 * `apply` 必须同步且纯，不关心的事件返回**同一个引用**
 * （`packages/session/session-projection/src/index.ts:48-93`）。
 * 状态分成两层：`visible` 是过线的形状，其余是内部记账（还没收到结果的工具调用等）。
 * `wire.view` 直接返回 `state.visible`，于是**只动内部记账的那些事件不会触发发布**
 * （注册表按 `Object.is` 比较相邻两次 view 的结果，
 * `packages/session/session-projection/src/index.ts:686-701`）。
 *
 * @module dsh-mobile-connector/dsh/trajectory
 */
import { z } from 'zod'
import type { Context } from '@deepseek-ai/cordis'
import type { SessionEvent } from '@deepseek-ai/dsh-session'
import type { ProjectionDefinition } from '@deepseek-ai/dsh-session-projection'

/**
 * 把 `trajectory` 并进 DSH 的投影类型表
 * （`packages/session/session-projection/src/types.ts:17,24` 的可合并空表；
 * 包根与 `./types` 出口是同一张表，两处写哪一处都落在这张表上）。
 */
declare module '@deepseek-ai/dsh-session-projection' {
  interface SessionProjectionMap {
    trajectory: TrajectoryView
  }
  interface SessionProjectionStateMap {
    trajectory: TrajectoryState
  }
}

/**
 * 保留的最大轮数。
 *
 * 200 轮 × 每轮一条头部 ≈ 18 KB；正常会话远低于此（`memory.md` 记的
 * 会话规模标定：中位 21 事件/turn）。
 */
export const MAX_TURNS = 200

/**
 * 单轮保留的最大步数（超了留**最近**的若干步）。
 *
 * 一轮的步数 ≈ 模型请求次数 + 工具调用次数 —— 实测样本
 * （`Sequential Echo Shell Tool Calls`：一轮 60 次工具调用）约 120 步，
 * 所以 200 是"正常长轮不会被截"的量级。
 */
export const MAX_STEPS_PER_TURN = 200

/**
 * 全部保留步数的上限（超了**从最旧的轮整轮丢**）。
 *
 * 最坏情况 ≈ 1200 步 × ~90 B ≈ 110 KB，与 `session.projections` 现有的几十 KB 同量级；
 * 而单帧上限是 8 MiB（契约 §40），所以这层上限是为**响应体积**定的，不是为帧定的。
 */
export const MAX_STEPS_TOTAL = 1200

/** 一段的类别：一次模型请求 / 一次工具调用 / 一次上下文压缩。 */
export type TrajectoryStepKind = 'assistant' | 'tool' | 'compaction'

/** 时间轴上的一段。 */
export interface TrajectoryStep {
  readonly kind: TrajectoryStepKind
  /** 起点事件的会话修订号（`step/start` / `tool/call` / `compaction/start`）。 */
  readonly seq: number
  /** 起点时刻（毫秒 epoch）。 */
  readonly startTime: number
  /** 终点时刻；`null` = 还在跑（只画起点标记）。 */
  readonly endTime: number | null
  /**
   * 这一段相对**本轮开始**的偏移（毫秒，`startTime - turn.startTime`）。
   *
   * 手机画 x 轴只需要这一个数：位置 = `offsetMs / turn.durationMs`。
   * 不把 `startTime` 相减交给手机 —— 那条判据是硬的
   * （`app/lib/` 里不许出现 epoch 相减，见模块头）。
   */
  readonly offsetMs: number
  /** **电脑侧算好的**用时（毫秒）；`null` = 还在跑。 */
  readonly durationMs: number | null
  /** 这一段是失败 / 被打断收口的。 */
  readonly isError: boolean
  /** 来源标识：工具段 = 工具名，其余为空串。 */
  readonly label: string
}

/** 时间轴上的一轮。 */
export interface TrajectoryTurn {
  readonly turn: number
  /** 这一轮 `turn/start` 的会话修订号（与 `turnOutline` 的 `seq` 同一个锚点）。 */
  readonly startSeq: number
  readonly startTime: number
  /** `null` = 这一轮还在跑。 */
  readonly endTime: number | null
  /** **电脑侧算好的**这一轮用时（毫秒）；`null` = 还在跑。 */
  readonly durationMs: number | null
  /** `turn/end.reason.kind`；`null` = 还没收口。 */
  readonly outcome: string | null
  /** 这一轮的步数超过 {@link MAX_STEPS_PER_TURN}，只留了最近的若干步。 */
  readonly stepsTruncated: boolean
  readonly steps: TrajectoryStep[]
}

/** 过线的整包形状（`session.projections` 里 `trajectory` 这个键的值）。 */
export interface TrajectoryView {
  /** 按轮次升序。 */
  readonly turns: TrajectoryTurn[]
  /** 有轮或步因上限被丢。 */
  readonly truncated: boolean
  /** 因上限被整轮丢掉的轮数。 */
  readonly droppedTurns: number
  /** 因上限被丢掉的步数合计（含整轮丢掉的那些轮里的步）。 */
  readonly droppedSteps: number
}

/**
 * fold 的内部状态。
 *
 * `visible` 就是过线的形状，**引用即"可见内容有没有变"**：`wire.view` 直接返回它，
 * 于是只有内部记账变化的事件不会触发发布（见文件头）。
 */
export interface TrajectoryState {
  readonly visible: TrajectoryView
  /** 还没收到 `tool/result` 的调用：callId → 那条 `tool/call` 的 seq。 */
  readonly openCalls: Record<string, number>
  /** 还没 `compaction/end` 的压缩落在哪一轮、起点 seq（`turn: null` 的不进时间轴）。 */
  readonly openCompaction: { readonly turn: number; readonly seq: number } | null
  /** `visible` 里的步数合计（裁剪用，避免每次现数）。 */
  readonly stepCount: number
}

/** 工具名的过线上限：DSH 的工具名是短标识，超长只可能是畸形数据。 */
const LABEL_LIMIT = 64

const stepSchema: z.ZodType<TrajectoryStep> = z
  .object({
    kind: z.enum(['assistant', 'tool', 'compaction']),
    seq: z.number().int().nonnegative(),
    startTime: z.number().int().nonnegative(),
    endTime: z.number().int().nonnegative().nullable(),
    offsetMs: z.number().int().nonnegative(),
    durationMs: z.number().int().nonnegative().nullable(),
    isError: z.boolean(),
    label: z.string().max(LABEL_LIMIT),
  })
  .strict()

const turnSchema: z.ZodType<TrajectoryTurn> = z
  .object({
    turn: z.number().int().nonnegative(),
    startSeq: z.number().int().nonnegative(),
    startTime: z.number().int().nonnegative(),
    endTime: z.number().int().nonnegative().nullable(),
    durationMs: z.number().int().nonnegative().nullable(),
    outcome: z.string().nullable(),
    stepsTruncated: z.boolean(),
    steps: z.array(stepSchema),
  })
  .strict()

const viewSchema: z.ZodType<TrajectoryView> = z
  .object({
    turns: z.array(turnSchema),
    truncated: z.boolean(),
    droppedTurns: z.number().int().nonnegative(),
    droppedSteps: z.number().int().nonnegative(),
  })
  .strict()

const stateSchema: z.ZodType<TrajectoryState> = z
  .object({
    visible: viewSchema,
    openCalls: z.record(z.string(), z.number().int().nonnegative()),
    openCompaction: z
      .object({ turn: z.number().int().nonnegative(), seq: z.number().int().nonnegative() })
      .strict()
      .nullable(),
    stepCount: z.number().int().nonnegative(),
  })
  .strict()

const EMPTY_VIEW: TrajectoryView = {
  turns: [],
  truncated: false,
  droppedTurns: 0,
  droppedSteps: 0,
}

/** 空状态（共享同一个对象：本文件的 fold 从不改状态，只造新的）。 */
const EMPTY_STATE: TrajectoryState = {
  visible: EMPTY_VIEW,
  openCalls: {},
  openCompaction: null,
  stepCount: 0,
}

/** 一个可读的（也是可复用的）空状态。 */
export function emptyTrajectoryState(): TrajectoryState {
  return EMPTY_STATE
}

/**
 * 换掉某一轮的 `steps`，并同步 `stepCount`。
 *
 * **唯一改步数的地方** —— 记账只在这里发生，别处不会漂。
 */
function withSteps(
  state: TrajectoryState,
  turnIndex: number,
  steps: TrajectoryStep[],
  stepsTruncated: boolean,
): TrajectoryState {
  const previous = state.visible.turns[turnIndex]
  /* v8 ignore next -- 调用方都先用 indexOfTurn 定位过 */
  if (previous === undefined) return state
  const turns = state.visible.turns.slice()
  turns[turnIndex] = { ...previous, steps, stepsTruncated }
  return {
    ...state,
    visible: { ...state.visible, turns },
    stepCount: state.stepCount + steps.length - previous.steps.length,
  }
}

/** 换掉某一轮的若干字段（**不改步数** —— 改步数只能走 {@link withSteps}）。 */
function withTurn(
  state: TrajectoryState,
  turnIndex: number,
  patch: Partial<TrajectoryTurn>,
): TrajectoryState {
  const previous = state.visible.turns[turnIndex]
  /* v8 ignore next -- 调用方都先用 indexOfTurn 定位过 */
  if (previous === undefined) return state
  const turns = state.visible.turns.slice()
  turns[turnIndex] = { ...previous, ...patch }
  return { ...state, visible: { ...state.visible, turns } }
}

/** 轮次号 → 下标（找不到 = 这一轮的 `turn/start` 不在日志里）。 */
function indexOfTurn(turns: readonly TrajectoryTurn[], turn: number): number {
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    if (turns[index]?.turn === turn) return index
  }
  return -1
}

/** 步的 seq → 位置（`tool/result` 要靠它找回那条 `tool/call` 开的那一段）。 */
function locateStep(
  turns: readonly TrajectoryTurn[],
  seq: number,
): { turnIndex: number; stepIndex: number } | null {
  for (let turnIndex = turns.length - 1; turnIndex >= 0; turnIndex -= 1) {
    const steps = turns[turnIndex]?.steps ?? []
    for (let stepIndex = steps.length - 1; stepIndex >= 0; stepIndex -= 1) {
      if (steps[stepIndex]?.seq === seq) return { turnIndex, stepIndex }
    }
  }
  return null
}

/**
 * 把一轮里所有还没结束的段按 `at` 收口，标成被打断。
 *
 * 返回同一轮（没有要收的段时**同一个引用**，让调用方可以据此早退）。
 */
function closeOpenSteps(turn: TrajectoryTurn, at: number): TrajectoryTurn {
  if (!turn.steps.some((step) => step.endTime === null)) return turn
  return {
    ...turn,
    steps: turn.steps.map((step) =>
      step.endTime === null
        ? { ...step, endTime: at, durationMs: at - step.startTime, isError: true }
        : step,
    ),
  }
}

/**
 * 丢掉 `openCalls` 里已经不对应任何"还没结束的段"的条目。
 *
 * 被裁剪丢掉、或被边界收口的调用都会在这里出账；没有可丢的返回**同一引用**。
 */
function pruneOpenCalls(state: TrajectoryState): TrajectoryState {
  const live = new Set<number>()
  for (const turn of state.visible.turns) {
    for (const step of turn.steps) {
      if (step.endTime === null) live.add(step.seq)
    }
  }
  const keys = Object.keys(state.openCalls)
  const kept = keys.filter((callId) => live.has(state.openCalls[callId] ?? -1))
  if (kept.length === keys.length) return state
  const openCalls: Record<string, number> = {}
  for (const callId of kept) openCalls[callId] = state.openCalls[callId] ?? 0
  return { ...state, openCalls }
}

/** 丢掉最旧的一轮（连同它的步数一起记账）。 */
function dropOldestTurn(state: TrajectoryState): TrajectoryState {
  const oldest = state.visible.turns[0]
  /* v8 ignore next -- 调用方保证至少两轮 */
  if (oldest === undefined) return state
  return {
    ...state,
    visible: {
      ...state.visible,
      turns: state.visible.turns.slice(1),
      droppedTurns: state.visible.droppedTurns + 1,
      droppedSteps: state.visible.droppedSteps + oldest.steps.length,
    },
    stepCount: state.stepCount - oldest.steps.length,
  }
}

/**
 * 施加三个上限：单轮步数、总轮数、总步数。
 *
 * 都**从最旧的丢**（用户看的是最近那一端），并把丢掉的数量记进
 * `droppedTurns` / `droppedSteps` / 每轮的 `stepsTruncated`。
 * 但**至少留一轮**（刚写完的那一轮永远在，否则时间轴会整页空掉）。
 */
function trim(state: TrajectoryState, turnIndex: number): TrajectoryState {
  let next = state

  // 单轮：只留最近的 MAX_STEPS_PER_TURN 步。
  const current = next.visible.turns[turnIndex]
  if (current !== undefined && current.steps.length > MAX_STEPS_PER_TURN) {
    const dropped = current.steps.length - MAX_STEPS_PER_TURN
    next = withSteps(next, turnIndex, current.steps.slice(dropped), true)
    next = {
      ...next,
      visible: { ...next.visible, droppedSteps: next.visible.droppedSteps + dropped },
    }
  }

  // 轮数与总步数：整轮整轮地从最旧的丢。
  while (
    next.visible.turns.length > 1 &&
    (next.visible.turns.length > MAX_TURNS || next.stepCount > MAX_STEPS_TOTAL)
  ) {
    next = dropOldestTurn(next)
  }

  const truncated = next.visible.droppedTurns > 0 || next.visible.droppedSteps > 0
  if (truncated === next.visible.truncated) return next
  return { ...next, visible: { ...next.visible, truncated } }
}

/** `turn/start`：开一轮。 */
function startTurn(state: TrajectoryState, turn: number, seq: number, time: number): TrajectoryState {
  const lastIndex = state.visible.turns.length - 1
  const last = state.visible.turns[lastIndex]
  // 顺序守卫：轮次号不前进的边界（重放 / 重试）落回原来那条，别把时间轴搅乱。
  if (last !== undefined && turn <= last.turn) return state
  // 上一轮没收口就来了下一轮：按 DSH `repair.ts:96` 同一条口径补一个收口
  // （`reason.kind = 'interrupted'`，边界取下一轮的开始时刻）—— 否则上一轮
  // 会永远显示"进行中"，而"下一轮已经开始了"是日志里的事实。
  let base = state
  if (last !== undefined && last.endTime === null) {
    base = pruneOpenCalls(
      withTurn(closeTurnSteps(state, last.turn, time), lastIndex, {
        endTime: time,
        durationMs: time - last.startTime,
        outcome: 'interrupted',
      }),
    )
  }
  return {
    ...base,
    visible: {
      ...base.visible,
      turns: [
        ...base.visible.turns,
        {
          turn,
          startSeq: seq,
          startTime: time,
          endTime: null,
          durationMs: null,
          outcome: null,
          stepsTruncated: false,
          steps: [],
        },
      ],
    },
  }
}

/** `step/start`：开一段助手请求。 */
function startAssistantStep(
  state: TrajectoryState,
  turn: number,
  seq: number,
  time: number,
): TrajectoryState {
  const turnIndex = indexOfTurn(state.visible.turns, turn)
  if (turnIndex < 0) return state
  const current = state.visible.turns[turnIndex]
  /* v8 ignore next -- indexOfTurn 已保证存在 */
  if (current === undefined) return state
  // 同一段里再来一条 `step/start` 是重放，不是新段。
  if (current.steps.at(-1)?.endTime === null && current.steps.at(-1)?.kind === 'assistant') return state
  const steps = [...current.steps, step('assistant', seq, time, current.startTime, '')]
  return trim(withSteps(state, turnIndex, steps, current.stepsTruncated), turnIndex)
}

/** `assistant/message`：助手请求的终点。 */
function settleAssistantStep(
  state: TrajectoryState,
  turn: number,
  time: number,
  interrupted: boolean,
): TrajectoryState {
  const turnIndex = indexOfTurn(state.visible.turns, turn)
  if (turnIndex < 0) return state
  const current = state.visible.turns[turnIndex]
  /* v8 ignore next -- indexOfTurn 已保证存在 */
  if (current === undefined) return state
  const stepIndex = current.steps.findLastIndex(
    (candidate) => candidate.kind === 'assistant' && candidate.endTime === null,
  )
  // 没有开着的助手段 = 这一条 `assistant/message` 没有起点（`step/start` 不在日志里）。
  // **不凭空造一段零长度的**：没有区间就说没有区间（与"进行中只画起点"同一条纪律）。
  if (stepIndex < 0) return state
  const steps = current.steps.slice()
  const target = steps[stepIndex]
  /* v8 ignore next -- findLastIndex 已保证存在 */
  if (target === undefined) return state
  steps[stepIndex] = { ...target, endTime: time, durationMs: time - target.startTime, isError: interrupted }
  return withSteps(state, turnIndex, steps, current.stepsTruncated)
}

/** `tool/call`：开一段工具调用。 */
function startToolStep(
  state: TrajectoryState,
  turn: number,
  seq: number,
  time: number,
  callId: string,
  name: string,
): TrajectoryState {
  const turnIndex = indexOfTurn(state.visible.turns, turn)
  if (turnIndex < 0) return state
  const current = state.visible.turns[turnIndex]
  /* v8 ignore next -- indexOfTurn 已保证存在 */
  if (current === undefined) return state
  const steps = [
    ...current.steps,
    step('tool', seq, time, current.startTime, name.slice(0, LABEL_LIMIT)),
  ]
  const next = trim(withSteps(state, turnIndex, steps, current.stepsTruncated), turnIndex)
  return { ...next, openCalls: { ...next.openCalls, [callId]: seq } }
}

/** `tool/result`：工具调用的终点（按 callId 找回 `tool/call` 开的那一段）。 */
function settleToolStep(
  state: TrajectoryState,
  callId: string,
  time: number,
  isError: boolean,
): TrajectoryState {
  const seq = state.openCalls[callId]
  if (seq === undefined) return state
  // 先出账（无论那一段还在不在：被裁剪丢掉的调用也要清掉记账，否则表会涨）。
  const openCalls = { ...state.openCalls }
  delete openCalls[callId]
  const withoutCall: TrajectoryState = { ...state, openCalls }
  const located = locateStep(state.visible.turns, seq)
  if (located === null) return withoutCall
  const current = state.visible.turns[located.turnIndex]
  /* v8 ignore next -- locateStep 已保证存在 */
  if (current === undefined) return withoutCall
  const steps = current.steps.slice()
  const target = steps[located.stepIndex]
  /* v8 ignore next -- locateStep 已保证存在 */
  if (target === undefined) return withoutCall
  steps[located.stepIndex] = { ...target, endTime: time, durationMs: time - target.startTime, isError }
  return withSteps(withoutCall, located.turnIndex, steps, current.stepsTruncated)
}

/** `step/end`：这一步（一次模型调用 + 它请求的工具）收口。 */
function closeTurnSteps(state: TrajectoryState, turn: number, at: number): TrajectoryState {
  const turnIndex = indexOfTurn(state.visible.turns, turn)
  if (turnIndex < 0) return state
  const current = state.visible.turns[turnIndex]
  /* v8 ignore next -- indexOfTurn 已保证存在 */
  if (current === undefined) return state
  const closed = closeOpenSteps(current, at)
  if (closed === current) return state
  return pruneOpenCalls(withTurn(state, turnIndex, { steps: closed.steps }))
}

/** `turn/end`：收一轮。 */
function endTurn(
  state: TrajectoryState,
  turn: number,
  time: number,
  outcome: string,
): TrajectoryState {
  const turnIndex = indexOfTurn(state.visible.turns, turn)
  if (turnIndex < 0) return state
  const current = state.visible.turns[turnIndex]
  /* v8 ignore next -- indexOfTurn 已保证存在 */
  if (current === undefined) return state
  // 重复的 `turn/end`（重放）不再改任何东西。
  if (current.endTime !== null) return state
  const closed = closeOpenSteps(current, time)
  const next = withTurn(state, turnIndex, {
    steps: closed.steps,
    endTime: time,
    durationMs: time - current.startTime,
    outcome,
  })
  return pruneOpenCalls(next)
}

/**
 * `compaction/*`：上下文压缩。
 *
 * `turn: null`（轮次之间的手动压缩，`packages/compaction/compaction/src/types.ts:24`）
 * **不进时间轴** —— 轨迹页的每一行都挂在轮次号上（`turnOutline` 给的），
 * 一个不属于任何一轮的段没有能画它的 x 轴。这是一处如实记下的缺口。
 */
function applyCompaction(
  state: TrajectoryState,
  type: string,
  seq: number,
  time: number,
  data: unknown,
): TrajectoryState {
  const record = asRecord(data)
  const turn = record?.['turn']
  if (type === 'compaction/start') {
    if (typeof turn !== 'number' || !Number.isInteger(turn)) return state
    const turnIndex = indexOfTurn(state.visible.turns, turn)
    if (turnIndex < 0) return state
    const current = state.visible.turns[turnIndex]
    /* v8 ignore next -- indexOfTurn 已保证存在 */
    if (current === undefined) return state
    const steps = [...current.steps, step('compaction', seq, time, current.startTime, '')]
    const next = trim(withSteps(state, turnIndex, steps, current.stepsTruncated), turnIndex)
    return { ...next, openCompaction: { turn, seq } }
  }
  if (type === 'compaction/end') {
    const open = state.openCompaction
    if (open === null) return state
    const located = locateStep(state.visible.turns, open.seq)
    const withoutCompaction: TrajectoryState = { ...state, openCompaction: null }
    if (located === null) return withoutCompaction
    const current = state.visible.turns[located.turnIndex]
    /* v8 ignore next -- locateStep 已保证存在 */
    if (current === undefined) return withoutCompaction
    const steps = current.steps.slice()
    const target = steps[located.stepIndex]
    /* v8 ignore next -- locateStep 已保证存在 */
    if (target === undefined) return withoutCompaction
    steps[located.stepIndex] = {
      ...target,
      endTime: time,
      durationMs: time - target.startTime,
      isError: record?.['error'] !== undefined,
    }
    return withSteps(withoutCompaction, located.turnIndex, steps, current.stepsTruncated)
  }
  // `compaction/summary` / `compaction/prune`：只带内容与影子价，不带时间语义。
  return state
}

function step(
  kind: TrajectoryStepKind,
  seq: number,
  startTime: number,
  turnStartTime: number,
  label: string,
): TrajectoryStep {
  return {
    kind,
    seq,
    startTime,
    endTime: null,
    // 偏移在**电脑侧**算好（见 `TrajectoryStep.offsetMs`）。
    offsetMs: startTime - turnStartTime,
    durationMs: null,
    isError: false,
    label,
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : null
}

/**
 * 纯折叠：前一个状态 + 一条已提交事件 → 下一个状态。
 *
 * **不关心的事件返回同一个引用**（`Object.is` 是下游的工作闸）。
 */
function apply(state: TrajectoryState, event: SessionEvent): TrajectoryState {
  switch (event.type) {
    case 'turn/start':
      return startTurn(state, event.data.turn, event.seq, event.time)
    case 'turn/end':
      return endTurn(state, event.data.turn, event.time, event.data.reason.kind)
    case 'step/start':
      return startAssistantStep(state, event.data.turn, event.seq, event.time)
    case 'step/end':
      return closeTurnSteps(state, event.data.turn, event.time)
    case 'assistant/message':
      return settleAssistantStep(state, event.data.turn, event.time, event.data.interrupted === true)
    case 'tool/call':
      return startToolStep(
        state,
        event.data.turn,
        event.seq,
        event.time,
        String(event.data.callId),
        event.data.name,
      )
    case 'tool/result':
      return settleToolStep(
        state,
        String(event.data.message.source.callId),
        event.time,
        event.data.message.isError === true || event.data.error !== undefined,
      )
    default:
      // 事件表是可被插件合并扩展的（`compaction/*` 就是 `@deepseek-ai/dsh-compaction`
      // 并进 `SessionEventMap` 的），所以这里按类型字符串再分派一次。
      // **不认识的类型就是"不关心"** —— 契约要求返回同一引用，不是兜底。
      return applyCompaction(state, event.type as string, event.seq, event.time, event.data)
  }
}

/** `trajectory` 这个键的投影定义（导出是为了让单测直接折它）。 */
export const trajectoryProjectionDefinition = {
  key: 'trajectory',
  stateVersion: 1,
  stateSchema,
  init: () => EMPTY_STATE,
  apply,
  wire: {
    viewSchema,
    // **返回状态里的那一个引用**（不是每次现造一个对象）：只有 `visible` 变了
    // 才该触发发布，否则每折一条内部记账事件都会发一次。
    view: (state: TrajectoryState) => state.visible,
  },
} satisfies ProjectionDefinition<'trajectory', TrajectoryState>

/**
 * 把 `trajectory` 注册进宿主的投影表（**可选能力**）。
 *
 * 注册是 effect（随调用方 fiber 卸载消失，
 * `packages/session/session-projection/src/index.ts:181-291`），所以走
 * `ctx.inject(['sessionProjections'], ...)` —— 服务不在时**什么都不发生**
 * （没有日志、没有报错）：那是"这台电脑没给时间轴"这一条能力缺失，
 * 手机侧按缺键显示，而不是让插件挂载失败。
 *
 * 注册失败（`register` 对 `stateVersion` 有硬校验，见
 * `packages/session/session-projection/src/index.ts:270-272`）要**大声抛**：
 * 一个静默没注册上的投影，在手机上与"这台电脑没给时间轴"长得一模一样。
 */
export function registerTrajectoryProjection(ctx: Context): void {
  ctx.inject(['sessionProjections'], (projectionCtx: Context) => {
    projectionCtx.sessionProjections.register(trajectoryProjectionDefinition)
  })
}
