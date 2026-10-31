/**
 * 连接器自助兑换（中转 `connectorAuth: "open"` 时的第一步）。
 *
 * ## 它换到的是什么
 *
 * **一张普通连接器令牌** —— 与管理员 `--issue-token` 签发的那张没有区别：进同一张摘要表、
 * 同一个吊销按钮、同一条限流。所以"要不要认证"只由中转的 `connectorAuth` 决定，
 * 连接器这边的认证路径没有第二条。
 *
 * ## 为什么走 HTTP 而不是握手里带
 *
 * 握手/线协议是端到端加密与 transcript 的边界（`protocol/verify-fixtures` 454 项、
 * 向量 49 项都盯着它）；换票只是"拿账号"这一步，用 HTTP 就够，且 `/ws-ticket` 早有先例。
 *
 * ## 三种失败要说清
 *
 * | 响应 | 含义 | 用户下一步 |
 * |---|---|---|
 * | `403 connector-auth-required` | 这台中转只认管理员签发的令牌 | 去要令牌，而不是重试 |
 * | `429 auto-enroll-full` | 名额用满（owner 设了上限） | 找 owner 加名额或手工发令牌 |
 * | 其它 / 网络错 | 地址错、DNS、证书、代理 | 按原文排查 |
 */
export interface EnrollResult {
  /** 明文令牌（只出现这一次，调用方要立刻写进凭据）。 */
  token: string
  /** 中转给的身份 id（`auto-xxxxxxxx`）。 */
  connectorId: string
}

/** 兑换失败：`status` / `code` 保留中转的原文，便于现场判断。 */
export class EnrollError extends Error {
  constructor(
    message: string,
    readonly status?: number,
    readonly code?: string,
  ) {
    super(message)
    this.name = 'EnrollError'
  }
}

/**
 * `wss://host/ws/connector` → `https://host/connector/enroll`。
 *
 * **不丢端口**：自部署常跑在 8787 之外的端口上，而 `Authorization` 那套令牌是
 * 跟着中转走的，把端口抹掉会让"地址明明对"变成"永远拨不通"。
 */
export function enrollUrlOf(relayUrl: string): string {
  const url = new URL(relayUrl)
  if (url.protocol !== 'wss:' && url.protocol !== 'ws:') {
    throw new EnrollError(`中转地址不是 WebSocket 地址（${relayUrl}）`)
  }
  const http = url.protocol === 'wss:' ? 'https:' : 'http:'
  return `${http}//${url.host}/connector/enroll`
}

type FetchLike = (
  input: string,
  init: { method: string; headers: Record<string, string>; body: string },
) => Promise<{ status: number; text: () => Promise<string> }>

export interface EnrollOptions {
  relayUrl: string
  /** 本机稳定 id（进身份，也是中转侧日志里的归属）。 */
  pcId: string
  /** 电脑名（只进日志与配置注释，不参与判定）。 */
  name?: string
  /** 测试注入点。 */
  fetchImpl?: FetchLike
}

export async function enrollConnector(options: EnrollOptions): Promise<EnrollResult> {
  const endpoint = enrollUrlOf(options.relayUrl)
  const doFetch = options.fetchImpl ?? (globalThis.fetch as unknown as FetchLike)
  if (typeof doFetch !== 'function') {
    throw new EnrollError('运行环境没有 fetch：无法向中转兑换令牌')
  }
  const body = JSON.stringify({
    pcId: options.pcId,
    ...(options.name === undefined || options.name === '' ? {} : { name: options.name }),
  })
  let response: { status: number; text: () => Promise<string> }
  try {
    response = await doFetch(endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body,
    })
  } catch (error) {
    throw new EnrollError(
      `兑换请求发不出去（${endpoint}）：${error instanceof Error ? error.message : String(error)}`,
    )
  }

  const text = await response.text().catch(() => '')
  if (response.status === 201) {
    let parsed: unknown
    try { parsed = JSON.parse(text) } catch {
      throw new EnrollError('中转回了 201，但响应不是 JSON', 201)
    }
    const fields = typeof parsed === 'object' && parsed !== null ? parsed as Record<string, unknown> : {}
    const token = fields['token']
    const connectorId = fields['connectorId']
    if (typeof token !== 'string' || token === '' || typeof connectorId !== 'string') {
      throw new EnrollError('中转回了 201，但缺少 token / connectorId', 201)
    }
    return { token, connectorId }
  }

  let code: string | undefined
  try {
    const parsed: unknown = JSON.parse(text)
    code = typeof parsed === 'object' && parsed !== null
      ? (parsed as Record<string, unknown>)['error'] as string | undefined
      : undefined
  } catch {
    code = undefined
  }

  if (response.status === 403) {
    throw new EnrollError(
      '这台中转要求管理员签发令牌（未开放自助兑换）：去要一张，重试没用',
      403, code ?? 'connector-auth-required',
    )
  }
  if (response.status === 429 && code === 'auto-enroll-full') {
    throw new EnrollError(
      '这台中转的自助兑换名额已满：找 owner 提高上限，或直接给一张手工令牌',
      429, code,
    )
  }
  if (response.status === 429) {
    throw new EnrollError('兑换被限流：稍后再试（速率限制按来源地址算）', 429, code)
  }
  throw new EnrollError(
    `兑换失败（HTTP ${response.status}${code === undefined ? '' : `，${code}`}）`,
    response.status, code,
  )
}
