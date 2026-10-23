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
 * 3. **看护只放行人类的回答**：超时 / 被 gateway 撤销一律收成"没答"并留证（§6.2）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  createInteractionFace,
  projectPendingQuestions,
  validateAnswerBatch,
  type AnswerItem,
  type InteractionLogger,
  type PendingItem,
  type Question,
  type QuestionAgent,
  type QuestionProjection,
} from '../src/interaction-face.js'
import { clientActionOf, ProtocolError } from '../src/protocol/errors.js'

// ---------------------------------------------------------------------------
// 假件
// ---------------------------------------------------------------------------

/** DSH `UserQuestionError` 的形状替身：只带内核要分支的 `code`（`user-questions/src/index.ts:46-51`）。 */
function questionError(code: string, message: string): Error & { code: string } {
  return Object.assign(new Error(message), { code })
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


