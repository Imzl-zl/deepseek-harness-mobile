/**
 * 已实现的方法（契约 §5.7）。
 *
 * 这里只放**能就地答完**的方法 —— 不需要新 DSH 服务、也没有跨会话副作用的那些。
 * 其余方法当前一律回 `connector/unsupported`（分发器自带这条），手机据此置灰按钮，
 * 不用错误码试探。
 *
 * **能力位与"实现了哪些方法"是两件事**：
 * - `caps` 说的是**服务在不在**（`dsh/caps.ts`，由宿主提供情况决定）；
 * - `methods` 说的是**我们把哪些方法接上了**（本文件这张表）。
 *
 * 手机置灰按钮靠的是后者，所以 `repo.info` 报的是**表的键**，而不是一份手抄的清单 ——
 * 手抄的清单会在下一次加方法时忘掉同步，而症状是"按钮能点但永远转圈"。
 *
 * ## 每个方法只做"映射 + 组合"
 *
 * 权威数据来自 DSH，别名之类**通道自己的概念**在这一层合成，且**逐字段构造给手机的行**：
 * 任何 `spread` 都会让将来 DSH 新增的字段（比如会话 id）悄悄过线，而中继与手机
 * 只该看到 `sid`（§5.1）。
 */
import { WIRE_VERSION } from './protocol/frame.js'
import { ProtocolError } from './protocol/errors.js'
import type { MethodHandler, MethodName } from './protocol/methods.js'
import type { Caps } from './dsh/caps.js'
import type { JobControlPort, JobsPort } from './dsh/jobs.js'
import type { JobSubscriptions } from './job-subscriptions.js'
import type { SessionPager } from './session-page.js'
import type { SessionSubscriptions } from './session-subscriptions.js'
import type { PromptPart, QueueAction, SessionSummaryRow, SessionsPort } from './dsh/sessions.js'
import type { ConnectionIdentity } from './connection-scope.js'
import type { InteractionFace } from './interaction-face.js'
import type { ModelFace } from './dsh/models.js'
import type { EndpointsPort } from './endpoints.js'
import type { ProjectionsPort } from './dsh/projections.js'
import type { ReferencesFace } from './dsh/references.js'
import type { SubagentsPort } from './dsh/subagents.js'
import type { WorkspacesPort } from './dsh/workspaces.js'
import type { PermissionFace } from './dsh/permissions.js'
import { commandNameOf, type CommandLineRunner } from './dsh/command-line.js'
import type { AgentPresetsFace } from './dsh/agent-presets.js'
import {
  SettingsConflictError,
  SettingsScopeError,
  type SettingsFace,
} from './dsh/settings-face.js'

/** 设备清单里的一行。**不含公钥** —— 手机不需要别人的公钥，少发一个字段就少一处泄漏面。 */
export interface DeviceRow {
  id: string
  name: string
  pairedAt: number
  /** 是否已吊销（电脑侧删公钥）。 */
  revoked: boolean
}

/**
 * 手机上的命令面白名单（`command.execute` 的准入，契约 §5.7）。
 *
 * **判据三条，加一个名字要三条都成立**：
 *
 * 1. **结果就是 `CommandResult` 的 `{kind,text}`**（`interaction/commands/src/types.ts:34-41`），
 *    不产生**会话之外**的新产物 —— 手机拿不到的东西（`/export` 的 ZIP 下载、
 *    `/feedback` 的反馈记录）在电脑侧发生了也呈现不了、更撤不回来。
 * 2. **效果是会话级状态，且处理器自己是状态机**：非法转移被拒、重复执行落到同一终态。
 *    这一条同时是幂等的前提 —— 契约 §5.6 对"崩溃窗口里重新执行"的承诺，靠的正是
 *    下游认得出重复（`idempotency.ts` 文件头那张表）。`/compact` 不满足：没有反向命令，
 *    且一次调用就是一次模型总结（`command-compact/src/index.ts:67`）。
 * 3. **没有已存在的窄口**：`/permission` 的写入口是 `permission.switch`，
 *    同一个状态不开第二条路。
 *
 * 名单**只有这一处**：手机侧不抄第二份 —— 它按"以 `/` 开头"分流发给 `command.execute`，
 * 候选菜单要画的名字由 `repo.info.commands` **原样过线**（同一份 `MOBILE_COMMANDS`）。
 * 所以电脑侧加一个名字，手机上的菜单立刻多一行；拿掉一个名字，手机收到的是
 * `connector/unsupported` + 一句人话，而不是"电脑不认识这条命令"。
 *
 * 取舍（为什么是白名单而不是推翻 §5.7 的通用命令面、为什么第 2 条同时是幂等的依据）见
 * `.agents/notes/implemented/2026-10-23-slash-command-execution-surface.md`。
 */
const MOBILE_COMMANDS: ReadonlySet<string> = new Set(['goal', 'plan'])

/** 白名单的人话（错误信息里用；顺序固定，便于用户照抄）。 */
const MOBILE_COMMAND_LIST = [...MOBILE_COMMANDS].map((name) => `/${name}`).join('、')

/** `tokenUsage` 的四个分项（键名是 DSH 的原名，`usage-projection.ts:16-21`）。 */
interface TokenBuckets {
  uncachedInputTokens: number
  outputTokens: number
  cacheReadTokens: number
  cacheWriteTokens: number
}

const ZERO_BUCKETS: TokenBuckets = {
  uncachedInputTokens: 0,
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheWriteTokens: 0,
}

/** 别名端口（契约 §5.1）：手机与中继都只见 `sid`，所以两个方向都要。 */
export interface AliasPort {
  /** 会话 → 别名（首次调用会分配并落盘）。 */
  ensure(dshSessionId: string): Promise<string>
  /** 别名 → 会话；不认识的别名返回 `undefined`（调用方据此回 `session/not-found`）。 */
  sessionOf(sid: string): string | undefined
}

export interface HandlerDeps {
  /** 服务存在性决定的能力位。 */
  caps: () => Caps
  /** `repo.info` 要报的「别名→会话元映射版本」（契约 §5.7）。 */
  aliasVersion: () => number
  /**
   * 宿主运行时的 DSH 版本（`repo.info.dshVersion`）。
   *
   * 是一个**取值函数**而不是字符串：装配时宿主可能还没把版本读出来（或者这个部署
   * 根本拿不到，见 `dsh/host-version.ts` 的三条取法），而 `repo.info` 是随时会被问的。
   * 拿不到就**不报这个字段** —— 手机那边说"未读到"。
   */
  dshVersion?: () => string | undefined
  /** 已配对设备（含已吊销的，便于手机显示"这台已被移除"）。 */
  devices: () => readonly DeviceRow[]
  /**
   * 端点自报（**没有监听面时不给**）。
   *
   * 与 `jobs` 同一条纪律：缺了就干脆不挂 `endpoint.describe`，而不是挂上去再回
   * `connector/unsupported` —— `repo.info` 报的是 handler 表的键，于是
   * "这台没开直连"与"这个方法没实现"在手机侧是同一种表现（按钮置灰），
   * 而电脑侧少一条永远走不到的分支。
   */
  endpoints?: EndpointsPort
  /**
   * 会话投影读取面（**没有 `sessionProjections` 服务时不给**）。
   *
   * 与 `endpoints` 同一条纪律：缺了就干脆不挂 `session.projections`，
   * 而不是挂上去再回 `connector/unsupported` —— `repo.info` 报的是 handler
   * 表的键，于是"这台没有投影服务"与"这个方法没实现"在手机侧是同一种表现
   * （按钮置灰），而电脑侧少一条永远走不到的分支。
   */
  projections?: ProjectionsPort
  /**
   * 权限预设（**三个服务键同时在场才给**：`permissionPresets` / `commands` / `agents`）。
   *
   * 与 `projections` 同一条纪律：缺了就干脆不挂 `permission.catalog` 与
   * `permission.switch`，而不是挂上去再回 `connector/unsupported` ——
   * `repo.info` 报的是 handler 表的键，于是"这台没有权限服务"与"这个方法没实现"
   * 在手机侧是同一种表现（控件隐藏），而电脑侧少一条永远走不到的分支。
   * 为什么是三个键，见 `dsh/permissions.ts` 的文件头。
   */
  permissions?: PermissionFace
  /**
   * 跑一条斜杠命令（`command.execute`，**`commands` 与 `agents` 同时在场才给**）。
   *
   * 与 `permissions` 同一条纪律：缺了就干脆不挂 `command.execute`，而不是挂上去
   * 再回 `connector/unsupported` —— `repo.info` 报的是 handler 表的键，于是
   * "这台电脑没有命令服务"与"这个方法没实现"在手机侧同一种表现（方法不出现）。
   * 执行那段（别名 → 活 agent、超时、`undefined` 的语义）在 `dsh/command-line.ts`，
   * 与 `permission.switch` 共用。
   */
  commandLine?: CommandLineRunner
  /**
   * Agent 预设目录（**`agentPresets` 服务不在时不给**）。
   *
   * 与 `permissions` 同一条纪律：缺了就干脆不挂 `agentPresets.list`，
   * 而不是挂上去再回 `connector/unsupported` —— `repo.info` 报的是 handler 表的键，
   * 于是"这台没有预设服务"与"这个方法没实现"在手机侧同一种表现（chip 说拿不到目录）。
   * **只挂读**：选预设走 `session.create({agentPreset})`，不需要这个方法面。
   */
  agentPresets?: AgentPresetsFace
  /**
   * 会话清单（DSH 权威行，已按活动排序）。
   *
   * 依赖是**必需**的而不是可选的：`sessionController` 是本插件的必需服务
   * （缺了它插件根本不挂载），所以不存在"这个端口不在"的生产形态；
   * 把它写成可选只会多一条永远不会被走到的错误分支。
   */
  /**
   * 会话面（**收窄成这一层真正用到的方法**：`list` 与 `prompt`）。
   *
   * `sessionController` 是本插件的必需服务（缺了它插件根本不挂载），所以不存在"这个端口不在"
   * 的生产形态；把它写成可选只会多一条永远不会被走到的错误分支。
   */
  sessions: Pick<SessionsPort, 'list' | 'prompt' | 'selectModel' | 'create' | 'updateQueue' | 'cancel'>
  aliases: AliasPort
  /**
   * 后台任务（可选服务）。
   *
   * **缺了就干脆不挂 `job.*` 方法**，而不是挂上去再回 `connector/unsupported`：
   * `repo.info` 报的是 handler 表的键，于是"本机没有 jobs 服务"这件事
   * 与"这个方法没实现"在手机侧是同一种表现（按钮置灰），而电脑侧少一条永远走不到的分支。
   */
  jobs?: JobsPort
  /**
   * 工作区面（可选服务 `workspaceController`）。
   *
   * **缺了就不挂 `workspace.list`**：手机的会话列表退回不分组 —— 那是如实的降级。
   * 不按 `cwd` 猜分组：`cwd` 与工作区不是一对一（多个工作区可以指向同一个目录），
   * 猜的那份就是第二份真值。
   */
  workspaces?: WorkspacesPort
  /**
   * 任务控制（可选服务 `jobController`，由 `dsh-web-app` 提供，base 里没有）。
   *
   * 与 `jobs` 分开是因为它们是**两个服务**，而"停任务"这件事必须走宿主的人类发起门面
   * （理由见 `dsh/jobs.ts` 的 `JobControlPort`）—— 于是两种能力可以独立缺失：
   * 只装 base 的部署能列任务但停不了，那时 `job.*` 里就只有 `job.list`。
   */
  jobControl?: JobControlPort
  /**
   * 任务输出订阅（同样只在 `jobController` 在的时候才有）。
   *
   * 与 `jobControl` 分开传是因为注册表还需要"怎么出帧"与"窗口满了等谁"——
   * 那两件事属于连接层，装配时才知道（见 `index.ts` 的 `start-transport`）。
   */
  jobSubscriptions?: JobSubscriptions
  /**
   * 会话订阅（`session.subscribe` / `session.unsubscribe`）。
   *
   * 与任务订阅分开是因为两者的"键"与"终止帧"都不同（会话按 `sid`、没有终止帧），
   * 但**机制共用同一个骨架**（背压、承诺兑现、跟连接活）——见 `subscriptions.ts`。
   */
  sessionSubscriptions?: SessionSubscriptions
  /**
   * 会话翻页与单条目补取（`session.page` / `session.refetch`）。
   *
   * 与订阅分开传是因为它的水位**来自订阅面的开启帧缓存**（契约 §5.3 要求 `throughSeq`
   * 必须出自开启帧）——装配时把 `cursorOf` 接到订阅面上（见 `index.ts`）。
   */
  sessionPager?: SessionPager
  /**
   * **每连接**才能回答的两个问题：这条连接是哪台设备、它的 presence 上报面在哪。
   *
   * 由 `connection-scope.ts` 在方法面装配时注入（握手完成前 `deviceId()` 返回 `null`）。
   * 缺了就只是没有 presence 上报 —— 方法面本身照常工作。
   */
  connection?: ConnectionIdentity
  /**
   * 提问 / 计划审查的内核（投影 + `interaction.respond` 的校验与路由）。
   *
   * **可选**：`userQuestions` 服务不在时（`caps.questions === false`）干脆不挂这个方法，
   * 让 `repo.info` 自然也不报它 —— 与 `job.*` 同一个理由（契约 §7 的能力位模型）。
   */
  interaction?: InteractionFace
  /**
   * 模型目录与每会话当前模型（`session.modelCatalog` 与 `session.list` 的 `model` 字段）。
   *
   * **可选**：`sessionController` / `sessionProjections` / `agents` 任一不在时
   * （`caps.models === false`）不挂这个方法，`repo.info` 自然也不报它 ——
   * 与 `job.*`、`interaction.respond` 同一个理由（契约 §7 的能力位模型）。
   */
  models?: ModelFace
  /**
   * 子代理面（可选服务 `subagents`）。
   *
   * 目前只用到**写的一面**：给可继续子会话投递一条人写的消息
   * （`subagent.prompt`）。读的一面走投影（`subagentCatalog`），不需要端口。
   * **缺了就不挂这个方法** —— 与 `job.*` 同一条纪律：`repo.info` 报的是
   * handler 表的键，于是"这台没有子代理服务"与"这个方法没实现"在手机侧同一种表现。
   */
  subagents?: SubagentsPort
  /**
   * `@` 候选的两个只读面（`refs.files` / `refs.sessions`）。
   *
   * **两个面都在才给**（`dsh/caps.ts` 的 `referencesAvailable`）：缺了就不挂这两个方法，
   * `repo.info` 的 `methods` 里自然也没有它们、`caps.references` 为 false ——
   * 手机据此**不显示** `@` 面板，而不是显示一个永远空的候选列表。
   *
   * 候选上限交给宿主（它有 `candidateLimit`），这里不截断；空结果是空数组；
   * 宿主抛错原样过线（分发器把非协议错误归成 `internal`，消息文字保留）。
   */
  references?: ReferencesFace
  /**
   * 设置面（`settings.describe` / `settings.update`，可选服务 `settings`）。
   *
   * **缺了就不挂这两个方法** —— 与 `job.*` 同一条纪律：`repo.info` 报的是 handler 表的键，
   * 于是"这台没有设置服务"与"这个方法没实现"在手机侧同一种表现。
   * 可读 / 可写的范围由 `dsh/settings-face.ts` 的两张 allowlist 定：
   * 手机只为三行设置而来（默认权限档 / 默认预设 / Session Log），
   * 而写面按 (ns, path) 逐条放行 —— `mutate` 是能写密钥字段的，`settings.update` 不是那条通道。
   */
  settings?: SettingsFace
}

export function createHandlers(deps: HandlerDeps): Partial<Record<MethodName, MethodHandler>> {
  /**
   * 把 `subagentCatalog` 投影里的**子会话 id 换成别名**（契约 §5.1）。
   *
   * ## 为什么必须换
   *
   * catalog 每项的 `id` 是**子会话的 DSH session id**
   *（`packages/subagent/subagent/src/catalog.ts:79` 的 `id: sessionIdSchema`）。
   * 而手机侧的 `sid` 是别名：`session.subscribe` 走 `requireSession`
   *（本文件 `:206`，内部是 `aliases.sessionOf`），**原始 id 会抛
   * `session/not-found`**。
   *
   * 所以不换的话，手机拿到的那一列子智能体**点了打不开** ——
   * 用户 2026-10-19 原话：「子智能体是列表，每一个点击是能进入的」。
   * 同一件事也修掉一个**一直存在**的越线：catalog 的 id 原先原样过线，
   * 而 §5.1 说手机与中继只见 `sid`。
   *
   * ## 为什么在这里换（而不是让手机去解）
   *
   * 别名是**连接器的知识**（`alias.ts` 的分配与持久化）。手机侧拿不到
   * 「DSH id → sid」的表，也不该拿到。投影是**面向手机**的只读面，
   * 凡它携带的会话 id 都该在过线前换好 —— 这一条只在这个方法上成立
   *（其它投影不带会话 id），所以就地做、不造通用机制。
   *
   * 认不出的形状**原样放过**：换不了不是"这个投影坏了"，
   * 而是"这一版没有这个字段"（与 `tokenTotalOf` 同一条纪律：
   * 不预设键名，也不把认不出当错误）。
   */
  async function aliasSubagentCatalog(
    values: unknown,
    aliases: AliasPort,
  ): Promise<unknown> {
    if (typeof values !== 'object' || values === null) return values
    const catalog = (values as Record<string, unknown>)['subagentCatalog']
    if (!Array.isArray(catalog)) return values
    const aliased = await Promise.all(
      catalog.map(async (entry) => {
        if (typeof entry !== 'object' || entry === null) return entry
        const id = (entry as Record<string, unknown>)['id']
        if (typeof id !== 'string' || id === '') return entry
        return { ...(entry as Record<string, unknown>), id: await aliases.ensure(id) }
      }),
    )
    return { ...(values as Record<string, unknown>), subagentCatalog: aliased }
  }

  /**
   * 取一个**形状合法**的 `sid`（契约 §5.7：形状不对是请求不合法，不是数据不存在）。
   *
   * 与 `requireSession` 分开是因为带 `sid` 的方法有两件事要做：先校验形状，再查别名。
   * 订阅类方法还要把 `sid` **原样留着**当订阅键（它是通道的键，不是 DSH 会话 id）。
   */
  const requireSid = (params: unknown): string => {
    const sid = paramOf(params, 'sid')
    if (typeof sid !== 'string' || sid === '') {
      throw new ProtocolError('protocol/bad-frame', 'sid 必填')
    }
    return sid
  }

  /**
   * 把一个 `sid` 反解回 DSH 会话 id（契约 §5.1：手机与中继只见 `sid`）。
   *
   * **别名不认识时不许当"没有数据"处理**：回一个空列表等于对手机撒谎
   * （"这个会话没有任务"），而事实是"我不认识这个会话"。所以回 `session/not-found`
   * ——§3.1 给它的客户端行为就是「从列表移除」，正是这里该发生的事。
   */
  const requireSession = (sid: string): string => {
    const dshSessionId = deps.aliases.sessionOf(sid)
    if (dshSessionId === undefined) {
      throw new ProtocolError('session/not-found', `未知的会话别名：${sid}`)
    }
    return dshSessionId
  }

  /// 一个会话的 token 总量（`tokenUsage` 投影的 wire 值）。
  ///
  /// **wire 值是 `totals` 本身，不是 `{totals, last}`** ——
  /// `llm/token-meter/src/usage-projection.ts:149` 的
  /// `wire: { viewSchema: projectionSchema, view: state => state.totals }`：
  /// 上线的就是那个 4 字段对象（`uncachedInputTokens` / `outputTokens` /
  /// `cacheReadTokens` / `cacheWriteTokens`）。按 `{totals,…}` 读会得到
  /// undefined ⇒ 汇总恒为 0（2026-10-19 真机复现：128 个会话全 0）。
  ///
  /// 两个形状都收（线上直读 + 万一将来改回带信封）：先找 `totals`，
  /// 没有再把自己当 totals。**不预设键名** —— 全部数值字段求和，
  /// 认不出的形状自然得 0。
  const tokenTotalOf = (tokenUsage: unknown): number => {
    if (typeof tokenUsage !== 'object' || tokenUsage === null) return 0
    const direct = tokenUsage as Record<string, unknown>
    const totals = typeof direct.totals === 'object' && direct.totals !== null
      ? (direct.totals as Record<string, unknown>)
      : direct
    let sum = 0
    for (const value of Object.values(totals)) {
      if (typeof value === 'number' && Number.isFinite(value)) sum += value
    }
    return sum
  }

  /// 四个 token 分项（`tokenUsage` 的 wire 值是 `totals` 本身，同上）。
  ///
  /// **键名原样用 DSH 的**（`usage-projection.ts:16-21` 的 `zeroBuckets`）：
  /// 连接器不做"提示词/补全"这类翻译 —— 词属于界面，由手机给。
  /// 认不出的形状给全零（与 `tokenTotalOf` 同一条纪律：不预设键名）。
  const bucketsOf = (tokenUsage: unknown): TokenBuckets => {
    const out: TokenBuckets = { ...ZERO_BUCKETS }
    if (typeof tokenUsage !== 'object' || tokenUsage === null) return out
    const direct = tokenUsage as Record<string, unknown>
    const totals = typeof direct.totals === 'object' && direct.totals !== null
      ? (direct.totals as Record<string, unknown>)
      : direct
    for (const key of Object.keys(out) as (keyof TokenBuckets)[]) {
      const value = totals[key]
      if (typeof value === 'number' && Number.isFinite(value)) out[key] = value
    }
    return out
  }

  /// 把 `trajectory` 投影里每一轮的起点折成"按天计数"（热力图的数据面）。
  ///
  /// 日期用**电脑侧本地时区**：`turn/start.time` 是那台电脑的时钟，
  /// 而热力图回答的是"这台电脑上哪天在干活"。
  /// **覆盖范围受投影上限约束**（`dsh/trajectory.ts:98` 的 `MAX_TURNS = 200`，
  /// 超出保留窗口的轮不在里面）—— 这是如实的上界，写进契约 §5.7 那一行。
  const turnsByDayOf = (
    trajectory: unknown,
  ): Map<string, { turns: number; tokens: number }> => {
    const days = new Map<string, { turns: number; tokens: number }>()
    if (typeof trajectory !== 'object' || trajectory === null) return days
    const turns = (trajectory as { turns?: unknown }).turns
    if (!Array.isArray(turns)) return days
    for (const turn of turns) {
      if (typeof turn !== 'object' || turn === null) continue
      const time = (turn as { startTime?: unknown }).startTime
      if (typeof time !== 'number' || !Number.isFinite(time) || time <= 0) continue
      const tokens = (turn as { tokens?: unknown }).tokens
      const date = new Date(time)
      const key = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
      const acc = days.get(key) ?? { turns: 0, tokens: 0 }
      acc.turns += 1
      // 这一轮的 token 来自 `trajectory.turns[].tokens`（`assistant/message.usage`
      // 的累加，见 `dsh/trajectory.ts` 的 `TrajectoryTurn.tokens`）。
      if (typeof tokens === 'number' && Number.isFinite(tokens) && tokens > 0) {
        acc.tokens += tokens
      }
      days.set(key, acc)
    }
    return days
  }

  /// 列表行的标题（**从投影提示来**，与 `session.list` 给手机的同一个来源）。
  ///
  /// DSH 的 host 侧 `SessionSummary` 没有独立的持久标题字段
  /// （`dsh-api-session-controller` 的 `lib/types/types.d.ts`），标题在
  /// `projections.values.title`（`session-title/src/index.ts:269-281`，
  /// wire view 是 `string | null`）。**不从本地条目推导**：推导出来的标题
  /// 是第二个真值源，必然漂（2026-10-17 真机反馈"选中会话名字就变"）。
  /// 取不到就空串 —— 手机按 DSH 的链退到「未命名」，不在这里兜一个目录名。
  const titleOf = (row: SessionSummaryRow): string => {
    const values = (row.projections as { values?: unknown } | undefined)?.values
    if (typeof values !== 'object' || values === null) return ''
    const title = (values as Record<string, unknown>).title
    return typeof title === 'string' ? title : ''
  }

  /** 取一个非空字符串参数（`jobId` 之类）。 */
  const requireString = (params: unknown, key: string): string => {
    const value = paramOf(params, key)
    if (typeof value !== 'string' || value === '') {
      throw new ProtocolError('protocol/bad-frame', `${key} 必填`)
    }
    return value
  }

  /**
   * 取一个**字符串数组**参数（缺省 = 空数组）。
   *
   * 形状不对回 `gateway/bad-request` 而不是 `protocol/bad-frame`：这一层已经解过帧，
   * 到了这里说明**是我们发的参数**不对（与 `settings.update` 的越界同一条归类）。
   */
  const stringArray = (params: unknown, key: string): string[] => {
    if (params === null || typeof params !== 'object') return []
    const value = (params as Record<string, unknown>)[key]
    if (value === undefined) return []
    if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
      throw new ProtocolError('gateway/bad-request', `${key} 必须是字符串数组`)
    }
    return value as string[]
  }

  /**
   * 取一个可选的非负整数参数（`since` / `beforeSeq` / `maxMessages` / `seq` 这一类）。
   *
   * 负数、小数、非数字一律 `protocol/bad-frame`：它们都是**下标或条数**，
   * 接受一个不合法的值只会让它一路走到 DSH 里再以更难懂的方式失败。
   */
  function optionalCount(params: unknown, key: string): number | undefined {
    const value = paramOf(params, key)
    if (value === undefined) return undefined
    if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
      throw new ProtocolError('protocol/bad-frame', `${key} 必须是非负整数`)
    }
    return value
  }

  /** 取 `params.sid`（形状不对留给 `requireSession` 报 `protocol/bad-frame`）。 */
  const sidOf = (params: unknown): unknown => paramOf(params, 'sid')

  /** 取 `params` 里的某个字段（形状不对时返回 `undefined`，由各自的校验报错）。 */
  function paramOf(params: unknown, key: string): unknown {
    return typeof params === 'object' && params !== null
      ? (params as Record<string, unknown>)[key]
      : undefined
  }

  /**
   * 取 `content`：非空数组，每一项是带 `type` 的对象。
   *
   * 只做**形状**校验：具体是文本还是图片、图片能不能被当前模型接受，是 DSH 的判据
   * （它会回 `session/attachment-invalid` 之类；我们的错误码表是封闭的，那些归 `internal`，
   * 但**消息原样透传** —— 用户照样看得到"模型不支持图片输入"）。
   */
  function requireContent(params: unknown): readonly PromptPart[] {
    const value = paramOf(params, 'content')
    if (!Array.isArray(value) || value.length === 0) {
      throw new ProtocolError('protocol/bad-frame', 'content 必须是非空数组')
    }
    for (const part of value) {
      if (typeof part !== 'object' || part === null || typeof (part as { type?: unknown }).type !== 'string') {
        throw new ProtocolError('protocol/bad-frame', 'content 的每一项都必须是带 type 的对象')
      }
    }
    return value as readonly PromptPart[]
  }

  const handlers: Partial<Record<MethodName, MethodHandler>> = {
    'devices.list': () => ({
      devices: deps.devices().map((row) => ({
        devId: row.id,
        name: row.name,
        pairedAt: row.pairedAt,
        revoked: row.revoked,
      })),
    }),

    'session.prompt': async (params, context) => {
      const dshSessionId = requireSession(requireSid(params))
      // **`requestId` 在请求顶层**（不是 `params` 里），方法面把它放进上下文递进来 ——
      // 而且 `IDEMPOTENT_METHODS` 的键强制在**分发之前**就查过了（§5.6），所以这里一定拿得到。
      const requestId = context.requestId
      if (requestId === undefined || requestId === '') {
        throw new ProtocolError('protocol/bad-frame', 'requestId 必填：写操作必须带幂等键')
      }
      const content = requireContent(params)
      const mode = paramOf(params, 'mode')
      if (mode !== undefined && mode !== 'queue' && mode !== 'steer') {
        throw new ProtocolError('protocol/bad-frame', 'mode 必须是 queue 或 steer')
      }
      // **幂等键就是 `requestId`**：方法面按 `IDEMPOTENT_METHODS` 把它包进两阶段管道
      // （先落盘 pending → 执行 → 成功写 done），所以这里只管把参数递下去。
      // DSH 自己也按 `rpcId` 去重（会扫会话事件日志，`commands.ts:602-614`）——
      // 两层叠起来：同一条消息不会因为重发变成两条，也不会因为桥接重启而丢。
      const { accepted } = await deps.sessions.prompt(
        dshSessionId,
        requestId,
        content,
        mode === 'steer' ? 'steer' : 'queue',
      )
      return { accepted }
    },

    // 打断：取消当前轮次但**保留待处理收件箱**。**与 Web 同一个 DSH 方法**
    // （`session-controller/src/index.ts:472` 的 `@Remote('cancel')`）。
    // DSH 的注释原话是"Cancel one active Agent turn without dropping its
    // pending inbox"（`:467-470`）—— 排队中的消息不会被这一次取消丢掉，
    // 所以它安全地当"停止"用。
    // 不带幂等键（契约 §5.7 那一列是空的）：取消本就没有第二次副作用。
    // Note: 排队条 / 插话 / 打断为什么是这三个方法而不是别的形态 ——
    // 见 .agents/notes/implemented/2026-10-17-queue-dock-and-cancel-landed.md
    'session.cancel': async (params) => {
      const dshSessionId = requireSession(requireSid(params))
      return deps.sessions.cancel(dshSessionId)
    },

    // 排队项变异：编辑 / 删除 / 插话。**与 Web 的排队 dock 同一个 DSH 方法**
    // （`sessionController.updateQueue`，`@Remote('updateQueue')`，
    // `packages/api/session-controller/src/index.ts:462-465`；实现 `commands.ts:432-479`）。
    // 队列内容不在这个方法里 —— 它在 `inbox` 投影（随 `session.projections` 到手机），
    // 这里只做"变异某一项"这一个动作，带幂等键（用户指令，重发不该编辑两次）。
    'session.updateQueue': async (params, context) => {
      const dshSessionId = requireSession(requireSid(params))
      const requestId = context.requestId
      if (requestId === undefined || requestId === '') {
        throw new ProtocolError('protocol/bad-frame', 'requestId 必填：写操作必须带幂等键')
      }
      const itemId = requireString(params, 'itemId')
      const action = paramOf(params, 'action')
      if (typeof action !== 'object' || action === null) {
        throw new ProtocolError('protocol/bad-frame', 'action 必须是对象')
      }
      const kind = (action as { kind?: unknown }).kind
      if (kind !== 'edit' && kind !== 'remove' && kind !== 'steer') {
        throw new ProtocolError('protocol/bad-frame', "action.kind 必须是 edit / remove / steer")
      }
      if (kind === 'edit') {
        // 编辑只收纯文本（DSH 的 `commands.ts:433-448` 同一条：非文本块整个拒）。
        const content = (action as { content?: unknown }).content
        if (!Array.isArray(content) || content.length === 0) {
          throw new ProtocolError('protocol/bad-frame', 'edit 的 content 必须是非空数组')
        }
        for (const part of content) {
          if (typeof part !== 'object' || part === null || (part as { type?: unknown }).type !== 'text') {
            throw new ProtocolError('protocol/bad-frame', 'edit 的 content 每一项都必须是 {type:"text"}')
          }
          const text = (part as { text?: unknown }).text
          if (typeof text !== 'string' || text.trim() === '') {
            throw new ProtocolError('protocol/bad-frame', 'edit 的 text 必须含非空白字符')
          }
        }
      }
      return deps.sessions.updateQueue({
        sessionId: dshSessionId,
        itemId,
        action: action as QueueAction,
      })
    },

    // 切模型：**与 Web 同一个 DSH 方法**（见 `dsh/sessions.ts` 的 `selectModel` 注释）。
    // 带幂等键 —— 切模型是用户指令，重发不该切两次。
    // 方法名带连字符，所以是**字符串 key**（`'session.select-model':`）而不是点号。
    'session.select-model': async (params, context) => {
      const dshSessionId = requireSession(requireSid(params))
      const provider = requireString(params, 'provider')
      const model = requireString(params, 'model')
      const effort = paramOf(params, 'reasoningEffort')
      if (effort !== undefined && typeof effort !== 'string') {
        throw new ProtocolError('protocol/bad-frame', 'reasoningEffort 必须是字符串')
      }
      return deps.sessions.selectModel({
        sessionId: dshSessionId,
        provider,
        model,
        ...(effort === undefined ? {} : { reasoningEffort: effort }),
      })
    },

    // 新建会话。**与 Web 同一个 DSH 方法**（见 `dsh/sessions.ts` 的 `create` 注释）。
    // 带幂等键 —— 点了两次不该建出两个会话。
    // `workspaceId` / `cwd` 都**不透传**：手机不知道电脑有哪些工作区，
    // 而 DSH 对缺省字段有自己的当前工作区（与 Web 点"新建会话"一致）。
    // 硬传一个猜的值比不传更糟。
    // 取舍见 `.agents/notes/implemented/2026-10-15-session-create.md`。
    'session.create': async (params) => {
      // 先收窄成 `string | undefined`，再展开 —— 直接展开 `unknown` 过不了类型。
      const str = (key: string): string | undefined => {
        const value = paramOf(params, key)
        if (value === undefined) return undefined
        if (typeof value !== 'string') {
          throw new ProtocolError('protocol/bad-frame', `${key} 必须是字符串`)
        }
        return value
      }
      const workspaceId = str('workspaceId')
      const cwd = str('cwd')
      const agentPreset = str('agentPreset')
      const created = await deps.sessions.create({
        ...(workspaceId === undefined ? {} : { workspaceId }),
        ...(cwd === undefined ? {} : { cwd }),
        ...(agentPreset === undefined ? {} : { agentPreset }),
      })
      // DSH 回的是 `{sessionId}`（`session-controller/src/commands.ts:149`），
      // 而通道只说别名 `sid`。**原样透传有两个错**（2026-10-17 真机验收抓到：
      // hero 上选工作区后"开新任务失败：新建会话没有回 sid"）：
      // ① 字段名对不上，手机读不到；
      // ② 把 DSH 会话 id 漏过了线 —— 别名表的存在就是让中继与手机只见到 `sid`
      //    （`dsh/sessions.ts:89`），`session.list` 一向如此，只有这条写路径漏了。
      // 建完即分配别名，与 `session.list` 的 `ensure` 同一个表，两边看到同一条。
      const sid = await deps.aliases.ensure(created.sessionId)
      return {
        sid,
        ...(created.agentPreset === undefined ? {} : { agentPreset: created.agentPreset }),
      }
    },

    'session.list': async () => {
      const rows = await deps.sessions.list()
      // 别名可以**并发**分配：不同会话之间互不影响，同一个会话则由 `ensure` 自己合流
      // （见 `alias.ts` 的说明）。逐字段构造给手机的行，**不 spread** ——
      // `dshSessionId` 绝不能过线（中继与手机只见 `sid`）。
      //
      // **父级也要过同一张别名表**：`parentSessionId` 是 DSH 的会话 id
      // （`dsh/sessions.ts` 的 `SessionSummaryRow.parentSessionId`），
      // 原样发出去就是把 DSH 的 id 漏过线 —— 与 `session.create` 那条同一个错
      // （见本文件 `session.create` 的注释）。根会话没有父级 ⇒ **不给这个键**，
      // 也不为 `undefined` / 空串建别名（前者会塞一行空映射，后者会铸出一个
      // 不存在的父级 —— 手机拿到它会让 `←` 打开一个空会话）。
      const assigned = await Promise.all(
        rows.map(async (row) => ({
          row,
          sid: await deps.aliases.ensure(row.dshSessionId),
          parentSid:
            row.parentSessionId === undefined || row.parentSessionId === ''
              ? undefined
              : await deps.aliases.ensure(row.parentSessionId),
        })),
      )
      return {
        sessions: assigned.map(({ row, sid, parentSid }) => ({
          sid,
          updatedAt: row.updatedAt,
          running: row.running,
          blank: row.blank,
          subagent: row.subagent,
          // **父级（别名形式）**：手机侧「子会话头部的父级」与「← 返回父会话」
          // 走的就是它 —— 导航记忆只有一层，往深处走一层就不对了
          // （`.agents/notes/implemented/2026-10-23-subagent-header-parent-from-data.md`）。
          // 根会话（`parentSessionId === undefined`）**不带这个键**：
          // 不给 = 根；给空串会把根读成"父级叫空"的子会话。
          ...(parentSid === undefined ? {} : { parentSessionId: parentSid }),
          // **当前模型从真投影来**，不是占位：`modelSelection` 的 `next ?? lastUsed`
          // （`dsh/models.ts`）。取不到就**不给这个字段** —— 手机显示"未选择"，
          // 而不是猜一个把"看起来连着"当成"连着"。
          ...(deps.models === undefined
            ? {}
            : (() => {
                const model = deps.models.modelOf(sid)
                return model === undefined ? {} : { model }
              })()),
          ...(row.cwd === undefined ? {} : { cwd: row.cwd }),
          // **投影提示原样透送**：`projections.values.title` 就是列表标题，
          // Web 的列表行读的是同一个东西（`list.ts:291-312` 的 hints）。
          // 冷行（从没打开过的会话）也有值 —— DSH 为它读持久缓存。
          // 手机据此显示标题；空标题显示「未命名」，不拿目录名兜底
          // （DSH 的 `sessionTitle` 同一条，`ui-workspace/src/client/tree.ts:296`）。
          ...(row.projections === undefined
            ? {}
            : { projections: row.projections }),
        })),
      }
    },
  }

  // 模型目录：与 `job.*` / `interaction.respond` 一样按能力位挂（契约 §7）。
  if (deps.models !== undefined) {
    handlers['session.modelCatalog'] = async () => {
      const catalog = await deps.models!.catalog()
      // 目录拿不到就**明说**，不给空数组：空数组会被手机读成"没有可用模型"，
      // 而真实原因可能是某个 provider 的 key 没配。
      if (catalog === undefined) return { available: false }
      return { available: true, catalog }
    }
  }

  // 端点自报：与 `job.*` / `interaction.respond` 一样按能力位挂（契约 §7）。
  // 缺了 `endpoints` 时 `endpoint.describe` 不出现 —— 手机侧看到的是  // "这个方法不存在"，而不是一个回 `unsupported` 的按钮。
  if (deps.endpoints !== undefined) {
    handlers['endpoint.describe'] = () => deps.endpoints!.describe()
  }

  // 子会话**唯一的写入口**：给可继续子会话投递一条人写的消息。
  //
  // 直接对子会话调 `session.prompt` 会被宿主拒成
  // `internal: session "…" is owned by subagent routing`（2026-10-21 真机实测，
  // 手机侧表现成「发送失败：…is owned by subagent routing」）。而手机在子会话里
  // 给的是**正常输入框**（可继续档，`docs/subsystems/subagent-page.md` §5）——
  // 输入框能用、发出去必失败，正是"承诺了但做不到"。DSH 的入口是
  // `SubagentRuntime.prompt`（`packages/subagent/subagent/src/index.ts:447`）。
  //
  // 父级从**清单行**来（`parentSessionId` 只在子会话行上出现），
  // 与 `follow` / `page` 的地址解析同一个出处（`dsh/sessions.ts` 的
  // `resolveSessionAddress`）：两处各推一次父级就是第二份会漂的真值。
  if (deps.subagents !== undefined) {
    handlers['subagent.prompt'] = async (params, context) => {
      const dshChildId = requireSession(requireSid(params))
      const requestId = context.requestId
      if (requestId === undefined || requestId === '') {
        throw new ProtocolError('protocol/bad-frame', 'requestId 必填：写操作必须带幂等键')
      }
      const content = requireContent(params)
      const mode = paramOf(params, 'mode')
      if (mode !== undefined && mode !== 'queue' && mode !== 'steer') {
        throw new ProtocolError('protocol/bad-frame', 'mode 必须是 queue 或 steer')
      }
      const rows = await deps.sessions.list()
      const row = rows.find((item) => item.dshSessionId === dshChildId)
      if (row === undefined || !row.subagent || row.parentSessionId === undefined) {
        // 这个 sid 不是子会话（或清单里查不到父级）：那是客户端用错了方法，
        // 不是宿主故障 —— 让它按 bad-frame 重试/改正，别伪装成连接问题。
        throw new ProtocolError(
          'protocol/bad-frame',
          '这个会话不是子智能体的子会话：投递请走 session.prompt',
        )
      }
      const receipt = await deps.subagents!.deliver({
        parentSessionId: row.parentSessionId,
        childSessionId: dshChildId,
        requestId,
        content,
        delivery: mode === 'steer' ? 'steer' : 'queue',
      })
      return { accepted: true, messageId: receipt.messageId }
    }
  }

  // 会话投影：一个方法打开全部只读面（见 `dsh/projections.ts` 的文件头）。
  // **按能力位挂**：缺 `sessionProjections` 服务时这个方法不出现 ——
  // 与 `job.*` 同一条纪律（手机侧看到"不存在"而不是一个必然失败的按钮）。
  if (deps.projections !== undefined) {
    handlers['session.projections'] = async (params) => {
      const dshSessionId = requireSession(requireSid(params))
      const values = await deps.projections!.of(dshSessionId)
      return aliasSubagentCatalog(values, deps.aliases)
    }

    // **跨会话用量汇总**（2026-10-19，方案见
    // `.agents/notes/proposed/2026-10-19-cross-session-usage-summary.md`）。
    //
    // DSH 的 `tokenUsage` 投影是**单会话**的（`token-meter/src/usage-projection.ts:56-63`
    // 的 state 是 `{totals, last:{turn, step, buckets}}`），没有跨会话汇总接口，
    // 所以这一层自己聚合。
    //
    // ## 为什么是"遍历 visible 会话读投影"而不是连接器本地记账
    //
    // 本地记账只覆盖**插件在线期间**的会话，给出的数字看起来像总量其实不是 ——
    // 那比没有更糟（项目纪律：不给看似数据的假数据）。遍历读投影拿的是
    // DSH 的持久真值，与手机上单会话看到的那个数字同源。
    handlers['usage.summary'] = async () => {
      const rows = await deps.sessions.list()
      // 别名可以**并发**分配（与 `session.list` 同一条纪律）：不同会话互不影响，
      // 同一个会话由 `ensure` 自己合流。
      const assigned = await Promise.all(
        rows.map(async (row) => ({ row, sid: await deps.aliases.ensure(row.dshSessionId) })),
      )
      // **子智能体会话不计入**：与 `sessionVisible` 同一条规则（`ui-workspace`
      // 的 `tree.ts:245`）—— 子智能体的用量已经含在父会话的账里，
      // 再算一遍就是双计。
      const visible = assigned.filter(({ row }) => !row.subagent)
      // 逐个读投影。**并发**（彼此独立，串行会让 20 个会话等 20 个往返）；
      // 单个会话读失败**不影响其它**（那一项按 0 计，与"没数据"区分不开是
      // 可接受的降级 —— 总量仍然对，只是少了那一份）。
      const usages = await Promise.all(
        visible.map(async ({ row }) => {
          const values = (await deps.projections!.of(row.dshSessionId)) as {
            tokenUsage?: unknown
            trajectory?: unknown
          }
          // **一次投影读要算三样**：总量（老字段）、四个分项、以及"哪几天在干活"。
          // 三样都来自同一包 `values`，所以按天聚合**没有额外往返**
          // （`trajectory` 本来就在 `session.projections` 的返回里）。
          return {
            tokens: tokenTotalOf(values.tokenUsage),
            buckets: bucketsOf(values.tokenUsage),
            days: turnsByDayOf(values.trajectory),
          }
        }),
      )
      const grandTotal = usages.reduce((sum, entry) => sum + entry.tokens, 0)
      const totalBuckets = usages.reduce<TokenBuckets>(
        (acc, entry) => ({
          uncachedInputTokens: acc.uncachedInputTokens + entry.buckets.uncachedInputTokens,
          outputTokens: acc.outputTokens + entry.buckets.outputTokens,
          cacheReadTokens: acc.cacheReadTokens + entry.buckets.cacheReadTokens,
          cacheWriteTokens: acc.cacheWriteTokens + entry.buckets.cacheWriteTokens,
        }),
        { ...ZERO_BUCKETS },
      )
      // 按天合并：**轮次与 token 都是真值**（token 来自每轮 `assistant/message.usage`
      // 的累加，见 `dsh/trajectory.ts`）。日期升序 —— 热力图画的是连续的一段日历。
      const dayMap = new Map<string, { turns: number; tokens: number }>()
      for (const entry of usages) {
        for (const [date, acc] of entry.days) {
          const total = dayMap.get(date) ?? { turns: 0, tokens: 0 }
          total.turns += acc.turns
          total.tokens += acc.tokens
          dayMap.set(date, total)
        }
      }
      const byDay = [...dayMap.entries()]
        .map(([date, acc]) => ({ date, turns: acc.turns, tokens: acc.tokens }))
        .sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0))
      // **按项目（工作区目录）聚合**：`cwd` 就是 `session.list` 已经在发的那个
      // 字段（`dsh/sessions.ts` 的 `...(item.cwd === undefined ? {} : { cwd })`）。
      // 用户 2026-10-19 原话：「用量你最好也是做成一个页面的……总量，单个项目
      // 使用量是吧」。DSH 没有跨会话汇总接口，所以这一层聚合（见方法头的说明）。
      //
      // **`cwd` 为空的会话单独一档**（`path: ''`）：不猜一个项目归属。
      // 空目录名在手机上显示成「未关联项目」。
      const byProjectMap = new Map<string, { tokens: number; sessions: number }>()
      visible.forEach(({ row }, i) => {
        const path = row.cwd ?? ''
        const acc = byProjectMap.get(path) ?? { tokens: 0, sessions: 0 }
        acc.tokens += usages[i]!.tokens
        acc.sessions += 1
        byProjectMap.set(path, acc)
      })
      const byProject = [...byProjectMap.entries()]
        .map(([path, acc]) => ({ path, tokens: acc.tokens, sessions: acc.sessions }))
        .filter((entry) => entry.tokens > 0)
        .sort((a, b) => b.tokens - a.tokens)
      return {
        sessions: visible.length,
        grandTotalTokens: grandTotal,
        // 四个分项（键名是 DSH 的原名，手机自己给中文标签）。
        totals: totalBuckets,
        // **按天只数轮次**：投影里没有"每一轮用了多少 token"，按天摊 token 就是编。
        // 覆盖范围 = 各会话 `trajectory` 保留的最近 200 轮（`dsh/trajectory.ts:98`）。
        byDay,
        byProject,
        // 逐字段构造，**不 spread** —— 且只给手机认识的 `sid`
        // （`dshSessionId` 绝不能过线，契约 §5.1）。
        //
        // **不再截断到 5 条**：2026-10-19 起用量是**独立页面**（`ui/usage_page.dart`），
        // 一页能放很多行；截断会让"更多会话"看不见。排序仍然是
        // "用量大的在前"（手机侧自己决定怎么分组/折叠）。
        bySession: visible
          .map(({ row, sid }, i) => ({
            sid,
            // 标题从列表行的投影提示来（与 `session.list` 同一个来源）；
            // 取不到就空串，手机自己按 DSH 的链退到「未命名」。
            title: titleOf(row),
            // 项目目录（**同一个来源**：`session.list` 的 `cwd`）。
            // 空串 = 这台电脑没给 `cwd`，手机显示成「未关联项目」。
            cwd: row.cwd ?? '',
            tokens: usages[i]!.tokens,
          }))
          // 全零的会话不进榜：一张"0 tok"的行说的是"没数据"，不是"用了 0"。
          .filter((entry) => entry.tokens > 0)
          .sort((a, b) => b.tokens - a.tokens),
      }
    }
  }

  // 工作区面：会话列表**按它分组**（Web 的侧栏就是 工作区 → 会话）。
  // **按能力位挂**：缺 `workspaceController` 时这个方法不出现，手机的列表
  // 退回不分组 —— 如实降级，而不是按 `cwd` 猜一个分组。
  if (deps.workspaces !== undefined) {
    // 这个面的五种返回体都是"一串会话 id"，而**换别名的规则只有一份**：
    // `WorkspaceView.sessionIds` / `archivedSessionIds` / `pinnedSessionIds`
    // 都是 DSH 的 id，手机与中继只见 `sid`（与 `session.list` 同一条纪律）。
    // 同一份载荷里只换一半 = 手机拿到一串它不认识的 id，分组/归档/置顶全对不上。
    const aliased = (ids: readonly string[]) =>
      Promise.all(ids.map((id) => deps.aliases.ensure(id)))

    handlers['workspace.list'] = async () => {
      const snapshot = await deps.workspaces!.list()
      const workspaces = await Promise.all(
        snapshot.workspaces.map(async (row) => ({
          workspaceId: row.workspaceId,
          title: row.title,
          path: row.path,
          sessionIds: await aliased(row.sessionIds),
        })),
      )
      // 归档集与置顶集各多一列；三列一起换，不留下"半份别名"。
      return {
        workspaces,
        archivedSessionIds: await aliased(snapshot.archivedSessionIds),
        pinnedSessionIds: await aliased(snapshot.pinnedSessionIds),
      }
    }

    // 同工作区内重排（DOM insertBefore 语义）。**不改归属**：跨工作区的移动
    // 会被宿主拒成 `workspace/move-invalid`（`commands.ts:137-149`）。
    // 连接器不吞它、也不改写成"成功"；这个码不在手机的封闭错误表里，
    // 所以手机收到的是 `internal` + **宿主原文**（`protocol/methods.ts:265-275`）。
    handlers['workspace.insertSessionBefore'] = async (params) => {
      const workspaceId = requireString(params, 'workspaceId')
      const dshSessionId = requireSession(requireSid(params))
      // 锚点可选：不给 = 追加到末尾（`types.ts:107-112`）。给了就必须是**能解出
      // DSH id 的别名** —— 认不出就是 `session/not-found`，与其它方法同一条。
      const beforeSessionId =
        paramOf(params, 'beforeSid') === undefined
          ? undefined
          : requireSession(requireString(params, 'beforeSid'))
      const order = await deps.workspaces!.insertSessionBefore(
        workspaceId,
        dshSessionId,
        beforeSessionId,
      )
      return { sessionIds: await aliased(order) }
    }

    // 工作区排序（拖动侧栏的项目头）。与上面那条的区别：那条改**组内会话**顺序，
    // 这条改**工作区自己**的顺序。工作区 id 不是别名（`workspace.list` 也原样给），
    // 所以不过 `aliased` —— 返回的是**整份** `{workspaceIds}`。
    handlers['workspace.insertBefore'] = async (params) => {
      const workspaceId = requireString(params, 'workspaceId')
      const beforeWorkspaceId =
        paramOf(params, 'beforeWorkspaceId') === undefined
          ? undefined
          : requireString(params, 'beforeWorkspaceId')
      return {
        workspaceIds: await deps.workspaces!.insertBefore(
          workspaceId,
          beforeWorkspaceId,
        ),
      }
    }

    handlers['workspace.pin'] = async (params) => ({
      pinnedSessionIds: await aliased(
        await deps.workspaces!.pin(requireSession(requireSid(params))),
      ),
    })

    handlers['workspace.unpin'] = async (params) => ({
      pinnedSessionIds: await aliased(
        await deps.workspaces!.unpin(requireSession(requireSid(params))),
      ),
    })

    // 归档 / 取消归档。**写路径就这两个**，各自带幂等键（`IDEMPOTENT_METHODS`）：
    // 归档是用户指令，重发不该落两次（虽然宿主侧幂等，但指令层不该靠它兜）。
    // 归档运行中的会话会被宿主拒成 `workspace/session-active`（`commands.ts:160-167`）——
    // 那是**信息**不是故障：Web 因此弹"停止并归档"对话，带 `stopActivity` 重试
    // （`ui-workspace/src/client/index.ts:190-208`）。这里照同一条，把开关过线；
    // 那个码在 `ERROR_TABLE` 里，所以它**原样到手机**（`dsh/workspaces.ts` 的
    // `asProtocolError`），不是 `internal`。
    handlers['workspace.archive'] = async (params) => {
      const dshSessionId = requireSession(requireSid(params))
      const stopActivity = paramOf(params, 'stopActivity') === true
      return {
        archivedSessionIds: await aliased(
          await deps.workspaces!.archive(dshSessionId, stopActivity),
        ),
      }
    }

    handlers['workspace.unarchive'] = async (params) => ({
      archivedSessionIds: await aliased(
        await deps.workspaces!.unarchive(requireSession(requireSid(params))),
      ),
    })
  }

  // 权限预设：清单与写路径都按能力位挂（`dsh/permissions.ts` 的文件头列了三个服务键）。
  if (deps.permissions !== undefined) {
    const permissions = deps.permissions
    handlers['permission.catalog'] = async () => {
      const catalog = await permissions.catalog()
      // 与 `session.modelCatalog` 同一条纪律：拿不到就**明说**，不给空数组 ——
      // 空数组会被手机读成"没有可用预设"，而真实原因可能是这个部署没配预设表。
      if (catalog === undefined) return { available: false }
      return { available: true, catalog }
    }

    // 切权限。**带幂等键**（`IDEMPOTENT_METHODS`）—— 分发前就拦，所以这里一定拿得到，
    // 不需要再查一遍（与 `session.select-model` 同一个口径）。
    handlers['permission.switch'] = async (params) => {
      const sid = requireSid(params)
      requireSession(sid)
      const preset = requireString(params, 'preset')
      // 边界校验：`preset` 被拼进 `/permission <preset>` 这条命令行。
      // 已核实 DSH 的 `parseCommand` 只把命令名之后的所有内容当 `rawInput`
      // （`interaction/commands/src/index.ts:125-132`），所以换行**变不成第二条命令**；
      // 但空串与首尾空白必须在这里拦掉：空串会让 DSH 回"当前预设是 X"
      // （`permission-presets/src/index.ts:266-268`），那是一次**假的切换成功**。
      if (preset.trim() === '' || preset !== preset.trim()) {
        throw new ProtocolError('protocol/bad-frame', 'preset 必须是非空且不带首尾空白的字符串')
      }
      return permissions.switchTo(sid, preset)
    }
  }

  // 通用命令门：**白名单里的命令才放行**（判据见文件头 `MOBILE_COMMANDS`）。
  // 与 Web 同一个 DSH 方法（`commands.execute`，`interaction/commands/src/index.ts:360`；
  // Web 侧 `session-controller/.../session.ts:388`），执行那段在 `dsh/command-line.ts`。
  if (deps.commandLine !== undefined) {
    const commandLine = deps.commandLine
    // **带幂等键**（`IDEMPOTENT_METHODS`）：分发前就拦，所以这里一定拿得到。
    // 键只保证"同一次重发不跑两遍"（同键合流 / 24 h 内命中缓存）；崩溃窗口里的
    // 重发靠的是白名单那三条判据里的第 2 条（处理器自己认得出重复）。
    handlers['command.execute'] = async (params) => {
      const sid = requireSid(params)
      requireSession(sid)
      const line = requireString(params, 'line')
      // 手机输入框是单行；换行会让一条命令变成"命令 + 一段 rawInput"，
      // 而 DSH 的 `parseCommand` 只认行首那一条（`index.ts:126` 的正则不跨行）。
      // 与其让它悄悄进 rawInput，不如在这里拦掉。
      if (/[\r\n]/.test(line)) {
        throw new ProtocolError('protocol/bad-frame', 'line 不能包含换行')
      }
      const name = commandNameOf(line)
      if (name !== undefined && !MOBILE_COMMANDS.has(name)) {
        // **不是 `matched:false`**：那个值让手机按"电脑不认识"退成普通消息，
        // 等于把 `/compact` 悄悄当消息发出去 —— 正是本轮要消灭的形状。
        // 也不是 `protocol/bad-frame`：请求本身合法，是**这台手机**没有这个动作。
        throw new ProtocolError(
          'connector/unsupported',
          `手机上的命令面只放 ${MOBILE_COMMAND_LIST}：/${name} 不在其中`,
        )
      }
      // 名字解析不出（`/etc/passwd 是啥` 这种）就交给宿主：它会回 `undefined`，
      // 手机按 Web 的同一条推导退成普通消息（`machine.ts:170-175`）。
      return commandLine.run(sid, line)
    }
  }

  // 可选服务的方法**按需挂**：表里没有它，`repo.info` 自然也不会报它（契约 §7 的能力位模型）。
  // Agent 预设：只有目录这一个读面（写路径是 `session.create({agentPreset})`）。
  if (deps.agentPresets !== undefined) {
    const presets = deps.agentPresets
    handlers['agentPresets.list'] = async () => {
      const roster = await presets.roster()
      // 与 `permission.catalog` 同一条纪律：拿不到就**明说**，不给空数组 ——
      // 空数组会被手机读成"这个部署一个预设都没有"，而真实原因可能是服务没起来。
      if (roster === undefined) return { available: false }
      return { available: true, roster }
    }
  }

  // 设置面：三行设置（默认权限档 / 默认预设 / Session Log）的读写。
  // 范围由 `dsh/settings-face.ts` 的两张 allowlist 定，越界回 `gateway/bad-request`。
  if (deps.settings !== undefined) {
    const settings = deps.settings

    // 读：手机点名要哪几个 ns。不在可读 allowlist 里的**静默跳过**（问多了不该报错）。
    handlers['settings.describe'] = (params) => {
      const namespaces = stringArray(params, 'namespaces')
      return { sections: settings.describe(namespaces) }
    }

    // 写：**只发新值**（`mutate` 的 `{op:'set'}`），带 `expectedRevision` 乐观锁。
    // 返回改完之后的快照 —— 手机据此刷新那一行，不必自己猜。
    handlers['settings.update'] = async (params) => {
      const ns = requireString(params, 'ns')
      const path = stringArray(params, 'path')
      if (path.length === 0) {
        throw new ProtocolError('gateway/bad-request', 'path 不能是空数组')
      }
      try {
        const section = await settings.update({
          ns,
          path,
          value: (params as Record<string, unknown>).value,
          expectedRevision: (params as Record<string, unknown>).expectedRevision,
        })
        return { section: section ?? null }
      } catch (error) {
        if (error instanceof SettingsScopeError) {
          throw new ProtocolError('gateway/bad-request', error.message)
        }
        if (error instanceof SettingsConflictError) {
          throw new ProtocolError('settings/conflict', error.message)
        }
        throw error
      }
    }
  }

  // `@` 的两个候选面（契约 §5.7）。**两个都必须挂**才给 `caps.references`，
  // 判据在 `dsh/caps.ts` 的 `referencesAvailable`（与装配层同一个函数）。
  //
  // `query` 允许空串：用户刚打完一个 `@` 时就是"这个目录下有什么"，
  // 空串不是缺陷。形状不对才是 `protocol/bad-frame` —— 形状校验在**方法面**做，
  // 与 `sid` 同一条纪律。
  if (deps.references !== undefined) {
    const references = deps.references
    /** `{sid, query}`：`query` 必须是字符串（可以是空串），**不做长度/字符裁剪**。 */
    const queryOf = (params: unknown): string => {
      const query = paramOf(params, 'query')
      if (typeof query !== 'string') {
        throw new ProtocolError('protocol/bad-frame', 'query 必须是字符串（可以是空串）')
      }
      return query
    }

    handlers['refs.files'] = async (params) => {
      const sid = requireSid(params)
      return { files: await references.files(sid, queryOf(params)) }
    }

    handlers['refs.sessions'] = async (params) => {
      const sid = requireSid(params)
      return { sessions: await references.sessions(sid, queryOf(params)) }
    }
  }

  if (deps.jobs !== undefined) {
    const jobs = deps.jobs
    handlers['job.list'] = (params) => {
      const dshSessionId = requireSession(requireSid(params))
      return {
        // 适配器给的行**就是**给手机的形状（同一个投影：`protocol/job-output.ts` 的 `JobRowView`），
        // 这里不再抄一遍字段 —— 抄一遍就多一处会漂移的地方。
        jobs: jobs.listOwnedBy(dshSessionId),
      }
    }
  }

  if (deps.jobControl !== undefined) {
    const control = deps.jobControl
    handlers['job.kill'] = (params) => {
      const dshSessionId = requireSession(requireSid(params))
      const jobId = requireString(params, 'jobId')
      // 归属围栏与取消原因都在宿主门面里（见 `dsh/jobs.ts`）；这里只把它的结论转达给手机。
      return { outcome: control.kill(dshSessionId, jobId) }
    }
  }

  if (deps.sessionSubscriptions !== undefined) {
    const subscriptions = deps.sessionSubscriptions
    handlers['session.subscribe'] = async (params) => {
      const sid = requireSid(params)
      const dshSessionId = requireSession(sid)
      const since = paramOf(params, 'since')
      if (since !== undefined && (typeof since !== 'number' || !Number.isSafeInteger(since) || since < 0)) {
        throw new ProtocolError('protocol/bad-frame', 'since 必须是非负整数')
      }
      // 回的是**基线水位**与"还有没有更早的历史"：手机据此重订与决定要不要 `session.page`。
      return subscriptions.subscribe({
        sid,
        dshSessionId,
        ...(since === undefined ? {} : { since }),
      })
    }

    handlers['session.unsubscribe'] = (params) => {
      const sid = requireSid(params)
      requireSession(sid)
      return { stopped: subscriptions.unsubscribe(sid) }
    }

    /**
     * `sync.hello`：恢复握手 + **前后台态声明**（契约 §5.4、§6.2）。
     *
     * 它与 `session.subscribe` 的分工（§5.4 的评估原文）：`subscribe(sid, since)` 是
     * **单会话**增量入口，而 `sync.hello` 做两件它做不到的事 —— ① 一次声明整份订阅集
     * （手机回到前台时要恢复的是"所有会话"，不是一个）；② 上报前后台态。
     *
     * 所以它**不另起一套恢复语义**：每个声明的会话都走同一个
     * `sessionSubscriptions.subscribe`（增量优先、缓冲补发、开启帧水位全在同一处），
     * 本方法只做"批量入口 + 应用态声明"。翻译层就是漂移层，批量入口也不例外。
     *
     * 失败语义与 `session.subscribe` **逐字一致**（一个别名未知就整票失败并回
     * `session/not-found`）：它的客户端动作正是「从列表移除」，对一条过期声明是对的；
     * 而"部分成功"会让同一个操作有两种失败形状，那是漂移的口子。
     */
    handlers['sync.hello'] = async (params) => {
      const app = paramOf(params, 'app')
      if (app !== 'foreground' && app !== 'background') {
        throw new ProtocolError('protocol/bad-frame', 'sync.hello 的 app 必须是 foreground 或 background')
      }
      const raw = paramOf(params, 'sessions')
      if (!Array.isArray(raw)) {
        throw new ProtocolError('protocol/bad-frame', 'sync.hello 的 sessions 必须是数组')
      }
      const declared: { sid: string; since?: number }[] = []
      for (const entry of raw) {
        if (typeof entry !== 'object' || entry === null) {
          throw new ProtocolError('protocol/bad-frame', 'sessions 的每一项必须是对象')
        }
        const record = entry as Record<string, unknown>
        const sid = record['sid']
        if (typeof sid !== 'string' || sid === '') {
          throw new ProtocolError('protocol/bad-frame', 'sessions 的每一项都要带 sid')
        }
        const since = record['since']
        if (since !== undefined && (typeof since !== 'number' || !Number.isSafeInteger(since) || since < 0)) {
          throw new ProtocolError('protocol/bad-frame', 'since 必须是非负整数')
        }
        declared.push({ sid, ...(since === undefined ? {} : { since }) })
      }

      // **前后台态在订阅之前上报**：`foreground` 档的 claim 判据是"前台且已订阅该 sid"，
      // 顺序反了会出现一段"已订阅但仍判不在前台"的窗口（审批被让回桌面）。
      const connection = deps.connection
      const devId = connection?.deviceId() ?? null
      if (connection !== undefined && devId !== null) {
        connection.presence.app(devId, app)
      }

      const sessions: { sid: string; since: number; hasMore: boolean }[] = []
      for (const item of declared) {
        const dshSessionId = requireSession(item.sid)
        const reply = await subscriptions.subscribe({
          sid: item.sid,
          dshSessionId,
          ...(item.since === undefined ? {} : { since: item.since }),
        })
        sessions.push({ sid: item.sid, since: reply.since, hasMore: reply.hasMore })
      }
      return { app, sessions }
    }
  }

  if (deps.interaction !== undefined) {
    const face = deps.interaction
    /**
     * `interaction.respond`：提问 / 计划审查的答案批次，**也收束在途的审批 claim**。
     *
     * 为什么一个方法对两个目的地：契约 §5.7 只定义了这一个应答入口，而
     * §6.3.1 的两条路径在 DSH 侧本来就是同一个形状（答案批次）。分叉点不在方法名上，
     * 而在"这一项是不是一次在途的审批 claim"—— 那个判据只有挂载级的端口知道，
     * 所以它作为 {@link InteractionFaceDeps.settleApproval} 注进内核，
     * 在形状校验之后、路由到 DSH 之前问一次。
     *
     * `lastInteractedAt` 记在**这里**而不是内核里：它需要"哪台设备说的"，
     * 而那是每连接的知识。时间戳由**连接器**盖（不信任手机时钟 ——
     * 这个值只喂仲裁排序的一个并列判据，客户端时钟漂移会让排序随设备漂）。
     */
    handlers['interaction.respond'] = (params) => {
      // 只读 peek，不做校验：形状判据全在内核里（那里才是唯一一处），
      // 这里只为"哪台设备在哪个会话上答了话"取一个键。取不到就不记，不报错。
      const peeked = typeof params === 'object' && params !== null
        ? (params as Record<string, unknown>)['sid']
        : undefined
      const connection = deps.connection
      const devId = connection?.deviceId() ?? null
      if (connection !== undefined && devId !== null && typeof peeked === 'string' && peeked !== '') {
        connection.presence.interacted(devId, peeked, Date.now())
      }
      return face.respond(params)
    }
  }

  if (deps.sessionPager !== undefined) {
    const pager = deps.sessionPager
    handlers['session.page'] = async (params) => {
      const sid = requireSid(params)
      const dshSessionId = requireSession(sid)
      const beforeSeq = optionalCount(params, 'beforeSeq')
      const maxMessages = optionalCount(params, 'maxMessages')
      return pager.page({
        sid,
        dshSessionId,
        ...(beforeSeq === undefined ? {} : { beforeSeq }),
        ...(maxMessages === undefined ? {} : { maxMessages }),
      })
    }

    handlers['session.refetch'] = (params) => {
      const sid = requireSid(params)
      const dshSessionId = requireSession(sid)
      const seq = optionalCount(params, 'seq')
      if (seq === undefined) {
        throw new ProtocolError('protocol/bad-frame', 'seq 必填')
      }
      return pager.refetch({ sid, dshSessionId, seq })
    }
  }

  if (deps.jobSubscriptions !== undefined) {
    const subscriptions = deps.jobSubscriptions
    handlers['job.follow'] = async (params) => {
      const sid = requireSid(params)
      const dshSessionId = requireSession(sid)
      const jobId = requireString(params, 'jobId')
      const from = paramOf(params, 'from')
      if (from !== undefined && (typeof from !== 'number' || !Number.isSafeInteger(from) || from < 0)) {
        // 偏移是**绝对字节下标**：负数或小数说明对端理解错了协议，早点吵比拿它去读盘好。
        throw new ProtocolError('protocol/bad-frame', 'from 必须是非负整数')
      }
      return subscriptions.follow({
        sid,
        dshSessionId,
        jobId,
        ...(from === undefined ? {} : { from }),
      })
    }

    handlers['job.unfollow'] = (params) => {
      const sid = requireSid(params)
      requireSession(sid)
      const jobId = requireString(params, 'jobId')
      return { stopped: subscriptions.unfollow(sid, jobId) }
    }
  }

  // `repo.info` 最后挂：它报的 `methods` 就是这张表的键，所以它必须看得见全部兄弟。
  handlers['repo.info'] = () => ({
    /** 线上协议版本（`v` 字段的取值）。它才是兼容性判据。 */
    protocol: WIRE_VERSION,
    caps: deps.caps(),
    aliasVersion: deps.aliasVersion(),
    // **宿主运行时的 DSH 版本**（见 `dsh/host-version.ts`）：取不到就**不报这个字段**
    // —— 手机那边显示"未读到"，而不是一个看起来合理的假版本号。
    ...(deps.dshVersion === undefined || deps.dshVersion() === undefined
      ? {}
      : { dshVersion: deps.dshVersion() }),
    methods: Object.keys(handlers).sort(),
    // **斜杠命令白名单原样过线**（候选菜单用）。仍然是**一处**真值：
    // 手机上那张菜单只画这里给的名字，加/减一个名字不需要改手机。
    // **只在 `command.execute` 真的挂上时才报**：报一个调不通的名字，就是
    // 契约 §5.7 表后那句"多一个必然失败的按钮"。
    ...(handlers['command.execute'] === undefined
      ? {}
      : { commands: [...MOBILE_COMMANDS] }),
  })

  return handlers
}
