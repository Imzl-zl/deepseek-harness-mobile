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
import type { SessionSubscriptions } from './session-subscriptions.js'
import type { SessionSummaryRow } from './dsh/sessions.js'

/** 设备清单里的一行。**不含公钥** —— 手机不需要别人的公钥，少发一个字段就少一处泄漏面。 */
export interface DeviceRow {
  id: string
  name: string
  pairedAt: number
  /** 是否已吊销（电脑侧删公钥）。 */
  revoked: boolean
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
  /** 已配对设备（含已吊销的，便于手机显示"这台已被移除"）。 */
  devices: () => readonly DeviceRow[]
  /**
   * 会话清单（DSH 权威行，已按活动排序）。
   *
   * 依赖是**必需**的而不是可选的：`sessionController` 是本插件的必需服务
   * （缺了它插件根本不挂载），所以不存在"这个端口不在"的生产形态；
   * 把它写成可选只会多一条永远不会被走到的错误分支。
   */
  sessions: { list(signal?: AbortSignal): Promise<readonly SessionSummaryRow[]> }
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
}

export function createHandlers(deps: HandlerDeps): Partial<Record<MethodName, MethodHandler>> {
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

  /** 取一个非空字符串参数（`jobId` 之类）。 */
  const requireString = (params: unknown, key: string): string => {
    const value = paramOf(params, key)
    if (typeof value !== 'string' || value === '') {
      throw new ProtocolError('protocol/bad-frame', `${key} 必填`)
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

  const handlers: Partial<Record<MethodName, MethodHandler>> = {
    'devices.list': () => ({
      devices: deps.devices().map((row) => ({
        devId: row.id,
        name: row.name,
        pairedAt: row.pairedAt,
        revoked: row.revoked,
      })),
    }),

    'session.list': async () => {
      const rows = await deps.sessions.list()
      // 别名可以**并发**分配：不同会话之间互不影响，同一个会话则由 `ensure` 自己合流
      // （见 `alias.ts` 的说明）。逐字段构造给手机的行，**不 spread** ——
      // `dshSessionId` 绝不能过线（中继与手机只见 `sid`）。
      const assigned = await Promise.all(
        rows.map(async (row) => ({ row, sid: await deps.aliases.ensure(row.dshSessionId) })),
      )
      return {
        sessions: assigned.map(({ row, sid }) => ({
          sid,
          updatedAt: row.updatedAt,
          running: row.running,
          blank: row.blank,
          subagent: row.subagent,
          ...(row.cwd === undefined ? {} : { cwd: row.cwd }),
        })),
      }
    },
  }

  // 可选服务的方法**按需挂**：表里没有它，`repo.info` 自然也不会报它（契约 §7 的能力位模型）。
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
    methods: Object.keys(handlers).sort(),
  })

  return handlers
}
