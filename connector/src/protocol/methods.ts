/**
 * 方法面：信封、封闭方法集与分发（契约 §5.7）。
 *
 * 三条规则在这里被做成代码，而不是留给每个 handler 自己记得：
 *
 * 1. **方法名是封闭集**。不认识的方法回 `connector/unsupported`（能力不存在），
 *    而不是抛错断连 —— 手机端据此置灰按钮，不用错误码试探。
 * 2. **标了幂等键的方法必须带键**。§5.7 的表里 `session.prompt` / `interaction.respond` /
 *    `settings.update` / `credentials.set|unset` 都带键；漏了键的重发会变成**第二条消息**
 *    或**第二次授权**，那正是不变量 I8 要防的。所以在分发前就拦下，别指望 handler 自己查。
 * 3. **结构化错误不关连接**（§9）。分发器**从不抛**：所有失败都变成 `ok:false` 的信封。
 *    连接层的关闭只留给协议级错误（帧不合法、重放、握手未完成）。
 */
import { isErrorCode, ProtocolError, type ErrorCode } from './errors.js'

/** 契约 §5.7 的方法表。顺序与文档一致，便于对照。 */
/**
 * 契约 §5.7 的方法表。**与契约逐字对应**(顺序也一致,便于对照)。
 *
 * 契约里没有的,这里也不要有:`isMethod` 放行一个契约外的方法,分发器只会回
 * `connector/unsupported`——那会让"这个方法不存在"看起来像"这个方法还没实现",
 * 而手机上多一个必然失败的按钮。所以 2026-10-09 把三个已从契约删掉的名字
 * 一并清了出去:`interaction.list`(待处理集合是投影,没有独立查询)、
 * `devices.revoke`(吊销不是方法,名册写入方本来就是电脑侧)、
 * `push.configure`(推送本期不做,调不通)。
 */
export const METHODS = [
  'session.create',
  'session.list',
  'session.subscribe',
  'session.unsubscribe',
  'session.page',
  'session.prompt',
  'session.cancel',
  'session.refetch',
  // 模型目录：只读。手机据此建选择器，显示的名字与电脑侧同一份真值
  // （DSH 的 `session/modelCatalog`，见 `dsh/models.ts` 的文件头）。
  'session.modelCatalog',
  // 切这个会话的模型。**与 Web 用同一个 DSH 方法**（`session/select-model`），
  // 没有第二套接口 —— 已核实 Web 侧调的就是它
  // （`packages/client/ui-model-selection/src/client/directory.ts:98`）。
  // 语义见 `dsh/sessions.ts` 的 `selectModel` 注释：当前会话立即生效、
  // 以后新建的 agent 默认跟随、**不改别的会话**。
  'session.select-model',
  // 会话投影：**一个方法打开全部只读面**（模型选择 / 权限档 / 子智能体目录 /
  // 交付物 / token 用量 / 统计 / 轨迹 / 待办 / 目标 / 计划 …）。
  // 为什么不是每面一个方法，见 `dsh/projections.ts` 的文件头。
  'session.projections',
  // 权限预设清单（只读）。**与 Web 同一个 DSH 方法**：
  // `permissionPresets.catalog()`（`@Remote('catalog')`，
  // `packages/interaction/permission-presets/src/index.ts:292`）。
  // 预设表是**部署可配**的（`bundle/base/cordis.patch.yml:262-271`），
  // 所以名单只能从电脑侧取，手抄一份就是第二份真值。
  'permission.catalog',
  // 切这个会话的权限预设。写路径是 DSH 的 `/permission <档位>` 斜杠命令
  // （`permission-presets/src/index.ts:255-276`，DSH 注释原话
  // "the one write path a web client uses"），Web 侧经
  // `remote.commands.execute` 调它（`ui-permission-presets/src/client/index.ts:126`）。
  // 当前值不走这个方法读 —— 它在 `permissions` 投影里，随 `session.projections` 到手机。
  'permission.switch',
  'interaction.respond',
  'job.list',
  'job.follow',
  'job.unfollow',
  'job.kill',
  'settings.describe',
  'settings.update',
  'credentials.set',
  'credentials.unset',
  'devices.list',
  // 端点自报：当前可拨的地址表（中转 + 局域网直连）。只读。
  // 手机据此建"连接方式"列表，并在 IP 变了之后自愈 —— 详见 `endpoints.ts` 的文件头。
  'endpoint.describe',
  'sync.hello',
  'repo.info',
] as const

export type MethodName = (typeof METHODS)[number]

const METHOD_SET: ReadonlySet<string> = new Set(METHODS)

/**
 * 带幂等键的方法（§5.7 的「幂等键」列非空的那几个）。
 *
 * `interaction.respond` 的键形状特殊（`i:<callId>`，载荷是答案批次而非标量决策），
 * 所以它由 handler 自己组装（见 `recovery.ts` 的 `answer`）——
 * 这里只要求**必须带**一个键。
 */
export const IDEMPOTENT_METHODS: ReadonlySet<MethodName> = new Set([
  'session.create',
  'session.prompt',
  'session.select-model',
  // 切权限是用户指令：重发不该落两条 `command/run` / `command/done`
  // 生命周期事件，也不该把预设应用两遍。
  'permission.switch',
  'interaction.respond',
  'settings.update',
  'credentials.set',
  'credentials.unset',
])

export function isMethod(value: unknown): value is MethodName {
  return typeof value === 'string' && METHOD_SET.has(value)
}

export function requiresIdempotencyKey(method: MethodName): boolean {
  return IDEMPOTENT_METHODS.has(method)
}

/** 手机 → 电脑的请求信封（封在 `box` 里）。 */
export interface RequestEnvelope {
  method: string
  params?: unknown
  /** 幂等键；哪些方法必须带见 {@link IDEMPOTENT_METHODS}。 */
  requestId?: string
}

/** 电脑 → 手机的应答信封。**失败也是一个正常应答**，不是断连理由。 */
export type ResponseEnvelope =
  | { ok: true; result: unknown }
  | { ok: false; code: ErrorCode; message?: string }

/** 解析请求信封。**只解析形状**；方法是否认识留给分发器（那样能回 unsupported 而不是断连）。 */
export function decodeRequest(box: string): RequestEnvelope {
  let parsed: unknown
  try {
    parsed = JSON.parse(box)
  } catch (error) {
    throw new ProtocolError('protocol/bad-frame', `请求载荷不是合法 JSON：${String(error)}`)
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new ProtocolError('protocol/bad-frame', '请求载荷必须是 JSON 对象')
  }
  const record = parsed as Record<string, unknown>
  const method = record['method']
  if (typeof method !== 'string' || method === '') {
    throw new ProtocolError('protocol/bad-frame', '请求载荷缺少 method')
  }
  const requestId = record['requestId']
  if (requestId !== undefined && (typeof requestId !== 'string' || requestId === '')) {
    throw new ProtocolError('protocol/bad-frame', 'requestId 必须是非空字符串')
  }
  return {
    method,
    ...(requestId === undefined ? {} : { requestId }),
    ...(record['params'] === undefined ? {} : { params: record['params'] }),
  }
}

export interface DispatchContext {
  requestId?: string
  /** 会话别名（帧头带来的，不在信封里）。 */
  sid?: string
}

export type MethodHandler = (
  params: unknown,
  context: DispatchContext,
) => Promise<unknown> | unknown

export interface Dispatcher {
  /** **从不抛**：所有失败都变成 `ok:false` 的信封。 */
  dispatch(request: RequestEnvelope, context?: DispatchContext): Promise<ResponseEnvelope>
  /** 已经实现了哪些方法（能力位与自检用）。 */
  readonly implemented: readonly MethodName[]
}

/**
 * @param handlers - 已实现的方法。表里没有的会回 `connector/unsupported`。
 */
export function createDispatcher(
  handlers: Partial<Record<MethodName, MethodHandler>>,
): Dispatcher {
  const implemented = METHODS.filter((method) => handlers[method] !== undefined)

  return {
    implemented,

    async dispatch(request, context = {}) {
      if (!isMethod(request.method)) {
        // 不认识的方法 = 能力不存在，**不是**协议错误。回结构化错误，连接留着。
        return {
          ok: false,
          code: 'connector/unsupported',
          message: `未知方法：${request.method}`,
        }
      }

      // 幂等键必须在分发前强制：漏键的重发会变成第二条消息 / 第二次授权（I8）。
      if (requiresIdempotencyKey(request.method) && request.requestId === undefined) {
        return {
          ok: false,
          code: 'protocol/bad-frame',
          message: `${request.method} 必须带 requestId（幂等键）`,
        }
      }

      const handler = handlers[request.method]
      if (handler === undefined) {
        return {
          ok: false,
          code: 'connector/unsupported',
          message: `${request.method} 尚未实现`,
        }
      }

      try {
        return {
          ok: true,
          result: await handler(request.params, {
            ...(request.requestId === undefined ? {} : { requestId: request.requestId }),
            ...context,
          }),
        }
      } catch (error) {
        // 结构化错误不关连接（§9）。协议错误保留它自己的码，其余归 internal。
        const code: ErrorCode = error instanceof ProtocolError && isErrorCode(error.code)
          ? error.code
          : 'internal'
        return {
          ok: false,
          code,
          message: error instanceof Error ? error.message : String(error),
        }
      }
    },
  }
}
