/**
 * 面板「连接」卡的逻辑：读真值、校验、一次写入、错误归一。
 *
 * ## 为什么单开一层（而不是全塞进 `routes.ts`）
 *
 * 与 `admin/device-admin.ts` 同一个理由：这里有三条**必须逐条钉住**的判据，
 * 而它们都只能靠单测证明，不能靠在浏览器里点一下：
 *
 * 1. **白名单**：卡片只碰 `relayUrl` / `allowInsecurePublic` / `listenPort`
 *    三个字段。`describe()` 会把该条目全部 12 个 volatile 字段摆出来
 *    （实测），把 `windowFrames`、`frameLimitBytes` 之类顺手写回界面没有任何一行会用到，
 *    却让"改配置"这件事的爆炸半径变大。
 * 2. **地址校验在写入之前**：schema 不管这件事 —— 实测
 *    `relayUrl: "http://example.com/not-a-relay"` 能被 `settings.update` 成功写进
 *    patch。校验必须复用 `relayUrlOf`（与 `validate-config` 同一处判据，
 *    `transport/relay-url.ts:114`），并且校验的是**这次保存之后的完整状态**
 *    （勾选与地址一次提交时，不能按字段出现顺序判）。
 * 3. **一次写入**：三个字段一次 `settings.update`，不是三次 `mutate`
 *    （每次写 revision 都 +1，第二次拿旧 revision 必冲突）。
 *
 * ## 令牌为什么排在配置之后
 *
 * 两件事没有跨存储的原子性。先写配置：失败（校验/冲突）时令牌还没动；再写令牌：
 * 失败时如实报"配置已生效 + 令牌没写"。反过来则会出现"令牌已经换掉、配置却没落盘"，
 * 而换掉的令牌会让下一次拨号 401 —— 症状比第一种难查得多。
 *
 * 取舍见 `.agents/notes/implemented/2026-10-29-panel-connection-card.md`。
 */
import { RelayTokenError } from '../dsh/relay-token.js'
import { isNonPublicHost, relayUrlOf } from '../transport/relay-url.js'

/** 卡片可写字段（**白名单**，顺序即界面顺序）。 */
export const CONNECTION_FIELDS = ['relayUrl', 'allowInsecurePublic', 'listenPort'] as const
export type ConnectionField = (typeof CONNECTION_FIELDS)[number]

/** 端口范围与 schema 同一条（`config.ts:71-78` 的 `.min(0).max(65535)`）。 */
const PORT_RANGE = { min: 0, max: 65_535 } as const

/** 端口面读到的真值（`index.ts` 的通道注册表 + settings + 凭据）。 */
export interface ConnectionState {
  /** 拿不到 settings 服务时为 `undefined`（卡片据此显示"此部署没有设置服务"）。 */
  revision: number | undefined
  relayUrl: string | undefined
  allowInsecurePublic: boolean
  /** 只服务地址校验（`relayUrlOf` 的第一档），**不上卡**。 */
  allowInsecureLocal: boolean
  listenPort: number
  relayTokenRef: string | undefined
  token: { configured: boolean; writable: boolean }
  relay: { running: boolean; connected: boolean }
  direct: { running: boolean }
}

/** 过线的形状（`GET` 与保存回执共用）。**只有白名单字段**。 */
export interface ConnectionView {
  capable: boolean
  revision: number | undefined
  value: {
    relayUrl: string | undefined
    allowInsecurePublic: boolean
    listenPort: number
    relayTokenRef: string | undefined
  }
  token: { configured: boolean; writable: boolean }
  /** `public` = 中转主机是公网（判据同 `relayUrlOf`：域名一律算公网）。 */
  relay: { running: boolean; connected: boolean; public: boolean }
  direct: { running: boolean }
}

/** 装配层给的能力（每一格都是**用时取值**，不是挂载时快照）。 */
export interface ConnectionPorts {
  read(): Promise<ConnectionState>
  /** 一次写多个字段；`expectedRevision` 缺省 = 不校验。 */
  writeFields(patch: Readonly<Record<string, unknown>>, expectedRevision?: number): Promise<void>
  writeToken(ref: string, token: string): Promise<void>
  clearToken(ref: string): Promise<void>
  /**
   * 等"配置写入触发的那次通道重建"落地，返回它的失败原因。
   *
   * 配置改动会经 `loader/volatile-update` 派发重建（异步），而保存的 HTTP 回执里
   * 要带**重建之后**的真值 —— 否则面板刚存完就显示上一秒的状态。
   */
  settle(): Promise<string | undefined>
}

export type ConnectionSaveResult =
  | {
      status: 200
      body: {
        ok: true
        applied: readonly ConnectionField[]
        tokenApplied: 'none' | 'set' | 'clear'
        relayError?: string
        view: ConnectionView
      }
    }
  | {
      status: 400
      body: {
        ok: false
        field: ConnectionField | 'token' | 'revision' | 'body'
        error: string
        /** 令牌写失败但配置已落盘时为 true —— 两件事分开报，不合并成"保存失败"。 */
        configApplied: boolean
        view: ConnectionView
      }
    }
  | {
      status: 409
      body: { ok: false; conflict: true; error: string; view: ConnectionView }
    }

/** 令牌操作三态：留空 = 不改、填写 = 写入、显式删除 = 抹掉。 */
type TokenOp = { op: 'keep' } | { op: 'set'; value: string } | { op: 'clear' }

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function hostOf(url: string): string {
  try {
    const parsed = new URL(url)
    return parsed.hostname.startsWith('[') && parsed.hostname.endsWith(']')
      ? parsed.hostname.slice(1, -1)
      : parsed.hostname
  } catch {
    // 解析不了就被 `relayUrlOf` 拦住了；这里只是给"公网/内网"一个保守答案。
    return ''
  }
}

function toView(state: ConnectionState): ConnectionView {
  const host = state.relayUrl === undefined ? '' : hostOf(state.relayUrl)
  return {
    capable: state.revision !== undefined,
    revision: state.revision,
    value: {
      relayUrl: state.relayUrl,
      allowInsecurePublic: state.allowInsecurePublic,
      listenPort: state.listenPort,
      relayTokenRef: state.relayTokenRef,
    },
    token: state.token,
    relay: {
      ...state.relay,
      // 空主机不给"内网"这个假答案：没配中转就是没配。
      public: host !== '' && !isNonPublicHost(host),
    },
    direct: state.direct,
  }
}

function asInt(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isInteger(value) ? value : undefined
}

/** 卡片本体。路由层只调这两个方法。 */
export function createConnectionCard(ports: ConnectionPorts): {
  read(): Promise<ConnectionView>
  save(body: unknown): Promise<ConnectionSaveResult>
} {
  const failure = async (
    field: ConnectionField | 'token' | 'revision' | 'body',
    error: unknown,
    configApplied = false,
  ): Promise<ConnectionSaveResult> => ({
    status: 400,
    body: {
      ok: false,
      field,
      error: error instanceof Error ? error.message : String(error),
      configApplied,
      view: toView(await ports.read()),
    },
  })

  return {
    async read() {
      return toView(await ports.read())
    },

    async save(body) {
      if (!isRecord(body)) return failure('body', new Error('请求体必须是 JSON 对象'))
      const before = await ports.read()
      if (before.revision === undefined) {
        return failure('body', new Error('这个部署没有设置服务（settings），无法在这里改配置'))
      }

      // ---- 1) 解析 + 算出"这次保存之后的完整状态"，再校验这个状态 ----
      const next: Record<ConnectionField, unknown> = {
        relayUrl: before.relayUrl,
        allowInsecurePublic: before.allowInsecurePublic,
        listenPort: before.listenPort,
      }
      if ('relayUrl' in body) {
        const raw = body['relayUrl']
        if (typeof raw !== 'string') return failure('relayUrl', new Error('地址必须是字符串'))
        next.relayUrl = raw.trim()
      }
      if ('allowInsecurePublic' in body) {
        const raw = body['allowInsecurePublic']
        if (typeof raw !== 'boolean') return failure('allowInsecurePublic', new Error('这一项必须是布尔值'))
        next.allowInsecurePublic = raw
      }
      if ('listenPort' in body) {
        const raw = body['listenPort']
        if (asInt(raw) === undefined) return failure('listenPort', new Error('端口必须是整数'))
        const port = raw as number
        if (port < PORT_RANGE.min || port > PORT_RANGE.max) {
          return failure('listenPort', new Error(`端口必须在 ${PORT_RANGE.min}–${PORT_RANGE.max} 之间`))
        }
        next.listenPort = port
      }

      const relayUrl = next.relayUrl
      if (typeof relayUrl !== 'string' || relayUrl === '') {
        return failure(
          'relayUrl',
          new Error('地址必填：清空它这台电脑就连不上中转（要停中转请用「传输方式」里的开关）'),
        )
      }
      try {
        // 校验**结果状态**：勾选与地址同一次提交时，不按字段出现顺序判。
        relayUrlOf(relayUrl, before.allowInsecureLocal, next.allowInsecurePublic === true)
      } catch (error) {
        return failure('relayUrl', error)
      }

      // ---- 2) 只发真的变了的键（不把默认值钉进 patch） ----
      const patch: Partial<Record<ConnectionField, unknown>> = {}
      const applied: ConnectionField[] = []
      for (const field of CONNECTION_FIELDS) {
        if (next[field] !== before[field]) {
          patch[field] = next[field]
          applied.push(field)
        }
      }

      // ---- 3) 令牌三态（解析在写配置之前，坏输入不该先落盘配置） ----
      let tokenOp: TokenOp = { op: 'keep' }
      const tokenRaw = body['token']
      if (tokenRaw !== undefined) {
        if (!isRecord(tokenRaw)) return failure('token', new Error('token 必须是对象'))
        const op = tokenRaw['op']
        if (op === 'keep') tokenOp = { op: 'keep' }
        else if (op === 'clear') tokenOp = { op: 'clear' }
        else if (op === 'set') {
          const value = tokenRaw['value']
          if (typeof value !== 'string') return failure('token', new Error('令牌必须是字符串'))
          if (value.trim() === '') return failure('token', new RelayTokenError('令牌不能为空：要撤掉请用删除'))
          tokenOp = { op: 'set', value }
        } else {
          return failure('token', new Error('token.op 必须是 keep / set / clear'))
        }
      }
      if (before.relayTokenRef === undefined || before.relayTokenRef === '') {
        return failure('body', new Error('relayTokenRef 未配置：不知道令牌该写进哪条记录'))
      }

      // 什么都没改：不写、不动 revision，回当前真值。
      if (applied.length === 0 && tokenOp.op === 'keep') {
        const relayError = await ports.settle()
        return {
          status: 200,
          body: {
            ok: true,
            applied: [],
            tokenApplied: 'none',
            ...(relayError === undefined ? {} : { relayError }),
            view: toView(await ports.read()),
          },
        }
      }

      // ---- 4) 配置优先：一次写入，冲突单独归一 ----
      if (applied.length > 0) {
        const expected = body['revision'] === undefined ? before.revision : asInt(body['revision'])
        if (expected === undefined) return failure('revision', new Error('revision 必须是整数'))
        try {
          await ports.writeFields(patch, expected)
        } catch (error) {
          const code = (error as { code?: unknown } | null)?.code
          if (code === 'SETTINGS_CONFLICT') {
            return {
              status: 409,
              body: {
                ok: false,
                conflict: true,
                error: '配置在别处被改过（另开的页面，或直接改了 cordis.patch.yml）',
                view: toView(await ports.read()),
              },
            }
          }
          return failure('body', error)
        }
      }

      // ---- 5) 令牌：失败只报这一项，明说配置已经生效 ----
      let tokenApplied: 'none' | 'set' | 'clear' = 'none'
      if (tokenOp.op !== 'keep') {
        try {
          if (tokenOp.op === 'set') await ports.writeToken(before.relayTokenRef, tokenOp.value)
          else await ports.clearToken(before.relayTokenRef)
          tokenApplied = tokenOp.op
        } catch (error) {
          return failure('token', error, applied.length > 0)
        }
      }

      // ---- 6) 等重建落地，回重建之后的真值 ----
      const relayError = await ports.settle()
      return {
        status: 200,
        body: {
          ok: true,
          applied,
          tokenApplied,
          ...(relayError === undefined ? {} : { relayError }),
          view: toView(await ports.read()),
        },
      }
    },
  }
}
