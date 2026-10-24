/**
 * `@` 候选的两个只读面（`refs.files` / `refs.sessions`，契约 §5.7）。
 *
 * ## 只透传，不新增能力
 *
 * `@` 在 DSH 里是**普通文本 token**（`packages/client/ui-conversation/src/client/input/decorations.ts:24-25`
 * 的 `TEXT_REF_RE` / `FOLDER_REF_RE`：触发符必须在**行首或空白之后**，不跨行），
 * 背后两个 Remote 各管一半：
 *
 * - 文件 / 目录：`fileReferences.list(agent, query, signal)` → 候选只有
 *   `{path, kind:'file'|'directory'}`（`packages/api/session-controller/src/file-references.ts:32-39`，
 *   类型 `packages/context/file-reference/src/types.ts:8-18`，**path-only、确定性**）。
 * - 会话：`sessionReferenceResolver` 的 `@Remote('candidates')`
 *   （`packages/context/session-reference/src/index.ts:281-295`）→ 候选里**已经拼好**
 *   `mention` 文本（`@[label](dsh-session:<base64url>)`，`uri.ts:63-66` 的
 *   `formatSessionReferenceMention`）。
 *
 * 这一层**不排序、不截断、不缓存、不预取**：候选上限是宿主的 `candidateLimit`
 * （`index.ts:106` 的 Config，默认值在 `config.ts` 的 `DEFAULT_CANDIDATE_LIMIT`），
 * 我们按宿主给的原样过线。空结果就是空数组（"这里没有匹配"是宿主的答案）。
 *
 * ## 为什么 mention 原样过线
 *
 * 会话候选的 `mention` 里**装着 DSH 会话 id 的 base64url**（`uri.ts:15-19`）——
 * 那是宿主的 URI 格式，不是我们发明的字段。手机只把它当**不透明文本**插进输入框，
 * 发回来时由宿主的 `agent/pre-step` 解析（`session-reference/src/index.ts:143-150`）。
 * 换掉它（比如换成 `sid`）就等于自己造一套宿主认不出的引用语法。
 *
 * ## 行里为什么还带 `sid`
 *
 * 别名是**本通道的概念**（`alias.ts`），手机侧只认 `sid`。候选行给 `sid` 是为了
 * 界面能标识"这一条对应哪个会话"（以及将来点开的需求），与 `subagentCatalog`
 * 的 id 换算法同一条纪律（`handlers.ts` 的 `aliasSubagentCatalog`）。
 * **先查再分配**：`session.list` 已经为可见会话分过别名，所以绝大多数候选命中第一档；
 * 第二档只覆盖"会话刚建、列表还没刷"的窗口。
 *
 * 取舍（为什么不做成 `fileReferences` 那种直接透传的第三个面、为什么不截断）见
 * `.agents/notes/implemented/2026-10-24-file-and-session-mentions.md`。
 */
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'

import { ProtocolError } from '../protocol/errors.js'

/** 宿主的文件候选（`packages/context/file-reference/src/types.ts:8-18`）。 */
export interface FileCandidate {
  path: string
  kind: 'file' | 'directory'
}

/** 宿主的会话候选里我们用到的字段（`session-reference/src/types.ts` 的 `…MentionCandidate`）。 */
interface SessionCandidate {
  sessionId: string
  label?: unknown
  displayTitle?: unknown
  mention?: unknown
}

/** `fileReferences` 服务面（**按形状收窄、不 import DSH 类型**）。 */
interface FileReferenceService {
  list(agent: Agent, query: string, signal: AbortSignal): Promise<readonly FileCandidate[]>
}

/** `sessionReferenceResolver` 服务面（`@Remote('candidates')` 的本地方法名）。 */
interface SessionReferenceService {
  remoteExportCandidates(
    agent: Agent,
    query: string,
    signal: AbortSignal,
  ): Promise<readonly SessionCandidate[]>
}

/** `agents` 注册表（`packages/core/agent/src/index.ts` 的 `get`）。 */
interface AgentsRegistry {
  get(id: Agent['id']): Agent | undefined
}

/** 给手机的一行文件候选。**逐字段构造**，不让宿主将来新增的字段悄悄过线。 */
export interface FileRefRow {
  path: string
  kind: 'file' | 'directory'
}

/** 给手机的一行会话候选。 */
export interface SessionRefRow {
  /** 本通道的会话别名（契约 §5.1）。 */
  sid: string
  /** 标题：宿主的 `displayTitle` 优先、其次 `label`（与 `@Remote('candidates')` 拼 mention 的口径一致）。 */
  title: string
  /** 宿主编好的引用文本，**原样**插进输入框。 */
  mention: string
}

export interface ReferencesDeps {
  /** 通道别名 → DSH 会话 id（契约 §5.1）。不认识的别名返回 `undefined`。 */
  sessionOf(sid: string): string | undefined
  /** DSH 会话 id → 别名（已有就直接给，没有才分配）。 */
  ensureSid(dshSessionId: string): Promise<string>
}

/** `@` 候选的两个面。 */
export interface ReferencesFace {
  files(sid: string, query: string): Promise<readonly FileRefRow[]>
  sessions(sid: string, query: string): Promise<readonly SessionRefRow[]>
}

/**
 * 候选查询的超时。
 *
 * `list` / `candidates` 都要求一个 `AbortSignal`（宿主用它取消枚举目录的读）。
 * 取契约 §10 的请求超时同一个值：手机侧到点就放弃这次请求，电脑侧留着它只是白做功。
 */
const CANDIDATE_TIMEOUT_MS = 60_000

/**
 * 建两个候选面。
 *
 * 三个服务键都走 `ctx.get`，**缺席的判定放在装配层**（`index.ts` 按
 * `referencesAvailable(ctx)` 决定挂不挂方法）；走到这里缺键只可能是装配写错了，
 * 那时如实抛，而不是静默回空数组（空数组会被手机读成"没有匹配"）。
 */
export function createReferencesFace(ctx: Context, deps: ReferencesDeps): ReferencesFace {
  const filesOf = (): FileReferenceService | undefined =>
    (ctx.get('fileReferences') as FileReferenceService | undefined) ?? undefined
  const sessionsOf = (): SessionReferenceService | undefined =>
    (ctx.get('sessionReferenceResolver') as SessionReferenceService | undefined) ?? undefined
  const agentsOf = (): AgentsRegistry | undefined =>
    (ctx.get('agents') as AgentsRegistry | undefined) ?? undefined

  /** 别名 → live root agent。口径与 `dsh/command-line.ts` 的 `agentOf` 一致。 */
  const agentOf = (sid: string): Agent => {
    const dshSessionId = deps.sessionOf(sid)
    if (dshSessionId === undefined) {
      throw new ProtocolError('session/not-found', `未知的会话别名：${sid}`)
    }
    const agent = agentsOf()?.get(dshSessionId as Agent['id'])
    if (agent === undefined) {
      throw new ProtocolError(
        'internal',
        `这个会话在电脑上没有对应的活动 agent（${sid}）：@ 候选要在这个会话自己的工作目录里找`,
      )
    }
    return agent
  }

  return {
    async files(sid, query) {
      const service = filesOf()
      if (service === undefined) {
        throw new ProtocolError('internal', 'fileReferences 服务不在：@ 文件候选不可用')
      }
      const candidates = await service.list(
        agentOf(sid),
        query,
        AbortSignal.timeout(CANDIDATE_TIMEOUT_MS),
      )
      // 宿主给的就是路径与种类；**不猜第三种 kind**，认不出的项整个丢掉
      // （摆一行点不动的候选，比少一行更坏）。
      return candidates.flatMap((candidate) =>
        (candidate.kind === 'file' || candidate.kind === 'directory') &&
        typeof candidate.path === 'string' &&
        candidate.path !== ''
          ? [{ path: candidate.path, kind: candidate.kind }]
          : [],
      )
    },

    async sessions(sid, query) {
      const service = sessionsOf()
      if (service === undefined) {
        throw new ProtocolError('internal', 'sessionReferenceResolver 服务不在：@ 会话候选不可用')
      }
      const candidates = await service.remoteExportCandidates(
        agentOf(sid),
        query,
        AbortSignal.timeout(CANDIDATE_TIMEOUT_MS),
      )
      return Promise.all(
        candidates.flatMap((candidate) => {
          const sessionId = candidate.sessionId
          const mention = candidate.mention
          if (typeof sessionId !== 'string' || sessionId === '') return []
          if (typeof mention !== 'string' || mention === '') return []
          // 标题口径与宿主拼 mention 时用的同一个（`:290-293`：
          // `label: candidate.displayTitle ?? candidate.label`）。
          const title =
            typeof candidate.displayTitle === 'string' && candidate.displayTitle !== ''
              ? candidate.displayTitle
              : typeof candidate.label === 'string'
              ? candidate.label
              : ''
          return [{ sessionId, title, mention }]
        }).map(async (row) => ({
          sid: await deps.ensureSid(row.sessionId),
          title: row.title,
          mention: row.mention,
        })),
      )
    },
  }
}
