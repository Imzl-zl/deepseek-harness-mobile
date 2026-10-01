/**
 * 中转的 HTTP 面（契约 §2 的连接建立、§12.1 的出码登记）。
 *
 * 这里只做**请求 → 判定 → 响应**，不碰 HTTP 服务器：`ws` 与 `http` 的接线是薄薄一层，
 * 而"什么令牌换什么票、什么情况该拒"才是会被反复改、也最该被单测盯住的部分。
 *
 * ## 两个端点，两种凭据
 *
 * | 端点 | 谁调 | 拿什么认证 | 干什么 |
 * |---|---|---|---|
 * | `POST /ws-ticket` | 手机 | 设备令牌（§12.2 的摘要比对） | 用 `codeHash` 认领连接器 → 换一张一次性票 |
 * | `POST /pairing/register` | 电脑侧 | 连接器令牌 | 出码时把自己的 `codeHash` 登记给中转 |
 *
 * 两个端点**都不接受配对码**：手机送 `codeHash`、电脑侧登记 `codeHash` ——
 * 中转从头到尾没见过码（§12 的中转表里那一列就叫 `code_hash`）。
 *
 * ## 状态码的选择（客户端要按它分行为，不是随手写的）
 *
 * - `401` 令牌不对：**不要重试同一个令牌**，要么换票要么重新配对。
 * - `409` 配对登记不可用（没登记 / 已过期 / 已被认领 / 连接器离线）：手机该显示
 *   "请让电脑重新出码"，而**不是**"网络错误"。
 * - `400` 请求本身不合法（缺字段、JSON 坏）。与 `409` 分开：一个是"你发错了"，
 *   一个是"你要的东西现在没有"。
 *
 * `409` 里**不细分**原因：那几种处境对手机是同一件事（让电脑重新出码），
 * 细分只会让客户端多几个永远走不到的分支。
 */
import type { RelayCore } from './core.js'
import type { TicketStore } from './tickets.js'
import type { ChannelLogger } from './logger.js'

/** 已认证的调用方。`kind` 决定它能调哪些端点。 */
export interface Authenticated {
  kind: 'device' | 'connector'
  id: string
}

export interface HttpFaceOptions {
  tickets: TicketStore
  core: RelayCore
  /**
   * 校验令牌（实现方去查摘要表，§12.2）。
   *
   * 做成端口是因为**令牌存在哪里**还没有落地（中转的库属于另一块）；
   * 而"校验失败一律 401"这条判定在这里就定死，不必等库。
   */
  authenticate: (token: string) => Authenticated | undefined
  log?: ChannelLogger
}

export interface HttpRequest {
  method: string
  path: string
  /** `Authorization: Bearer <token>` 里的令牌。 */
  token?: string
  body?: unknown
}

export interface HttpResponse {
  status: number
  body?: unknown
}

export interface HttpFace {
  handle(request: HttpRequest): HttpResponse
}

export function createHttpFace(options: HttpFaceOptions): HttpFace {
  const { tickets, core, authenticate, log } = options

  return {
    handle(request) {
      if (request.method !== 'POST') {
        return { status: 405, body: { error: 'method-not-allowed' } }
      }

      const token = request.token
      const caller = token === undefined || token === '' ? undefined : authenticate(token)
      if (caller === undefined) {
        // 401：令牌不对。客户端据此换票/重配，而不是拿同一个令牌重试。
        log?.debug(`拒绝 ${request.path}：令牌无效或缺失`)
        return { status: 401, body: { error: 'unauthorized' } }
      }

      const body =
        typeof request.body === 'object' && request.body !== null
          ? (request.body as Record<string, unknown>)
          : {}
      const codeHash = typeof body['codeHash'] === 'string' ? body['codeHash'] : ''

      if (request.path === '/ws-ticket') {
        if (caller.kind !== 'device') {
          // 连接器不该来换设备票：它是长连的一条连接，不走这个端点（契约 §2）。
          return { status: 403, body: { error: 'wrong-credential-kind' } }
        }
        if (codeHash === '') return { status: 400, body: { error: 'codeHash-required' } }

        const connectorId = core.claimTicket(caller.id, codeHash)
        if (connectorId === undefined) {
          // 409：配对登记不可用（没登记/过期/已认领/连接器离线）。
          // 对手机都是同一件事（让电脑重新出码），所以不细分。
          return { status: 409, body: { error: 'pairing-unavailable' } }
        }
        const issued = tickets.issue(caller.id)
        log?.info(`设备 ${caller.id} 换到票，绑定连接器 ${connectorId}`)
        // 票值**只在这里返回**：中转不留明文，日志也不打它。
        return { status: 201, body: { ticket: issued.ticket, expiresAt: issued.expiresAt } }
      }

      if (request.path === '/pairing/register') {
        if (caller.kind !== 'connector') {
          return { status: 403, body: { error: 'wrong-credential-kind' } }
        }
        if (codeHash === '') return { status: 400, body: { error: 'codeHash-required' } }
        const expiresAt = core.registerPairing(caller.id, codeHash)
        return { status: 201, body: { expiresAt } }
      }

      return { status: 404, body: { error: 'not-found' } }
    },
  }
}
