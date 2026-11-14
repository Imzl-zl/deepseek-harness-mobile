/**
 * Agent Teams 的**写面**（这一轮只有开关：`team.setEnabled`）。
 *
 * ## 为什么走 gateway remote，而不是进程内直接调服务
 *
 * 宿主的 `TeamService.setEnabled` 要一个 **live `Agent`** 句柄
 * （`packages/team/agent-team/src/index.ts:111-114`：先 `rootOf(agent)`，不是根就抛
 * `TEAM_LEAD_REQUIRED`）。手机上只有 `sid`，而"要不要为一个开关把不在内存里的会话拉起来"
 * 是**宿主的决定**：
 *
 * - 走进程内 `agents.get()`（本仓别处那个写法）：拿不到就完了，用户点开关毫无反应；
 * - 走进程内 `sessionController.resolveAgent()`：等于我们替宿主决定"把整个 agent 拉起来"；
 * - 走 gateway：`agent` 参数的解析由宿主自己配的 lookup 完成
 *   （`packages/api/session-controller/src/agent.ts:128-132` 的
 *   `ctx.typert.lookups.configure('agent', …)` → `resolveAgent`），**行为与 Web 完全一致**。
 *
 * 宿主自己的客户端走的就是这条：`packages/client/ui-agent-team/src/client/mount.ts:43`
 * 的 `scope.remote.agentTeams.setEnabled(sessionId, enabled)`。
 *
 * ## 线上形状（不是猜的）
 *
 * 方法名与参数由 DSH 自己的 e2e 钉着：端点 `agentTeams/setEnabled`，
 * args 是 `{agentId, enabled}`（`packages/team/agent-team/tests/built-lib.e2e.ts:37-41`：
 * `input.safeParse({ agentId: 'root', enabled })` 通过、缺 `agentId` 被拒）。
 * `agentId` 是 `Agent` 这个 lookup 参数的**线上名**，传的是 DSH 会话 id。
 *
 * ## 与 `dsh/interaction-client.ts` 的关系
 *
 * 两者都用 `connection.createPeer` + `createSharedFetchHandler('/api')` 向 gateway 发一个
 * `{type:'client-request', …}`。**没有合并**：interaction-client 那侧还要读 `$events`
 * 流、维护投递与换代，把它拆出通用层会动一条有 29 项装配回归网盯着的主链；
 * 这里只需要"发一次请求拿结果"，六行。哪天需要第三种调用者再抽。
 *
 * 取舍见 `.agents/notes/implemented/2026-11-14-agent-team-integration.md`。
 *
 * @module dsh-mobile-connector/dsh/team
 */
import type { Context } from '@deepseek-ai/cordis'

import { ProtocolError } from '../protocol/errors.js'
import type { Aliases } from '../alias.js'

/** gateway 的 in-process 通道（只用到这两样，形状照 `dsh/interaction-client.ts`）。 */
interface ConnectionService {
  createPeer(options: { readonly principal: { readonly kind: 'owner' } }): unknown
  createSharedFetchHandler(channel: '/api'): SharedFetchHandler
}

interface SharedFetchHandler {
  fetch(request: Request, peer?: unknown): Promise<Response>
}

/** Agent Teams 的写面。 */
export interface TeamFace {
  /**
   * 保存一个**根会话**的 Team 选择。
   *
   * @param sid - 手机的会话别名
   * @param enabled - 目标档位
   * @throws ProtocolError 形状／别名不认（`session/not-found`）或宿主拒绝
   *   （`TEAM_LEAD_REQUIRED` 等原样带码）
   */
  setEnabled(sid: string, enabled: boolean): Promise<void>
}

/** `team.setEnabled` 的 DSH 端点（`@Remote` 方法名与参数见文件头）。 */
const SET_ENABLED_ENDPOINT = 'agentTeams/setEnabled'

/**
 * 建 Team 写面。
 *
 * @returns `null` = 宿主缺 `connection`（没有 in-process 通道）——
 *   那时装配层不挂这个方法，`caps.team` 也照旧为 true（它说的是"服务在不在"）。
 *   两件事分开：能力位看 `agentTeams`，这个方法看"我们能不能把话带到宿主"。
 */
export function createTeamFace(
  ctx: Context,
  deps: { readonly aliases: Aliases },
): TeamFace | null {
  const connection = ctx.get('connection') as ConnectionService | undefined
  if (connection === undefined) return null
  const peer = connection.createPeer({ principal: { kind: 'owner' } })
  const fetchHandler = connection.createSharedFetchHandler('/api')
  let sequence = 0

  return {
    async setEnabled(sid, enabled) {
      const dshSessionId = deps.aliases.sessionOf(sid)
      if (dshSessionId === undefined) {
        throw new ProtocolError('session/not-found', `会话 ${sid} 不认识（别名表里没有）`)
      }
      sequence += 1
      const rpcId = `team-${String(sequence)}`
      const response = await fetchHandler.fetch(
        new Request(`http://host/api/${SET_ENABLED_ENDPOINT}`, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            type: 'client-request',
            rpcId,
            method: SET_ENABLED_ENDPOINT,
            payload: { args: { agentId: dshSessionId, enabled } },
          }),
        }),
        peer,
      )
      const body = (await response.json()) as {
        result?: { ok?: boolean; error?: { code?: string; message?: string } }
      }
      if (body.result?.ok === true) return
      // 失败一律归 `internal`（错误码表是**封闭**的，`protocol/errors.ts` 的文件头）。
      // 宿主的码**写进消息**而不是自造一个码：表外码加进来要同时动契约 §3.1、
      // 两侧的码表与 `assert.equal(ERROR_CODES.length, …)`，而这条失败在手机上是不可达的 ——
      // 子会话根本不显示这个开关（`ui/side_panel_visibility.dart`），
      // 所以 `TEAM_LEAD_REQUIRED` 只会发生在"宿主自己那一侧已经变了"的时候，
      // 那时人要看的是原始码，不是一句翻译。
      const error = body.result?.error
      const code = error?.code === undefined ? '' : ` [${error.code}]`
      throw new ProtocolError(
        'internal',
        `${error?.message ?? 'agentTeams/setEnabled 没有回接纳'}${code}`,
      )
    },
  }
}
