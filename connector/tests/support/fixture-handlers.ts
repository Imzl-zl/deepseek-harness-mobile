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
import { createSessionsAdapter } from '../../src/dsh/sessions.js'
import { createFakeAliases } from './fake-aliases.js'
import type { SessionController } from '@deepseek-ai/dsh-api-session-controller'
import type { SessionSummary } from '@deepseek-ai/dsh-api-session-controller/types'
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
  changes: false,
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

/** DSH 的会话 id 是 branded 类型；夹具里把普通字符串标成它。 */
const dshSid = (value: string): SessionSummary['sessionId'] =>
  value as SessionSummary['sessionId']

/**
 * 投影提示：外壳（kind / asOfSeq）照 DSH 的类型走；`values` 里是我们自己贡献的
 * JSON 投影（DSH 的 `SessionProjectionSummaryValues` 只声明了它编译面内的键，
 * 类型注释原话是 "plus JSON-safe values contributed outside this compilation face"），
 * 所以只有这一层用一次显式转换 —— **会话行的其它字段不接受转换**。
 */
const dshProjections = (
  kind: 'cached' | 'sequenced',
  asOfSeq: number,
  values: Record<string, unknown>,
): SessionSummary['projections'] =>
  ({ kind, asOfSeq, values }) as unknown as SessionSummary['projections']

/**
 * **DSH 侧的真形状会话清单**：类型来自 DSH 自己的 `SessionSummary`。
 *
 * 之前这里直接写端口行（`dshSessionId` / `subagent`…），等于**绕过适配器** ——
 * 金样测的是"手写的行 → handler"，`createSessionsAdapter` 永远没人经过
 * （2026-10-26 评审：连接器下层只有手写假输入兜着）。
 *
 * 现在夹具是 DSH 对象，再走**真实适配器**变成端口行：DSH 改 `SessionSummary`
 * 时 `tsc --noEmit` 直接红，而不是等到某次真机。
 */
const DSH_SESSION_ITEMS: readonly SessionSummary[] = [
  {
    agentAvailable: true,
    sessionId: dshSid('dsh-1'),
    updatedAt: 200,
    running: false,
    blank: false,
    cwd: '/repo/a',
    projections: dshProjections('sequenced', 12, { ...PLAIN_PROJECTION_VALUES }),
  },
  {
    agentAvailable: false,
    sessionId: dshSid('dsh-2'),
    updatedAt: 180,
    running: false,
    blank: false,
    parentSessionId: dshSid('dsh-1'),
    origin: 'subagent',
  },
  {
    agentAvailable: false,
    sessionId: dshSid('dsh-3'),
    updatedAt: 160,
    running: false,
    blank: true,
  },
  {
    agentAvailable: true,
    sessionId: dshSid('dsh-4'),
    updatedAt: 140,
    running: true,
    blank: false,
    cwd: '/repo/b',
    projections: dshProjections('cached', 7, { ...FULL_PROJECTION_VALUES }),
  },
]

/** 走一次真实适配器：DSH `SessionSummary` → 端口行（`SessionSummaryRow`）。 */
function dshSessionRows() {
  // DSH 的 `SessionController` 是个大 class；夹具只假装它用到的那一个方法。
  const controller = {
    list: async () => ({ items: DSH_SESSION_ITEMS }),
  } as unknown as SessionController
  return createSessionsAdapter(controller).list()
}

/**
 * 用**一份给定的 DSH 清单**造 `session.list` 处理器。
 *
 * 真实数据那条样本（`tests/fixtures/real-dsh-sessions.json`）与适配器用例共用它：
 * 两条路径都经过 `createSessionsAdapter`，不存在"夹具手写端口行"的捷径。
 * 别名用 `sid_r<原 id>`：**不透明**，且与 DSH id 不同（否则泄漏断言会永远为真）。
 */
export function sessionListHandlerFor(items: readonly SessionSummary[]) {
  const handlers = createHandlers({
    caps: () => ({ ...CAPS }),
    aliasVersion: () => 7,
    devices: () => [],
    sessions: createSessionsAdapter({
      list: async () => ({ items }),
    } as unknown as SessionController),
    aliases: createFakeAliases({
      sidFor: (dshSessionId) => `sid_r${dshSessionId.replace(/^sid_/, '')}`,
    }),
  })
  const handler = handlers['session.list']
  if (handler === undefined) throw new Error('session.list 没挂上')
  return handler
}

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
      // **不是手写的端口行**：DSH 对象走真实适配器（见上方 `DSH_SESSION_ITEMS`）。
      list: () => dshSessionRows(),
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
      // 分支：子 id 确定性（金样里不出现时间戳/随机数）；`rename` 回显标题。
      fork: async (request: { atSeq?: number }) => ({
        childSessionId: `dsh-fork-${request.atSeq ?? 'latest'}`,
      }),
      rename: async (_sessionId: string, title: string) => ({ title, seq: 2 }),
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
    // 端点自报：一张确定性的端点表（顺序即偏好：direct 先于 relay）。
    endpoints: {
      describe: () => ({
        endpoints: [
          { kind: 'direct' as const, url: 'ws://192.168.2.10:8790/', label: 'WLAN' },
          { kind: 'relay' as const, url: 'ws://127.0.0.1:8787/ws/device' },
        ],
      }),
    },
    // 工作区文件面：一份确定的目录清单 + 一页文本（形状照 app 侧 `fromWire` 的必填项）。
    files: {
      list: async (sid: string, path: string) => ({
        path,
        truncated: false,
        entries: [
          { name: 'README.md', type: 'file' as const, size: 42 },
          { name: 'src', type: 'directory' as const },
        ],
      }),
      read: async (sid: string, path: string) => ({
        text: '# dsh-mobile',
        offset: 1,
        lines: 1,
        eof: true,
        bytes: 13,
      }),
    },
    // 改动面：一份确定的记录（普通行 + 二进制行，两种行形态都收进金样）。
    // **`seq: 10` 回 `undefined`** —— 那是"电脑侧没有这条记录"的形态（`file.changes` 的
    // `{summary:null}`），金样两条都收，App 侧解码才两边都钉得住。
    changes: {
      summary: (_sid: string, seq: number) =>
        seq === 10
          ? null
          : {
              turn: 3,
              files: [
                { path: 'app/lib/main.dart', display: 'app/lib/main.dart', added: 9, deleted: 2 },
                {
                  path: 'assets/logo.png',
                  display: 'assets/logo.png',
                  added: 0,
                  deleted: 0,
                  binary: true as const,
                },
              ],
              total: 2,
              added: 9,
              deleted: 2,
            },
      // 逐行比对：`index: 1` 回二进制（两种判别形态都进金样），其余回一段文本。
      diff: async (_sid: string, _seq: number, index: number) =>
        index === 1
          ? {
              kind: 'binary' as const,
              path: 'assets/logo.png',
              display: 'assets/logo.png',
            }
          : {
              kind: 'text' as const,
              path: 'app/lib/main.dart',
              display: 'app/lib/main.dart',
              before: true,
              after: true,
              coarse: false,
              hunks: [
                {
                  oldStart: 3,
                  oldLines: 3,
                  newStart: 3,
                  newLines: 4,
                  lines: [' a', '-b', '+c', '+d', ' e'],
                },
              ],
            },
    },
    // `@` 候选：两列各一条（行形状由 app 侧 `AtCandidate.from*Row` 认）。
    references: {
      files: async () => [{ path: 'app/lib/main.dart', kind: 'file' as const }],
      sessions: async () => [
        { sid: SID_OF['dsh-1']!, title: 'Greeting', mention: '@[Greeting](dsh:session-1)' },
      ],
    },
    // 任务订阅：`follow` 回起点（手机据此拼尾部缓冲），`unfollow` 回是否真的有在跑的。
    jobSubscriptions: {
      follow: async () => ({ from: 0 }),
      unfollow: () => true,
      stopAll: () => {},
      active: 0,
    },
    // 历史页：一条记录 + 一个"太大、需单独补取"的标记；补取回同形状的一条记录。
    sessionPager: {
      page: async () => ({
        items: [
          {
            kind: 'record' as const,
            record: {
              type: 'event',
              event: {
                type: 'user/message',
                seq: 4,
                time: 1000,
                data: {
                  content: [{ type: 'text', text: 'hi' }],
                  source: { kind: 'user' },
                  role: 'user',
                  id: 'm1',
                },
              },
            },
          },
          { kind: 'refetch' as const, seq: 9, bytes: 2097152 },
        ],
        hasMore: true,
        throughSeq: 4,
      }),
      refetch: async () => ({
        record: {
          type: 'event',
          event: {
            type: 'assistant/message',
            seq: 9,
            time: 2000,
            data: {
              turn: 1,
              step: 1,
              message: {
                role: 'assistant',
                content: [{ type: 'text', text: 'big' }],
                source: { kind: 'model', provider: 'deepseek' },
                id: 'a9',
              },
              stream: [],
            },
          },
        },
      }),
    },
    // 插件面：一行插件 + 一个包 + 一个"回读后"的启停回执（`application` 原样）。
    plugins: {
      list: async () => [
        {
          entryId: 'plugin-1',
          name: 'dsh-mobile',
          moduleName: 'dsh-mobile',
          enabled: true,
          fiberPhase: 'active',
        },
      ],
      listBundles: async () => [
        {
          name: 'dsh-mobile',
          version: '0.1.0',
          installed: true,
          enabled: true,
          removable: true,
        },
      ],
      setEnabled: async (_id: string, enabled: boolean) => ({
        name: 'dsh-mobile',
        enabled,
        application: 'applied',
      }),
    },
    // 插件安装面：**发起即返回**（只有 requestId）+ 一份确定的结论。
    pluginInstall: {
      install: (spec: string, requestId: string) => ({ requestId }),
      remove: (name: string, requestId: string) => ({ requestId }),
      cancel: async (requestId: string) => ({ status: 'cancelling' }),
      status: (requestId: string) => ({
        requestId,
        status: 'done' as const,
        kind: 'install' as const,
        phase: 'applying',
        log: ['added dsh-mobile'],
        logTruncated: false,
        result: {
          changed: true,
          application: 'applied',
          stage: 'applying',
          target: 'dsh-mobile',
          bundle: 'dsh-mobile',
          version: '0.1.0',
        },
      }),
    },
    // 斜杠命令执行面：一条成功回执（`CommandRunView`）+ 一份命令说明。
    commandLine: {
      run: async (_sid: string, line: string) => ({
        matched: true,
        execution: { result: { kind: 'text', text: `ran ${line}` } },
      }),
      describe: (names: readonly string[]) =>
        Object.fromEntries(names.map((name) => [name, `${name} 的说明`])),
    },
    // 交互答复面：只用到 `respond`（其余成员对这条样本无意义，强制转型即可）。
    interaction: {
      respond: (params: unknown) => ({
        itemId: (params as { itemId?: string }).itemId ?? '',
      }),
    } as never,
    // 权限面：一份确定性的预设表 + 一个"切成功"的回执（`CommandRunView`）。
    permissions: {
      catalog: async () => ({
        options: [
          { value: 'read-only', name: '只读' },
          { value: 'workspace-write', name: '工作区写入' },
          { value: 'danger-full-access', name: '完全访问' },
        ],
        defaultOptions: [{ value: 'workspace-write', name: '工作区写入' }],
        defaultPreset: 'workspace-write',
      }),
      switchTo: async (_sid: string, preset: string) => ({
        matched: true,
        execution: { result: { kind: 'text', text: `已切换到 ${preset}` } },
      }),
    },
    // 设置面：描述把同名 ns 回成一份快照；写回改完之后的快照（revision 递增）。
    settings: {
      describe: (namespaces: readonly string[]) =>
        namespaces.map((ns) => ({
          ns,
          revision: 3,
          values: { defaultMode: 'workspace-write' },
          secrets: [],
        })),
      update: async (input: { ns: string; path: readonly string[]; value: unknown }) => ({
        ns: input.ns,
        revision: 4,
        values: { [String(input.path[0])]: input.value },
        secrets: [],
      }),
    },
    // Agent 预设目录：一个内置默认 + 一个自建（`name` 可缺，手机不翻译）。
    agentPresets: {
      roster: async () => ({
        presets: [
          { id: 'standard', isDefault: true },
          { id: 'team-review', name: 'Team Review', description: 'Review-only composition.' },
        ],
      }),
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
