/**
 * `src/interaction-face.ts` 的单测：提问投影、`interaction.respond` 路由、审批看护。
 *
 * 为什么这些用例值得写：这个内核的每一条分支都对应一个**已经发生过或即将发生的事故** ——
 * 提问已结束时的崩溃、重复应答造出第二条用户消息、看护漏一个定时器、审批在无人看护时
 * 被无限挂起。而它可测的前提是依赖全部注入：这里没有一个 DSH 替身，只有假时钟、假投影
 * 与会记录调用的假 `answer`。
 *
 * 三条被钉住的语义：
 * 1. **答案批次原样透传**，连接器不翻译（§6.3.1：翻译层就是漂移层）；
 * 2. **提问已结束不是崩溃**，而是 `interaction/not-pending` → 刷新待处理列表（§3.1 / §6.3.1）；
 * 3. **看护只放行人类的回答**：超时 / 断开 / 会话被替换一律 fail-closed 并留证（§6.2）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  createInteractionFace,
  createWatchdog,
  DEFAULT_APPROVAL_GUARD_MS,
  projectPendingQuestions,
  registerApprovalAnswerer,
  validateAnswerBatch,
  type ApprovalAsk,
  type ApprovalAnswerer,
  type ApprovalDecision,
  type ApprovalOutcome,
  type ApprovalRegistry,
  type AnswerItem,
  type InteractionLogger,
  type PendingItem,
  type Question,
  type QuestionAgent,
  type QuestionProjection,
  type UnhandledApproval,
} from '../src/interaction-face.js'
import { clientActionOf, ProtocolError } from '../src/protocol/errors.js'
import type { TakeoverDevice, TakeoverMode } from '../src/protocol/takeover.js'

// ---------------------------------------------------------------------------
// 假件
// ---------------------------------------------------------------------------

/** DSH `UserQuestionError` 的形状替身：只带内核要分支的 `code`（`user-questions/src/index.ts:46-51`）。 */
function questionError(code: string, message: string): Error & { code: string } {
  return Object.assign(new Error(message), { code })
}

/**
 * 假时钟。计时器由被测代码经注入的 `schedule` 登记，测试用 `advance` **同步**推进 ——
 * 于是"等 10 分钟"是一行数字，不是一次真等待。
 */
function fakeClock(start = 1_700_000_000_000) {
  let now = start
  let seq = 0
  const timers = new Map<number, { at: number; fn: () => void }>()
  return {
    now: () => now,
    schedule(fn: () => void, ms: number) {
      seq += 1
      // id 必须取值为常量：闭包捕获可变 `seq` 会让先注册的取消函数删掉后一个计时器
      const id = seq
      timers.set(id, { at: now + ms, fn })
      return () => {
        timers.delete(id)
      }
    },
    advance(ms: number) {
      now += ms
      for (const [id, timer] of [...timers]) {
        if (timer.at <= now) {
          timers.delete(id)
          timer.fn()
        }
      }
    },
    /** 还挂着的计时器个数：收束后必须归零，否则每次 claim 漏一个定时器。 */
    pending: () => timers.size,
  }
}

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

/** 取出被测函数抛出的协议错误（断言值来自真实抛出，不在测试里重写一遍实现）。 */
function protocolErrorOf(fn: () => unknown): ProtocolError {
  try {
    fn()
  } catch (error) {
    assert.ok(
      error instanceof ProtocolError,
      `抛出的应当是 ProtocolError（码来自封闭表），实际是 ${String(error)}`,
    )
    return error
  }
  assert.fail('这个载荷本应当被拒绝')
}

const TWO_QUESTIONS: readonly Question[] = [
  { id: 'scope', question: '授权范围？', options: [{ label: 'Tool only' }, { label: '全部' }] },
  { id: 'mode', question: '模式？', options: [{ label: 'plan' }], multiSelect: true },
]

const CONTINUED_VIEW: QuestionProjection = {
  active: [{ callId: 'call-1', questions: TWO_QUESTIONS, state: 'continued' }],
  settled: [],
}

const LIVE_AGENT: QuestionAgent = { __dshLiveRootAgent: 'branded' }

interface AnswerScript {
  returns?: boolean
  throws?: Error
}

function setupFace(options: {
  projection?: QuestionProjection
  script?: AnswerScript
  /** `false` = 没有 live root agent（子代理里的提问 / 会话被替换）。 */
  liveAgent?: boolean
  warnings?: string[]
} = {}) {
  const calls: { agent: unknown; callId: string; batch: unknown }[] = []
  const log: InteractionLogger | undefined =
    options.warnings === undefined
      ? undefined
      : { warn: (message, detail) => options.warnings?.push(`${message}｜${JSON.stringify(detail)}`) }
  const face = createInteractionFace({
    agentOf: (sid) => (sid === 'sid_1' && options.liveAgent !== false ? LIVE_AGENT : undefined),
    projectionOf: (sid) => (sid === 'sid_1' ? options.projection : undefined),
    answer: (agent, callId, batch) => {
      calls.push({ agent, callId, batch })
      if (options.script?.throws !== undefined) throw options.script.throws
      return options.script?.returns ?? true
    },
    ...(log === undefined ? {} : { log }),
  })
  return { face, calls }
}

function respondParams(patch: Record<string, unknown> = {}) {
  return {
    sid: 'sid_1',
    callId: 'call-1',
    answers: [
      { id: 'scope', selected: ['Tool only'] },
      { id: 'mode', selected: ['plan'] },
    ],
    ...patch,
  }
}

// ---------------------------------------------------------------------------
// 待处理投影
// ---------------------------------------------------------------------------

test('待处理投影：itemId = i:<callId>、问题与 state 原样带上；已答的不进集合（§6.3）', () => {
  const items: readonly PendingItem[] = projectPendingQuestions('sid_1', {
    active: [
      { callId: 'call-1', questions: TWO_QUESTIONS, state: 'continued' },
      { callId: 'call-2', questions: [TWO_QUESTIONS[0]!], state: 'open' },
    ],
    // 已答完的 call 只在 settled 半边：它不再是待处理项
    settled: [{ callId: 'call-0', answers: [] }],
  })

  assert.equal(items.length, 2, 'settled 半边不进待处理集合')
  assert.deepEqual(
    items[0],
    {
      itemId: 'i:call-1',
      sid: 'sid_1',
      callId: 'call-1',
      questions: TWO_QUESTIONS,
      state: 'continued',
    },
    'state 原样透传：内核不替手机判灰（§6.4 把置灰判据留给手机）',
  )
  assert.equal(items[1]?.state, 'open')
})

test('投影来源缺失（没投影快照 / 不认识的 sid）时是空列表，不是错误', () => {
  const { face } = setupFace({ projection: CONTINUED_VIEW })
  assert.deepEqual(
    face.pendingOf('sid_1').map((item) => item.itemId),
    ['i:call-1'],
  )
  assert.deepEqual(face.pendingOf('sid_unknown'), [], '没有投影 = 当前没有待处理提问')
})

// ---------------------------------------------------------------------------
// 批次形状校验
// ---------------------------------------------------------------------------

test('批次缺一项：两个问题只答一个 → interaction/not-pending，且不打扰 DSH', () => {
  const { face, calls } = setupFace({ projection: CONTINUED_VIEW })

  const error = protocolErrorOf(() =>
    face.respond(respondParams({ answers: [{ id: 'scope', selected: ['Tool only'] }] })),
  )
  assert.equal(error.code, 'interaction/not-pending')
  assert.equal(
    clientActionOf(error.code),
    'refresh-pending',
    '批次与提问对不上 = 手机侧的待处理视图过期，刷新即可恢复（客户端行为由封闭表推导）',
  )
  assert.deepEqual(calls, [], '本地就能判出来的畸形批次不该推到 DSH')
})

test('批次缺一项时留一声：待处理视图过期需要能被诊断出来', () => {
  const warnings: string[] = []
  const { face } = setupFace({ projection: CONTINUED_VIEW, warnings })

  protocolErrorOf(() => face.respond(respondParams({ answers: [{ id: 'scope', selected: [] }] })))
  assert.equal(warnings.length, 1)
  assert.match(warnings[0] ?? '', /对不上/)
})

test('批次多项：同一个问题答两次 → interaction/not-pending（DSH 的 BAD_ANSWER 同形，:178-185）', () => {
  const { face, calls } = setupFace({ projection: CONTINUED_VIEW })

  const error = protocolErrorOf(() =>
    face.respond(
      respondParams({
        answers: [
          { id: 'scope', selected: ['Tool only'] },
          { id: 'scope', selected: ['全部'] },
          { id: 'mode', selected: ['plan'] },
        ],
      }),
    ),
  )
  assert.equal(error.code, 'interaction/not-pending')
  assert.deepEqual(calls, [])
})

test('批次带未知问题：项数对得上但名字对不上 → interaction/not-pending', () => {
  const { face } = setupFace({ projection: CONTINUED_VIEW })

  const error = protocolErrorOf(() =>
    face.respond(
      respondParams({
        answers: [
          { id: 'scope', selected: ['Tool only'] },
          { id: 'not-a-question', selected: ['x'] },
        ],
      }),
    ),
  )
  assert.equal(error.code, 'interaction/not-pending')
})

test('空批次：一个问题都没命名 → interaction/not-pending（DSH 同样抛 BAD_ANSWER）', () => {
  const { face } = setupFace({ projection: CONTINUED_VIEW })

  assert.equal(
    protocolErrorOf(() => face.respond(respondParams({ answers: [] }))).code,
    'interaction/not-pending',
  )
})

test('空答案：selected 为空且无 custom 是 DSH 的「显式跳过」，原样转发不拦截', () => {
  // 依据：`packages/interaction/tool-ask-user/src/timed.ts:172-181` 的输出 schema 原文
  // "Empty with no custom means the user explicitly skipped this question"；
  // `packages/interaction/user-questions/tests/user-questions.spec.ts:880` 用
  // `{ answers: [{ id: 'scope', selected: [] }] }` 断言 `answer()` 返回 true。
  // 连接器若在这里加一条"至少选一个"的检查，就是把合法跳过变成失败 —— 自造 DSH 没有的规则。
  const { face, calls } = setupFace({ projection: CONTINUED_VIEW })
  const answers: readonly AnswerItem[] = [
    { id: 'scope', selected: ['Tool only'], custom: '只要读' },
    { id: 'mode', selected: [] },
  ]

  assert.deepEqual(face.respond(respondParams({ answers })), { itemId: 'i:call-1' })
  assert.equal(calls.length, 1)
  assert.deepEqual(calls[0]?.batch, { answers }, '答案批次原样透传：翻译层就是漂移层（§6.3.1）')
})

test('形状不合法 → protocol/bad-frame：answers 不是数组 / 项缺 id / selected 不是字符串数组 / 缺 sid', () => {
  // 契约 §5.7 对 `sid` 立过同一条规则："缺失或形状不对 → protocol/bad-frame，
  // 它是请求本身不合法，不是数据不存在"。这里把它同理推到批次上。
  const { face, calls } = setupFace({ projection: CONTINUED_VIEW })

  assert.equal(
    protocolErrorOf(() => face.respond(respondParams({ answers: 'nope' }))).code,
    'protocol/bad-frame',
  )
  assert.equal(
    protocolErrorOf(() => face.respond(respondParams({ answers: [{ selected: ['x'] }] }))).code,
    'protocol/bad-frame',
    '缺 id 的项连"答的是哪个问题"都说不出来',
  )
  assert.equal(
    protocolErrorOf(() =>
      face.respond(
        respondParams({ answers: [{ id: 'scope', selected: [1] }, { id: 'mode', selected: [] }] }),
      ),
    ).code,
    'protocol/bad-frame',
    'selected 必须是字符串数组（选项标签）',
  )
  assert.equal(
    protocolErrorOf(() => face.respond({ callId: 'call-1', answers: [] })).code,
    'protocol/bad-frame',
    '缺 sid',
  )
  assert.deepEqual(calls, [], '形状不合法时一个都不该进到 DSH')
})

test('validateAnswerBatch：缺项 / 多项 / 未知项各返回一句理由，合法批次返回 null', () => {
  assert.equal(
    validateAnswerBatch(TWO_QUESTIONS, [{ id: 'scope', selected: [] }]),
    '批次有 1 项，而这个提问有 2 个问题',
  )
  assert.match(
    validateAnswerBatch(TWO_QUESTIONS, [
      { id: 'scope', selected: [] },
      { id: 'scope', selected: [] },
    ]) ?? '',
    /多次/,
  )
  assert.match(
    validateAnswerBatch(TWO_QUESTIONS, [
      { id: 'scope', selected: [] },
      { id: 'ghost', selected: [] },
    ]) ?? '',
    /没被答到/,
  )
  assert.equal(
    validateAnswerBatch(TWO_QUESTIONS, [
      { id: 'scope', selected: [] },
      { id: 'mode', selected: ['plan'] },
    ]),
    null,
    '跳过（空 selected）也是合法答案',
  )
})

// ---------------------------------------------------------------------------
// 应答路由
// ---------------------------------------------------------------------------

test('提问已结束：answer 返回 false → interaction/not-pending，不是崩溃（:168）', () => {
  const { face, calls } = setupFace({ projection: CONTINUED_VIEW, script: { returns: false } })

  const error = protocolErrorOf(() => face.respond(respondParams()))
  assert.equal(error.code, 'interaction/not-pending')
  assert.equal(
    clientActionOf(error.code),
    'refresh-pending',
    '手机据此把那一项标成"已过期"并刷新列表，不弹错误框（§6.3.1）',
  )
  assert.equal(calls.length, 1, '判定权在 DSH：连接器照样把批次交给它')
})

test('REPLY_QUEUED → interaction/not-pending（幂等键 I8 的兜底）', () => {
  // 已排队再答抛 REPLY_QUEUED（:172-174）。正常路径上断线重发该被去重表拦下；
  // 真到这里时，刷新待处理列表就是恢复动作 —— 那一项会随排队回复落定而自己消失。
  const { face } = setupFace({
    projection: CONTINUED_VIEW,
    script: { throws: questionError('REPLY_QUEUED', 'a reply is already queued for this question') },
  })

  const error = protocolErrorOf(() => face.respond(respondParams()))
  assert.equal(error.code, 'interaction/not-pending')
  assert.match(error.message, /排队/)
})

test('BAD_ANSWER（投影不认识这个 call 时由 DSH 自己抛）→ interaction/not-pending', () => {
  // 投影缺这个 call 时内核跳过本地校验、照样问 DSH（I1：DSH 是自己的权威）。
  // 于是 DSH 的 BAD_ANSWER 仍要落到同一个客户端行为上。
  const { face } = setupFace({
    projection: { active: [], settled: [] },
    script: { throws: questionError('BAD_ANSWER', 'must name each question exactly once') },
  })

  assert.equal(protocolErrorOf(() => face.respond(respondParams())).code, 'interaction/not-pending')
})

test('CALLER_NOT_LIVE / DELEGATED_CALLER → interaction/not-pending（子代理里的提问答不了，§15）', () => {
  for (const code of ['CALLER_NOT_LIVE', 'DELEGATED_CALLER']) {
    const { face } = setupFace({
      projection: CONTINUED_VIEW,
      script: { throws: questionError(code, 'human interaction requires the exact live calling agent') },
    })
    assert.equal(
      protocolErrorOf(() => face.respond(respondParams())).code,
      'interaction/not-pending',
      `${code}：没有 live root agent 可答`,
    )
  }
})

test('没有 live root agent（agentOf 返回 undefined）→ interaction/not-pending，且不调用 answer', () => {
  const { face, calls } = setupFace({ projection: CONTINUED_VIEW, liveAgent: false })

  const error = protocolErrorOf(() => face.respond(respondParams()))
  assert.equal(error.code, 'interaction/not-pending')
  assert.deepEqual(calls, [], '拿不到 agent 就调不了 DSH：这一项不属于本设备')
})

test('未知错误（steer 抛错）原样上交：吞掉它会让手机以为答成功了', () => {
  // `answer()` 内部 steer 失败时会清理排队记录并原样抛（:199-204），答案从未进入会话。
  // 归一成 ProtocolError 会给它一个客户端动作，那是撒谎；交给分发器归 internal → 退避重试。
  const { face } = setupFace({
    projection: CONTINUED_VIEW,
    script: { throws: new Error('steer failed') },
  })

  try {
    face.respond(respondParams())
    assert.fail('未知错误必须原样抛出')
  } catch (error) {
    assert.ok(!(error instanceof ProtocolError), '未知错误必须原样上交，不套协议错误的外壳')
    assert.match((error as Error).message, /steer failed/)
  }
})

// ---------------------------------------------------------------------------
// 看护计时器
// ---------------------------------------------------------------------------

test('看护超时 → 未处理记录；默认上限由行为导出（差 1 ms 不收束，不真等 10 分钟）', async () => {
  const clock = fakeClock()
  const watchdog = createWatchdog({ now: clock.now, schedule: clock.schedule })
  const settled = watchdog.awaitAnswer(() => new Promise<never>(() => {}))

  clock.advance(DEFAULT_APPROVAL_GUARD_MS - 1)
  assert.equal(watchdog.settled, null, '差 1 ms 也不收束：提前收束会 fail-closed 掉"再看一眼手机"的用户')
  clock.advance(1)

  const settlement = await settled
  assert.equal(settlement.record.end, 'timeout')
  assert.equal(settlement.record.unhandled, true, '没等到人类的回答 = 未处理')
  assert.equal(settlement.record.at, clock.now())
  assert.equal(settlement.value, undefined)
  assert.equal(clock.pending(), 0, '收束后计时器必须取消，否则每次 claim 漏一个定时器')
})

test('guardMs 可配：500 ms 的看护在第 500 ms 才收束', async () => {
  const clock = fakeClock()
  const watchdog = createWatchdog({ guardMs: 500, now: clock.now, schedule: clock.schedule })
  const settled = watchdog.awaitAnswer(() => new Promise<never>(() => {}))

  clock.advance(499)
  assert.equal(watchdog.settled, null)
  clock.advance(1)
  assert.equal((await settled).record.end, 'timeout')
})

test('手机断开 → 未处理记录，且计时器被取消（不泄漏）', async () => {
  const clock = fakeClock()
  const watchdog = createWatchdog({ now: clock.now, schedule: clock.schedule })
  const settled = watchdog.awaitAnswer(() => new Promise<never>(() => {}))

  watchdog.disconnect()
  const settlement = await settled
  assert.equal(settlement.record.end, 'disconnected')
  assert.equal(settlement.record.unhandled, true)
  assert.equal(clock.pending(), 0)
})

test('会话被替换 → 未处理记录（别名映射指向了另一个会话）', async () => {
  const clock = fakeClock()
  const watchdog = createWatchdog({ now: clock.now, schedule: clock.schedule })
  const settled = watchdog.awaitAnswer(() => new Promise<never>(() => {}))

  watchdog.replace()
  assert.equal((await settled).record.end, 'replaced')
})

test('答完之后迟到事件被丢弃：只收束一次（DSH :303 的"late answer is discarded"同构）', async () => {
  const clock = fakeClock()
  const watchdog = createWatchdog({ now: clock.now, schedule: clock.schedule })
  const answer = deferred<ApprovalDecision>()
  const settled = watchdog.awaitAnswer(() => answer.promise)

  answer.resolve('allow-once')
  const first = await settled
  assert.equal(first.record.end, 'answered')
  assert.equal(first.value, 'allow-once')

  // 之后无论再来什么，都改变不了已收束的结局
  watchdog.disconnect()
  clock.advance(DEFAULT_APPROVAL_GUARD_MS)
  assert.equal(watchdog.settled?.end, 'answered', '迟到事件被丢弃：绝不把已放行的请求翻成 fail-closed')
})

test('推答端口 reject（或同步抛错）→ disconnected：不再细分原因，一律 fail-closed', async () => {
  const clock = fakeClock()
  const rejected = createWatchdog({ now: clock.now, schedule: clock.schedule })
  const thrown = createWatchdog({ now: clock.now, schedule: clock.schedule })

  const a = rejected.awaitAnswer(() => Promise.reject(new Error('socket closed')))
  const b = thrown.awaitAnswer(() => {
    throw new Error('设备那一下就断了')
  })

  assert.equal((await a).record.end, 'disconnected')
  assert.equal((await b).record.end, 'disconnected', '同步抛错不能从 awaitAnswer 逃出去变成 rejected promise')
  assert.equal(clock.pending(), 0)
})

test('awaitAnswer 二次调用抛错：一个 claim 只看护一次', () => {
  const clock = fakeClock()
  const watchdog = createWatchdog({ now: clock.now, schedule: clock.schedule })
  watchdog.awaitAnswer(() => new Promise<never>(() => {}))
  assert.throws(() => watchdog.awaitAnswer(() => new Promise<never>(() => {})), /一个 claim 只能看护一次/)
})

// ---------------------------------------------------------------------------
// 审批应答者
// ---------------------------------------------------------------------------

/** 桌面哨兵：证明这条请求被交还了桌面（不是任何真实 outcome）。 */
const FROM_DESKTOP = 'from-desktop' as unknown as ApprovalOutcome

function setupApproval(options: {
  mode?: TakeoverMode
  devices?: readonly TakeoverDevice[]
  /** `false` = 这个会话没登记给手机（`sidOf` 返回 undefined）。 */
  registered?: boolean
  decision?: ApprovalDecision
  askThrows?: Error
  /** 挂起不决定（看护用例用）。 */
  hang?: boolean
  guardMs?: number
} = {}) {
  const clock = fakeClock()
  const asks: { ask: ApprovalAsk; deviceId: string }[] = []
  const unhandled: UnhandledApproval[] = []
  const warnings: string[] = []
  let handler: ApprovalAnswerer | undefined
  let disposals = 0
  const registry: ApprovalRegistry = {
    on(_event, answerer) {
      handler = answerer
      return () => {
        disposals += 1
      }
    },
  }

  const off = registerApprovalAnswerer(registry, {
    takeover: {
      mode: () => options.mode ?? 'foreground',
      devices: () =>
        options.devices ?? [{ id: 'dev-A', online: true, foreground: true, subscribed: ['sid_1'], pairedAt: 1 }],
      sidOf: () => (options.registered === false ? undefined : 'sid_1'),
    },
    askApproval: (ask, deviceId) => {
      asks.push({ ask, deviceId })
      if (options.askThrows !== undefined) throw options.askThrows
      return options.hang === true
        ? new Promise<ApprovalDecision>(() => {})
        : Promise.resolve(options.decision ?? 'allow-once')
    },
    onUnhandled: (record) => {
      unhandled.push(record)
    },
    ...(options.guardMs === undefined ? {} : { guardMs: options.guardMs }),
    now: clock.now,
    schedule: clock.schedule,
    log: {
      warn: (message, detail) => {
        warnings.push(detail === undefined ? message : `${message}｜${JSON.stringify(detail)}`)
      },
    },
  })

  const run = async (patch: Partial<ApprovalAsk> = {}) => {
    const answerer = handler
    assert.ok(answerer !== undefined, 'registerApprovalAnswerer 应当注册 approval/request')
    let delegated = 0
    const outcome = await answerer(
      { dshSessionId: 'dsh-1', callId: 'call-1', toolName: 'bash', ...patch },
      () => {
        delegated += 1
        return Promise.resolve(FROM_DESKTOP)
      },
    )
    return { outcome, delegated }
  }

  return { run, asks, unhandled, warnings, clock, disposals: () => disposals, off }
}

const APPROVAL_ASK: ApprovalAsk = { dshSessionId: 'dsh-1', callId: 'call-1', toolName: 'bash' }

test('不接管的三种情形都 next()：会话未登记 / 没有 callId / 档位 never', async () => {
  const unknown = setupApproval({ registered: false })
  assert.equal((await unknown.run()).outcome, FROM_DESKTOP, '会话没登记给手机 → 交还桌面')
  assert.deepEqual(unknown.asks, [])

  const noCall = setupApproval()
  assert.equal((await noCall.run({ callId: undefined })).outcome, FROM_DESKTOP, '没有 callId 就没有稳定身份')
  assert.deepEqual(noCall.asks, [])

  const never = setupApproval({ mode: 'never' })
  assert.equal((await never.run()).outcome, FROM_DESKTOP, '档位 never：审批仍在桌面答（§6.2）')
  assert.deepEqual(never.asks, [], '不接管时绝不打扰手机')
})

test('foreground 档（默认）：前台且订阅才 claim；不同时满足就 next()', async () => {
  // §6.2 的机械判据：`foreground` 档要求「前台 且 已订阅该 sid」。
  // 默认取这一档的理由是不改变桌面既有行为 —— 用户离开手机时审批照常在电脑上弹。
  const claimed = setupApproval()
  assert.equal((await claimed.run()).delegated, 0, '前台且订阅 → claim')
  assert.deepEqual(
    claimed.asks.map((entry) => entry.deviceId),
    ['dev-A'],
  )

  for (const [name, device] of [
    ['不在前台', { id: 'dev-B', online: true, foreground: false, subscribed: ['sid_1'], pairedAt: 1 }],
    ['没订阅这个会话', { id: 'dev-C', online: true, foreground: true, subscribed: [], pairedAt: 1 }],
    ['不在线', { id: 'dev-D', online: false, foreground: true, subscribed: ['sid_1'], pairedAt: 1 }],
  ] as const) {
    const setup = setupApproval({ devices: [device] })
    assert.equal((await setup.run()).outcome, FROM_DESKTOP, `${name} → 交还桌面`)
    assert.deepEqual(setup.asks, [], `${name}：不接管时绝不打扰手机`)
  }
})

test('always 档：在线即接管；多设备并列取最近交互的那台（确定性排序）', async () => {
  const setup = setupApproval({
    mode: 'always',
    devices: [
      { id: 'dev-A', online: true, foreground: false, subscribed: [], pairedAt: 1, lastInteractedAt: { sid_1: 500 } },
      { id: 'dev-B', online: true, foreground: true, subscribed: ['sid_1'], pairedAt: 2 },
      { id: 'dev-C', online: false, foreground: true, subscribed: ['sid_1'], pairedAt: 3 },
    ],
  })

  await setup.run()
  assert.deepEqual(
    setup.asks.map((entry) => entry.deviceId),
    ['dev-A'],
    '离线设备直接出局；并列时取最近与该会话交互过的（排序规则在 protocol/takeover.ts）',
  )
})

test('claim 之后：allow-once → allowed-once；reject → rejected（唯一授权值是 allowed-once）', async () => {
  const allowed = setupApproval({ decision: 'allow-once' })
  assert.equal((await allowed.run()).outcome, 'allowed-once')

  const rejected = setupApproval({ decision: 'reject' })
  assert.equal((await rejected.run()).outcome, 'rejected')

  for (const setup of [allowed, rejected]) {
    assert.deepEqual(setup.unhandled, [], '正常收束不留未处理记录')
  }
})

test('看护超时 → unavailable + 未处理留证（fail-closed，绝不静默放行）', async () => {
  const setup = setupApproval({ hang: true })
  const pending = setup.run(APPROVAL_ASK)

  setup.clock.advance(DEFAULT_APPROVAL_GUARD_MS)
  const { outcome } = await pending

  assert.equal(outcome, 'unavailable', '§6.2：看护超时返回 unavailable，绝不静默放行')
  assert.equal(setup.unhandled.length, 1, '必须留下一条"未处理"记录')
  const record = setup.unhandled[0]
  assert.ok(record !== undefined)
  assert.equal(record.end, 'timeout')
  assert.equal(record.sid, 'sid_1')
  assert.equal(record.callId, 'call-1')
  assert.equal(record.code, 'interaction/not-pending')
  assert.equal(
    record.clientAction,
    clientActionOf('interaction/not-pending'),
    '客户端行为由封闭表推导，不让各端各自解释',
  )
  assert.match(setup.warnings.join('\n'), /fail-closed/, '失败不能无声无息')
  assert.equal(setup.clock.pending(), 0)
})

test('推答端口抛错 → unavailable + 留证（DSH 会把 answerer 异常静默归一成 unavailable）', async () => {
  const setup = setupApproval({ askThrows: new Error('手机那边断了') })
  const { outcome } = await setup.run()

  assert.equal(outcome, 'unavailable', '我们自己接住：结果与 DSH 的静默归一一致，但失败不再无声无息')
  assert.equal(setup.asks.length, 1, 'claim 之后才推题')
  assert.equal(setup.unhandled[0]?.end, 'disconnected')
  assert.match(setup.warnings.join('\n'), /fail-closed/)
})

test('档位不可识别 → unavailable 且留声（不静默降级成某一档）', async () => {
  const setup = setupApproval({ mode: 'sometimes' as TakeoverMode })
  const { outcome } = await setup.run()

  assert.equal(outcome, 'unavailable', '无法判定时必须 fail-closed：把"不可识别"伪装成某一档，比失败更危险')
  assert.match(setup.warnings.join('\n'), /不可识别/)
  assert.deepEqual(setup.asks, [], '判定不出来就不该推题')
})

test('disposer 注销应答者（少一个就留下一条指向手机的悬挂通道）', () => {
  const setup = setupApproval()
  assert.equal(setup.disposals(), 0, '注册阶段不该调用 disposer')
  setup.off()
  assert.equal(setup.disposals(), 1)
})
