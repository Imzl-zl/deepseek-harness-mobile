/**
 * 管理面的路由层：**只做分发与校验**，不认识 socket、也不改任何状态。
 *
 * 状态与动作由 `AdminApi` 注入（`server.ts` 装配）：这样路由可以脱离网络测，
 * 而"能改什么"只有一处定义。
 *
 * ## 边界的三个决定
 *
 * 1. **读是 GET、写是 POST 且必须带 JSON body**：不用表单（表单会被浏览器自动
 *    带上 cookie —— 我们本来就没有 cookie，但那层"顺手"不该被打开）。
 * 2. **主体只接受已有形状**（`user:<owner>` / `connector:<id>`）：面板不能成为
 *    新额度主体的入口，否则"键来自配置身份"这条有界性就没了。
 * 3. **每个写操作都回 `AdminResponse`**，由 `AdminApi` 决定成功/失败 —— 路由不猜
 *    "落盘失败该回什么"。
 */
import type { RelayEvent } from '../events.ts'
import type { TokenRow } from '../token-table.ts'

export interface AdminReply {
  status: number
  contentType: 'application/json' | 'text/html; charset=utf-8'
  body: string
}

export interface AdminRequest {
  method: string
  path: string
  body?: unknown
}

/** 用户行（管理台）：**没有摘要**，只有展示与策略字段。 */
export interface AdminUserRow {
  id: string
  email: string
  displayName: string
  role: 'admin' | 'user'
  status: 'active' | 'suspended'
  createdAt: number
  lastLoginAt: number | null
  maxConnectors: number
  quotaBytes: number | null
  connectors: number
  activeConnectors: number
  devices: number
  online: number
  usedBytes: number
}

/** 面板能看到的读面（形状由 `server.ts` 组）。 */
export interface AdminStateView {
  v: 1
  now: number
  /** 进程已运行毫秒数。 */
  uptimeMs: number
  /** 近 60 分钟整台服务的转发字节（面板曲线；最后一个是当前分钟）。 */
  traffic: { perMinute: readonly number[]; total: number }
  /** 最近事件（最新在前，最多 100 条；只有元数据）。 */
  events: readonly RelayEvent[]
  connectors: readonly {
    connectorId: string
    owner?: string
    since: number
    lastPongAt: number
    channels: number
  }[]
  channels: readonly {
    channelId: string
    connectorId: string
    deviceId: string
    purpose: string
    startedAt: number
    forwardedBytes: number
  }[]
  /** 列表封顶后的总数（面板据此说"共 N，显示前 500"）。 */
  totals: { connectors: number; channels: number }
  roster: { devices: number; bound: number; published: Readonly<Record<string, number>> }
  /** `limit === null` = 这个人不设上限（默认）。 */
  quota: { period: string; enforce: string; rows: readonly { subject: string; used: number; limit: number | null }[] } | null
  tokens: readonly TokenRow[]
  /** 连接器认证面：模式、名额上限（`null` = 无上限）与已自动签发的条数。 */
  connectorAuth: { mode: 'open' | 'required'; limit: number | null; autoCount: number }
  /** 账号模式下的用户清单（最多 500 行）。没开账号模式就是空数组。 */
  users: readonly AdminUserRow[]
  /** 账号模式的策略摘要；没开就是 `null`。 */
  auth: {
    mode: 'accounts'
    registration: string
    defaultMaxConnectors: number
    defaultQuotaBytes: number | null
  } | null
}

/** 写动作的落盘点（持久化在装配方：配置文件的写入不在这一层）。 */
export interface AdminOps {
  /** 读面用的令牌清单（不含摘要）。 */
  tokens(): readonly TokenRow[]
  /** 吊销 / 恢复一台连接器令牌；实现负责写回配置。 */
  setTokenEnabled(id: string, enabled: boolean): Promise<{ ok: boolean; error?: string }>
  /** **硬删除**一条已吊销的令牌记录（实现负责从配置里移除）。 */
  removeToken(id: string): Promise<{ ok: boolean; error?: string }>
  /** 把某人（`user:<owner>`）的新上限写回配置（`null` = 取消）；按连接器主体的覆盖不落盘。 */
  persistQuota(owner: string, bytes: number | null): Promise<{ ok: boolean; error?: string }>
  /**
   * 改「连接器是否必须认证」与自动签发名额（写回配置 + 运行时立即生效）。
   *
   * `limit === null` = 无上限（不预设人为限制）。
   */
  setConnectorAuth(mode: 'open' | 'required', limit: number | null): Promise<{ ok: boolean; error?: string }>
}

export interface AdminApi {
  /** 读面。每次轮询调一次，必须**同步**（不 await、不读盘）。 */
  state(): AdminStateView
  /** `bytes === null` = 取消上限（默认就是"不限"）。 */
  setQuota(subject: string, bytes: number | null): Promise<AdminReply>
  resetQuota(subject: string): Promise<AdminReply>
  disconnect(connectorId: string, deviceId?: string): Promise<AdminReply>
  setTokenEnabled(id: string, enabled: boolean): Promise<AdminReply>
  removeToken(id: string): Promise<AdminReply>
  setConnectorAuth(mode: 'open' | 'required', limit: number | null): Promise<AdminReply>
  /** 停用 / 恢复一个账号；停用会立刻收掉它名下所有连接。 */
  setUserStatus(id: string, status: 'active' | 'suspended'): Promise<AdminReply>
  setUserRole(id: string, role: 'admin' | 'user'): Promise<AdminReply>
  /** `null` = 回落到默认 / 不限（字段含义见 `AdminUserRow`）。 */
  setUserLimits(id: string, patch: { maxConnectors?: number | null; quotaBytes?: number | null }): Promise<AdminReply>
  /** 发一封测试邮件（验证 SMTP 配置）。 */
  testMail(to: string): Promise<AdminReply>
}

const json = (status: number, body: unknown): AdminReply => ({
  status, contentType: 'application/json', body: JSON.stringify(body),
})
const html = (status: number, body: string): AdminReply => ({
  status, contentType: 'text/html; charset=utf-8', body,
})

const SUBJECT = /^(user:[^\s:]{1,64}|connector:[^\s:]{1,64})$/
const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value)

export function createAdminRoutes(api: AdminApi, page: string): { handle(request: AdminRequest): Promise<AdminReply> } {
  return {
    async handle(request) {
      if (request.method === 'GET') {
        if (request.path === '/admin' || request.path === '/admin/') return html(200, page)
        if (request.path === '/admin/api/state') return json(200, api.state())
        return json(404, { error: 'not-found' })
      }
      if (request.method !== 'POST') return json(405, { error: 'method-not-allowed' })
      const body = isPlainObject(request.body) ? request.body : {}

      if (request.path === '/admin/api/quota') {
        const subject = body['subject']
        const bytes = body['bytes']
        if (typeof subject !== 'string' || !SUBJECT.test(subject)) {
          return json(400, { error: 'subject-invalid' })
        }
        // `bytes: null`（或干脆不带）= 取消上限；数字必须是正整数（0 不是"取消"）。
        if (bytes !== null && bytes !== undefined
          && (typeof bytes !== 'number' || !Number.isInteger(bytes) || bytes <= 0)) {
          return json(400, { error: 'bytes-invalid' })
        }
        return api.setQuota(subject, typeof bytes === 'number' ? bytes : null)
      }

      if (request.path === '/admin/api/quota/reset') {
        const subject = body['subject']
        if (typeof subject !== 'string' || !SUBJECT.test(subject)) {
          return json(400, { error: 'subject-invalid' })
        }
        return api.resetQuota(subject)
      }

      if (request.path === '/admin/api/disconnect') {
        const connectorId = body['connectorId']
        const deviceId = body['deviceId']
        if (typeof connectorId !== 'string' || connectorId === '') {
          return json(400, { error: 'connectorId-invalid' })
        }
        if (deviceId !== undefined && (typeof deviceId !== 'string' || deviceId === '')) {
          return json(400, { error: 'deviceId-invalid' })
        }
        return api.disconnect(connectorId, deviceId)
      }

      if (request.path === '/admin/api/tokens/revoke' || request.path === '/admin/api/tokens/restore') {
        const id = body['id']
        if (typeof id !== 'string' || id === '') return json(400, { error: 'id-invalid' })
        return api.setTokenEnabled(id, request.path.endsWith('/restore'))
      }

      if (request.path === '/admin/api/tokens/remove') {
        const id = body['id']
        if (typeof id !== 'string' || id === '') return json(400, { error: 'id-invalid' })
        return api.removeToken(id)
      }

      // 「连接器是否必须认证」+ 自动签发名额。**`limit: null` = 无上限**（不预设人为限制）。
      if (request.path === '/admin/api/connector-auth') {
        const mode = body['mode']
        if (mode !== 'open' && mode !== 'required') return json(400, { error: 'mode-invalid' })
        const limit = body['limit']
        if (limit !== null && limit !== undefined
          && (typeof limit !== 'number' || !Number.isInteger(limit) || limit < 1)) {
          return json(400, { error: 'limit-invalid' })
        }
        return api.setConnectorAuth(mode, typeof limit === 'number' ? limit : null)
      }

      // ---- 账号 ----
      if (request.path === '/admin/api/users/status') {
        const id = body['id']
        const status = body['status']
        if (typeof id !== 'string' || id === '') return json(400, { error: 'id-invalid' })
        if (status !== 'active' && status !== 'suspended') return json(400, { error: 'status-invalid' })
        return api.setUserStatus(id, status)
      }

      if (request.path === '/admin/api/users/role') {
        const id = body['id']
        const role = body['role']
        if (typeof id !== 'string' || id === '') return json(400, { error: 'id-invalid' })
        if (role !== 'admin' && role !== 'user') return json(400, { error: 'role-invalid' })
        return api.setUserRole(id, role)
      }

      if (request.path === '/admin/api/users/limits') {
        const id = body['id']
        if (typeof id !== 'string' || id === '') return json(400, { error: 'id-invalid' })
        const maxConnectors = body['maxConnectors']
        if (maxConnectors !== undefined && maxConnectors !== null
          && (typeof maxConnectors !== 'number' || !Number.isInteger(maxConnectors)
            || maxConnectors < 1 || maxConnectors > 100)) {
          return json(400, { error: 'max-connectors-invalid' })
        }
        const quotaBytes = body['quotaBytes']
        if (quotaBytes !== undefined && quotaBytes !== null
          && (typeof quotaBytes !== 'number' || !Number.isInteger(quotaBytes) || quotaBytes < 1)) {
          return json(400, { error: 'quota-invalid' })
        }
        if (maxConnectors === undefined && quotaBytes === undefined) {
          return json(400, { error: 'nothing-to-update' })
        }
        return api.setUserLimits(id, {
          ...(maxConnectors === undefined ? {} : { maxConnectors: maxConnectors as number | null }),
          ...(quotaBytes === undefined ? {} : { quotaBytes: quotaBytes as number | null }),
        })
      }

      if (request.path === '/admin/api/mail/test') {
        const to = body['to']
        if (typeof to !== 'string' || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) {
          return json(400, { error: 'email-invalid' })
        }
        return api.testMail(to.trim().toLowerCase())
      }

      return json(404, { error: 'not-found' })
    },
  }
}
