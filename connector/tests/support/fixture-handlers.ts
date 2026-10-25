/**
 * 方法面的测试装置：一份 `createHandlers` 的替身依赖（别名 / 会话行 / 任务 / 模型 / 投影）。
 *
 * ## 为什么单独成一个文件
 *
 * **金样生成器（`tests/wire-shapes.test.ts`）必须与连接级用例用同一份假行。**
 * 若金样里的行是一种形状、用例里是另一种，就又回到"用例喂的形状不是线上形状"
 * （`memory.md` 教训第九条）：两边各自自洽、合起来才断。
 *
 * ## 会话行必须覆盖四种形态
 *
 * 第 1 批的 decoder 按这四档分档（`connector/src/handlers.ts:739-769` 的键矩阵）：
 *
 * | 行 | `parentSessionId` | `cwd` | `model` | `projections` |
 * |---|---|---|---|---|
 * | `dsh-1` 普通 | — | ✓ | ✓ | ✓（只有 `title`） |
 * | `dsh-2` 子会话 | ✓ | — | — | — |
 * | `dsh-3` 冷行 | — | — | — | — |
 * | `dsh-4` 完整信封 | — | ✓ | — | ✓（四个键齐全） |
 *
 * **`models` 与 `projections` 两个面必须给**：`model` 这个键只在 `deps.models`
 * 存在（且 `modelOf` 有值）时才被写出（`handlers.ts:754-759`）；不给它，
 * "可选键"那一半等于没测 —— 金样里一行带 `model` 的都没有。
 *
 * **确定性**：假 id 走 `createFakeAliases` 的定值表；行里没有时间戳、没有随机值。
 * 金样（`tests/fixtures/wire-shapes.json`）比的就是这份输出，任何不确定字段都会让它常年红。
 */
import { createHandlers } from '../../src/handlers.js'
import { ProtocolError } from '../../src/protocol/errors.js'
import { createFakeAliases } from './fake-aliases.js'
import type { JobSubscriptions } from '../../src/job-subscriptions.js'
import type { SessionSubscriptions } from '../../src/session-subscriptions.js'

export const CAPS = {
  sessions: true,
  storage: true,
  approval: false,
  questions: false,
  jobs: false,
  subagents: false,
  references: false,
  plugins: false,
  files: false,
  settings: false,
  credentials: true,
  direct: false,
} as const

/** 假会话 id → 别名。定值，且**不含** DSH 会话 id（"id 不过线"的断言才有意义）。 */
const SID_OF: Record<string, string> = {
  'dsh-1': 'sid_0123456789abcd',
  'dsh-2': 'sid_1122334455667788',
  'dsh-3': 'sid_2233445566778899',
  'dsh-4': 'sid_33445566778899aa',
  'dsh-new': 'sid_99aabbccddeeff00',
}

/** 一份确定性的模型目录（形状照 DSH 的 `buildModelCatalog`：
 *  `packages/api/session-controller/src/catalog.ts:20-72`）。 */
export const MODEL_CATALOG_VALUE = {
  default: { provider: 'deepseek', model: 'deepseek-chat' },
  routableProviders: ['deepseek'],
  groups: [
    {
      id: 'deepseek',
      name: 'DeepSeek',
      models: [
        { id: 'deepseek-chat', name: 'DeepSeek Chat' },
        { id: 'deepseek-reasoner', name: 'DeepSeek Reasoner', reasoning: [{ id: 'high', name: 'High' }] },
      ],
    },
  ],
  failures: [] as { id: string; name: string; message: string }[],
} as const

/**
 * 一个子会话的**完整投影包**（`dsh-4` 的行信封与 `session.projections` 的应答共用）。
 *
 * 这里刻意收**App 真消费的全部 14 个键**（`app/lib/wire/rpc/projections.dart` 的字段表）：
 * 少一个键，那一面就只在手写假行上测过 —— 而"手写假行"正是三次事故的形态。
 * 值取自 2026-10-25 那棵隔离实例的真实投影（尺寸/上限/统计那几个数是真的）。
 *
 * 形状出处：
 * - `tokenUsage`：四个必填整数桶（`app/lib/model/session_stats.dart:85-100`）
 * - `sessionStats`：`session-stats/src/projection.ts:72-81`
 * - `contextPressure` / `contextBreakdown` / `turnOutline`：DSH 各自的 wire view
 * - `modelSelection`：`{lastUsed, next}`（`model-selection-projection.ts:65`）
 * - `subagentTiming`：`{settledMs, active?: {since, through}}`（`app/lib/model/subagent.dart:101-125`）
 * - `permissions`：`{currentValue}`（`permission-presets/src/index.ts:243`）
 * - `subagentCatalog`：`[{id, createdAt, mode, label?}]`（`app/lib/core/job.dart:215-235`）
 * - `trajectory`：本仓自带（`app/lib/model/trajectory.dart:185-205`）
 * - `imageLimits`：`app/lib/model/image_limits.dart` 的 `fromWire`
 */
export const FULL_PROJECTION_VALUES = {
  title: '把 token 账算对',
  modelSelection: {
    lastUsed: { provider: 'deepseek', model: 'deepseek-chat' },
    next: { provider: 'deepseek', model: 'deepseek-reasoner', reasoningEffort: 'high' },
  },
  subagentTiming: { settledMs: 2000, active: { since: 1000, through: 3000 } },
  tokenUsage: {
    uncachedInputTokens: 1200,
    outputTokens: 800,
    cacheReadTokens: 4000,
    cacheWriteTokens: 600,
  },
  sessionStats: {
    turns: 4,
    steps: 13,
    llmMs: 413838,
    toolMs: 544207,
    ttftMs: 193103,
    ttftSteps: 12,
    decodeMs: 220735,
    decodeTokens: 10948,
  },
  contextPressure: { pressureTokens: 53715, projectedTokens: 53873, contextWindow: 1000000 },
  contextBreakdown: { systemTokens: 1446, toolsTokens: 7205, messageTokens: 27421 },
  turnOutline: [
    { turn: 1, seq: 4, prompt: 'hi', response: '你好！' },
    { turn: 2, seq: 27, prompt: 'Give', response: '' },
  ],
  permissions: { currentValue: 'workspace-write' },
  agentPreset: 'standard',
  subagentCatalog: [
    { id: 'dsh-2', createdAt: 1000, mode: 'continuable', label: '调研实现' },
  ],
  trajectory: {
    turns: [
      {
        turn: 1,
        startSeq: 4,
        startTime: 1000,
        endTime: 2000,
        durationMs: 1000,
        outcome: 'completed',
        tokens: 12868,
        stepsTruncated: false,
        steps: [
          {
            kind: 'assistant',
            seq: 6,
            startTime: 1000,
            endTime: 2000,
            offsetMs: 0,
            durationMs: 1000,
            isError: false,
            label: '',
          },
        ],
      },
    ],
    truncated: false,
    droppedTurns: 0,
    droppedSteps: 0,
  },
  imageLimits: {
    maxImageBytes: 20971520,
    maxImagesPerMessage: 20,
    maxMessageImageBytes: 209715200,
    maxImagePixels: 64000000,
    maxImageDimension: 8192,
    mediaTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
  },
  inbox: { 'next-turn': [], 'next-step': [] },
} as const

/** 普通行的投影提示：**没有标题**（会话开过、但还没生成标题 —— 未命名是正常态，
 *  手机侧显示「未命名」而**不**当成形状错）。里面放一个手机暂时不读的投影键，
 *  顺带钉住"`values` 里有我们没消费的键是正常的"。 */
export const PLAIN_PROJECTION_VALUES = { agentPreset: 'standard' } as const

export function fixtureHandlers(
  subscriptions: JobSubscriptions | null = null,
  sessionSubscriptions: SessionSubscriptions | null = null,
  /** 数一数真实的 `session.prompt` 被调用了几次（I8 的证据）。 */
  promptBox?: { count: number },
) {
  return createHandlers({
    caps: () => ({ ...CAPS }),
    aliasVersion: () => 7,
    devices: () => [{ id: 'dev-1', name: '我的手机', pairedAt: 1000, revoked: false }],
    sessions: {
      list: () =>
        Promise.resolve([
          {
            dshSessionId: 'dsh-1',
            updatedAt: 200,
            running: false,
            blank: false,
            subagent: false,
            cwd: '/repo/a',
            projections: { kind: 'sequenced', asOfSeq: 12, values: { ...PLAIN_PROJECTION_VALUES } },
          },
          {
            dshSessionId: 'dsh-2',
            updatedAt: 180,
            running: false,
            blank: false,
            subagent: true,
            parentSessionId: 'dsh-1',
          },
          {
            dshSessionId: 'dsh-3',
            updatedAt: 160,
            running: false,
            blank: true,
            subagent: false,
          },
          {
            dshSessionId: 'dsh-4',
            updatedAt: 140,
            running: true,
            blank: false,
            subagent: false,
            cwd: '/repo/b',
            projections: {
              kind: 'cached',
              asOfSeq: 7,
              values: { ...FULL_PROJECTION_VALUES },
            },
          },
        ]),
      prompt: () => {
        if (promptBox !== undefined) promptBox.count += 1
        return Promise.resolve({ accepted: true })
      },
      selectModel: async (request: { provider: string; model: string }) => ({
        // **回执照请求回声**：DSH 的 `selectModel` 回的就是"已生效的那一对"，
        // 这里写死一对常量会让"手机读回执"的用例测不到真东西。
        selected: { provider: request.provider, model: request.model },
      }),
      create: async (request: { agentPreset?: string }) => ({
        sessionId: 'dsh-new',
        ...(request.agentPreset === undefined ? {} : { agentPreset: request.agentPreset }),
      }),
      updateQueue: async () => ({ accepted: true as const }),
      cancel: () => ({ accepted: true as const }),
    },
    aliases: createFakeAliases({
      // 别名是**不透明的**：刻意不把 DSH 会话 id 编进去，否则"id 不过线"的断言会失去意义
      // （拿一个含 id 的 sid 去查 `includes(id)`，永远为真）。
      sidFor: (dshSessionId) => SID_OF[dshSessionId] ?? 'sid_ffffffffffff',
    }),
    // **模型面**：只给 `dsh-1`（普通会话有活 agent），子会话与冷行都取不到 ——
    // 这正是线上形态：`model` 由活 agent 表读，子会话不在那张表里
    // （`connector/src/dsh/models.ts` 的 `modelOf`）。
    models: {
      catalog: async () => MODEL_CATALOG_VALUE,
      modelOf: (sid) =>
        sid === SID_OF['dsh-1']
          ? { provider: 'deepseek', model: 'deepseek-chat', reasoningEffort: 'high' }
          : undefined,
    },
    // **投影面**：`dsh-4` 有一包完整投影，`dsh-1` 只有标题，其余冷行读不到。
    // 注意这里是**扁平 `values`**（`dsh/projections.ts:68-72` 拆掉了信封），
    // 而 `session.list` 行里是**完整信封** —— 同一个名字的两种形状，金样两条都收。
    projections: {
      of: (dshSessionId: string) =>
        Promise.resolve(
          dshSessionId === 'dsh-4'
            ? { ...FULL_PROJECTION_VALUES }
            : dshSessionId === 'dsh-1'
              ? { ...PLAIN_PROJECTION_VALUES }
              : {},
        ),
    },
    // 工作区面：一份确定性的基线 + 七个方法的定值回执（都是"整份顺序/集合"）。
    workspaces: {
      list: async () => ({
        workspaces: [
          {
            workspaceId: 'ws-1',
            title: 'dsh-mobile',
            path: '/repo/dsh-mobile',
            createdAt: '2026-10-01T00:00:00.000Z',
            sessionIds: ['dsh-1', 'dsh-2'],
          },
        ],
        archivedSessionIds: ['dsh-3'],
        pinnedSessionIds: ['dsh-2'],
      }),
      archive: async (sessionId: string) => ['dsh-3', sessionId],
      unarchive: async () => ['dsh-3'],
      pin: async (sessionId: string) => ['dsh-2', sessionId],
      unpin: async () => ['dsh-2'],
      insertSessionBefore: async () => ['dsh-2', 'dsh-1'],
      insertBefore: async () => ['ws-1'],
    },
    jobs: {
      listOwnedBy: (dshSessionId) =>
        dshSessionId === 'dsh-1'
          ? [
              {
                id: 'j1',
                kind: 'shell',
                label: '构建',
                status: 'running',
                progress: '2/5',
                startedAt: 10,
                outputTotal: 42,
              },
            ]
          : [],
      readOutput: () => ({ chunks: [], next: 0, lossy: false }),
      subscribe: () => () => {},
    },
    // 端口层面的替身：真实端口会把宿主的 job/not-found 转成协议码（见 dsh/jobs.ts），这里照样。
    jobControl: {
      kill: (_sessionId, jobId) => {
        if (jobId === 'j-foreign') throw new ProtocolError('job/not-found', '不属于这个会话')
        return jobId === 'j-done' ? 'already-finished' : 'requested'
      },
      follow: () => (async function* () {})(),
    },
    ...(subscriptions === null ? {} : { jobSubscriptions: subscriptions }),
    ...(sessionSubscriptions === null ? {} : { sessionSubscriptions }),
    // 子代理面：只用到写的一面（`subagent.prompt`）。`deliver` 回一条确定的回执，
    // 于是那条方法的金样样本是确定的。
    subagents: {
      children: async () => [],
      descendants: async () => [],
      deliver: async () => ({ messageId: 'msg-1' }),
    },
  })
}

/** 假别名里那四个会话行的 `sid`（金样选择器与用例都从这里取，不各写一遍）。 */
export const SIDS = SID_OF

/** 取一个假会话行的 `sid`；不在表里就是测试写错了，直接抛（别让 `undefined` 漏进参数）。 */
export function sidOf(dshSessionId: string): string {
  const sid = SID_OF[dshSessionId]
  if (sid === undefined) throw new Error(`假会话行里没有 ${dshSessionId}`)
  return sid
}
