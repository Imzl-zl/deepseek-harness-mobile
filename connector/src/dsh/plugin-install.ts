/**
 * 插件的安装 / 卸载 / 取消 / 看进度（契约 §5.7 的 `plugin.install*` / `plugin.remove`）。
 *
 * ## 为什么不直接等宿主跑完
 *
 * 宿主的 `installBundle` / `removeBundle` 会**跑 pnpm 并等它结束**
 * （`packages/boot/plugin-manager/src/index.ts:835-965`，`removeBundle` 在 `:999` 起）。
 * 一次真实安装常常远超契约 §10 的 60 s 请求超时，所以手机不能"发出去等结果"。
 *
 * 宿主的答案本来就有两半：`installBundle(spec, {requestId})` 把控制块按 `requestId`
 * 记进 `this.installs`（`:837-841`），另有 `waitForInstall(requestId)`（`:972`）与
 * `cancelInstall(requestId)`（`:982`）。所以这一层的形状是**发起即返回 + 轮询**：
 *
 * - `plugin.install {spec}` → 立刻回 `{requestId}`，`installBundle` 在后台跑；
 * - `plugin.installStatus {requestId}` → `running` / `done`（带结果）/ `unknown`；
 * - `plugin.cancelInstall {requestId}` → 宿主的 `cancelled | too-late | not-running` **原样**。
 *
 * `requestId` 就是**方法的幂等键**（`context.requestId`）：同一次操作重发不会起第二遍安装 ——
 * 与宿主"按 requestId 记控制块"用的是同一个 id，不另造。
 *
 * ## 进度从哪来：宿主的两个事件，不新开帧
 *
 * 宿主在跑的时候会发 `plugin-manager/install-state`（阶段）与
 * `plugin-manager/install-log`（pnpm 的每一块输出）
 * （`types.ts:396-406` 的事件声明、`:335-361` 的形状）。这一层在挂载时订阅它们、
 * **按 requestId 收进一个有界的内存尾窗**，`plugin.installStatus` 每次回窗口里的尾部几行 ——
 * **不新增帧类型**（手机轮询一个读方法，与 `session.projections` 同一种节奏）。
 *
 * 尾窗是**通道层参数**（描述我们这条帧的预算，不是业务语义）：单帧 8 MiB（契约 §40），
 * 装一次 pnpm 的输出可以很长，所以只留最后 [LOG_TAIL_CHARS] 个字符，并且**明说截断**。
 *
 * ## 不做的事
 *
 * - **不自己判能不能装**：版本兼容 / registry / pnpm 的错误宿主都有码
 *   （`ManagementError.code`，`types.ts:136-145`），原样给人话。
 * - **不做乐观状态**：安装是不是成功，只看结果的 `application`
 *   （`applied | restart-required | overridden | failed | cancelled`）。
 * - **不清理"太久的"记录**：只保留最近 [MAX_JOBS] 条（内存上界），不按时钟过期 ——
 *   时钟过期是我们自己发明的一条边界。
 */
import type { Context } from '@deepseek-ai/cordis'

import { ProtocolError } from '../protocol/errors.js'

/** `pluginManager` 的安装面（**按形状收窄、不 import DSH 类型**）。 */
interface PluginInstallService {
  installBundle(spec: string, options?: { requestId?: string }): Promise<unknown>
  removeBundle(name: string): Promise<unknown>
  cancelInstall(requestId: string): Promise<{ status?: unknown }>
}

/** 宿主事件订阅面（`ctx.on`，cordis 自带）。 */
interface HostEvents {
  on(event: string, listener: (payload: unknown) => void): () => void
}

/** 一次安装/卸载在手机眼里的状态。 */
export interface PluginJobStatus {
  requestId: string
  /** `running` = 还在跑；`done` = 已有结论；`unknown` = 这一代插件没有这个 id 的记录。 */
  status: 'running' | 'done' | 'unknown'
  /** 发起的是什么（`install` / `remove`）。 */
  kind?: 'install' | 'remove'
  /** 宿主的阶段（`installing` / `cancelling` / `applying`），原样。 */
  phase?: string
  /** pnpm 输出的**尾部**几行（已经按帧预算截过）。 */
  log: readonly string[]
  /** 日志是否被截（**截断要说**）。 */
  logTruncated: boolean
  /** `done` 时宿主的结论（逐字段，不翻译）。 */
  result?: PluginJobResult
  /** 宿主抛错时的原话（`done` 且失败才有）。 */
  error?: string
}

/** 一次安装/卸载的结论（宿主的 `ChangeResult` 里手机用得上的字段）。 */
export interface PluginJobResult {
  changed: boolean
  application: string
  stage: string
  target: string
  enabled?: boolean
  restartReason?: string
  /** 宿主的 `ManagementError.code`（`unknown-plugin` / `not-removable` / …）。 */
  errorCode?: string
  /** 安装出来的包名与版本（`installBundle` 才有）。 */
  bundle?: string
  version?: string
  /** pnpm 的退出码与输出尾部（`truncated` 照报）。 */
  exitCode?: number
  timedOut?: boolean
  outputTail?: string
  outputTruncated?: boolean
}

export interface PluginInstallFace {
  /** 发起安装；**立刻返回**，宿主在后台跑。 */
  install(spec: string, requestId: string): { requestId: string }
  /** 发起卸载；同上。 */
  remove(name: string, requestId: string): { requestId: string }
  /** 取消；宿主的三档状态原样。 */
  cancel(requestId: string): Promise<{ status: string }>
  /** 看一次进度/结论。 */
  status(requestId: string): PluginJobStatus
}

/**
 * 手机上能不能提交这个 spec —— **只允许 registry / git 来源，不许本机路径**。
 *
 * 为什么这条是**我们的政策**而不是宿主的：宿主 `installBundle` 收的是 `pnpm add` 的任意
 * spec，**包括相对 profile 目录的本地路径**（`index.ts:830-834` 的注释原话
 * "including local paths relative to the invocation directory"）。桌面上那是对的 ——
 * 人在电脑前、能看见自己装了什么；手机上不行：一个已配对的设备不该能指定
 * "装电脑上某个目录里的包"。
 *
 * 判据只看**形状**（不联网、不解析版本）：
 *
 * - 本地路径：`/`、`./`、`../`、`~`、盘符（`C:\` / `C:/`）、UNC（`\\`）、任何反斜杠、`file:`；
 * - registry / git：`name`、`@scope/name`、`name@1.2.3`、`git+https://…`、`git@host:path`、
 *   `https://…`、`github:user/repo`、`user/repo`（github 简写）全部放行；
 * - `-` 开头的（会被 `pnpm` 当选项）宿主自己也拒，这里先拒，省一次往返。
 *
 * **不是替宿主判"能不能装"**：版本兼容 / registry 可达性 / 构建脚本，仍然全由宿主说。
 */
export function installableFromPhone(spec: string): boolean {
  const value = spec.trim()
  if (value === '' || value.startsWith('-')) return false
  // 反斜杠只出现在 Windows 路径里（registry / git spec 不用它）。
  if (value.includes('\\')) return false
  if (value.startsWith('/') || value.startsWith('~')) return false
  if (value.startsWith('.') ) return false // `.` / `./x` / `../x`
  if (/^[A-Za-z]:[\\/]/u.test(value)) return false // 盘符路径
  if (/^file:/iu.test(value)) return false
  return true
}

/** 日志尾窗（**通道层参数**：单帧预算下的尾巴，不是业务规则）。 */
const LOG_TAIL_CHARS = 4000
/** 同时保留几条任务的记录（内存上界；按插入顺序淘汰最老的）。 */
const MAX_JOBS = 16

interface Job {
  kind: 'install' | 'remove'
  state: 'running' | 'done'
  phase: string
  log: string
  logTruncated: boolean
  result?: PluginJobResult
  error?: string
}

/**
 * 建安装面。
 *
 * 服务键走 `ctx.get`，缺席的判定在装配层（`index.ts` 按 `pluginsAvailable(ctx)`）；
 * 走到这里缺键只可能是装配写错了 —— 那时如实抛。
 */
export function createPluginInstallFace(ctx: Context): PluginInstallFace {
  /** `requestId → 任务`（插入顺序即淘汰顺序）。 */
  const jobs = new Map<string, Job>()

  const serviceOf = (): PluginInstallService => {
    const service = ctx.get('pluginManager') as PluginInstallService | undefined
    if (service === undefined) {
      throw new ProtocolError('internal', 'pluginManager 服务不在：插件的安装面不可用')
    }
    return service
  }

  /**
   * 宿主事件：阶段与日志。
   *
   * 只收**我们发起过的** requestId（手机不带 id 的安装不存在 —— 必带幂等键）。
   * 订阅是挂载级的（`ctx.on` 随 fiber 卸载），这里只留 disposer 给测试用。
   */
  const events = ctx as unknown as HostEvents
  const remember = (requestId: unknown, update: (job: Job) => void): void => {
    if (typeof requestId !== 'string' || requestId === '') return
    const job = jobs.get(requestId)
    if (job === undefined) return
    update(job)
  }
  events.on('plugin-manager/install-state', (payload) => {
    if (typeof payload !== 'object' || payload === null) return
    const record = payload as Record<string, unknown>
    remember(record['requestId'], (job) => {
      job.phase = typeof record['phase'] === 'string' ? record['phase'] : job.phase
    })
  })
  events.on('plugin-manager/install-log', (payload) => {
    if (typeof payload !== 'object' || payload === null) return
    const record = payload as Record<string, unknown>
    remember(record['requestId'], (job) => {
      const text = record['text']
      if (typeof text !== 'string' || text === '') return
      job.log += text
      if (job.log.length > LOG_TAIL_CHARS) {
        job.log = job.log.slice(job.log.length - LOG_TAIL_CHARS)
        job.logTruncated = true
      }
    })
  })

  /** 起一个任务：先记一条 `running`，再把宿主的 promise 挂到后台。 */
  const start = (
    kind: Job['kind'],
    requestId: string,
    run: () => Promise<unknown>,
  ): void => {
    if (jobs.size >= MAX_JOBS) {
      const oldest = jobs.keys().next()
      if (!oldest.done) jobs.delete(oldest.value)
    }
    const job: Job = { kind, state: 'running', phase: 'installing', log: '', logTruncated: false }
    jobs.set(requestId, job)
    // **不 await**：这是"发起即返回"的全部要点（真实安装远超 60 s 请求超时）。
    void run().then(
      (value) => {
        job.state = 'done'
        job.result = resultOf(value)
      },
      (error: unknown) => {
        job.state = 'done'
        job.error = error instanceof Error ? error.message : String(error)
      },
    )
  }

  return {
    install(spec, requestId) {
      const service = serviceOf()
      start('install', requestId, () => service.installBundle(spec, { requestId }))
      return { requestId }
    },

    remove(name, requestId) {
      const service = serviceOf()
      start('remove', requestId, () => service.removeBundle(name))
      return { requestId }
    },

    async cancel(requestId) {
      const reply = await serviceOf().cancelInstall(requestId)
      const status = typeof reply?.status === 'string' ? reply.status : 'not-running'
      return { status }
    },

    status(requestId) {
      const job = jobs.get(requestId)
      if (job === undefined) {
        return { requestId, status: 'unknown', log: [], logTruncated: false }
      }
      return {
        requestId,
        status: job.state,
        kind: job.kind,
        phase: job.phase,
        log: job.log === '' ? [] : job.log.split('\n').slice(-40),
        logTruncated: job.logTruncated,
        ...(job.result === undefined ? {} : { result: job.result }),
        ...(job.error === undefined ? {} : { error: job.error }),
      }
    },
  }
}

/** 宿主的 `ChangeResult` → 手机的形状（**逐字段构造**，`packageResult.output` 只留尾部）。 */
function resultOf(value: unknown): PluginJobResult {
  const record = typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}
  const error = record['error']
  const errorCode =
    typeof error === 'object' && error !== null && typeof (error as Record<string, unknown>)['code'] === 'string'
      ? ((error as Record<string, unknown>)['code'] as string)
      : undefined
  const pkg = record['packageResult']
  const pkgRecord = typeof pkg === 'object' && pkg !== null ? (pkg as Record<string, unknown>) : undefined
  const output = pkgRecord?.['output']
  const outputTail =
    typeof output === 'string' && output !== ''
      ? output.length > LOG_TAIL_CHARS
        ? output.slice(output.length - LOG_TAIL_CHARS)
        : output
      : undefined
  return {
    changed: record['changed'] === true,
    application: typeof record['application'] === 'string' ? record['application'] : 'unknown',
    stage: typeof record['stage'] === 'string' ? record['stage'] : '',
    target: typeof record['target'] === 'string' ? record['target'] : '',
    ...(record['enabled'] === true || record['enabled'] === false
      ? { enabled: record['enabled'] }
      : {}),
    ...(typeof record['restartReason'] === 'string' ? { restartReason: record['restartReason'] } : {}),
    ...(errorCode === undefined ? {} : { errorCode }),
    ...(typeof record['bundle'] === 'string' ? { bundle: record['bundle'] } : {}),
    ...(typeof record['version'] === 'string' ? { version: record['version'] } : {}),
    ...(pkgRecord === undefined
      ? {}
      : {
          ...(typeof pkgRecord['exitCode'] === 'number' ? { exitCode: pkgRecord['exitCode'] } : {}),
          ...(pkgRecord['timedOut'] === true ? { timedOut: true } : {}),
          ...(outputTail === undefined ? {} : { outputTail }),
          ...(typeof output === 'string'
            ? { outputTruncated: output.length > LOG_TAIL_CHARS }
            : {}),
        }),
  }
}
