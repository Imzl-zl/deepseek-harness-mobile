/**
 * 技能目录的读取面（`skill.catalog`，契约 §5.7）。
 *
 * ## 它是什么
 *
 * 桌面 `/` 菜单把两类东西拼在一起：**宿主的命令表**（`repo.info.commands`）与
 * **这一会话可见的技能目录**（`ui-skill/src/client/index.ts:171-184` 的
 * `trigger: '/'`、`order: 2`，子会话里不出现）。方法名 `skill.catalog` 只服务后者。
 *
 * ## 宿主那一面
 *
 * `packages/api/session-controller/src/skill-catalog.ts:36` 的 `@Remote`：
 * `sessionSkillCatalog.list({sessionId}, signal)`（namespace `skills`）→
 * `{skills: [{name, path?, description, whenToUse?, modelInvocable}]}`，
 * 已经滤成"用户可调用"（`isUserInvocable`）。它**冷读**：不需要活 agent，
 * 靠 `sessionQuery` 与 `workingDirectory` 还原这一会话的作用域。
 *
 * 所以这个端口只做三件事：别名 → DSH 会话 id、30 s 上限、形状过滤
 * （名字不是字符串的行丢掉 —— 一条坏行不该让整张菜单消失）。
 *
 * 取舍（为什么新开方法而不是塞进 `session.projections`、为什么子会话没有技能段）
 * 见 `.agents/notes/implemented/2026-11-22-command-surface-parity.md` §技能段。
 */
import type { Context } from '@deepseek-ai/cordis'

import { ProtocolError } from '../protocol/errors.js'

/** `sessionSkillCatalog` 的方法面（按形状收窄、不 import DSH 类型）。 */
interface SkillCatalogService {
  list(
    request: { sessionId: string },
    signal: AbortSignal,
  ): Promise<{ skills?: unknown }>
}

/** 过线的技能行：只留手机菜单要的三样（`path` / `whenToUse` 是桌面侧的东西）。 */
export interface SkillRow {
  name: string
  description?: string
  modelInvocable?: boolean
}

export interface SkillCatalogPort {
  /** 一个会话可见的技能目录。别名未知 = 调用方的缺陷（handler 已经查过一次）。 */
  of(sid: string): Promise<{ skills: SkillRow[] }>
}

/**
 * 单次读取的上限。与投影那条同一个量级（`dsh/projections.ts` 的 30 s）：
 * 它是"冷读整个目录"的成本，而不是一次网络往返。
 */
const SKILL_CATALOG_TIMEOUT_MS = 30_000

export function createSkillCatalogPort(
  ctx: Context,
  deps: { sessionOf(sid: string): string | undefined },
): SkillCatalogPort {
  const serviceOf = (): SkillCatalogService | undefined =>
    (ctx.get('sessionSkillCatalog') as SkillCatalogService | undefined) ??
    undefined

  return {
    async of(sid) {
      const service = serviceOf()
      if (service === undefined) {
        // 装配层按"服务在不在"决定挂不挂（`index.ts`），走到这里只可能是装配写错了。
        throw new ProtocolError(
          'internal',
          'sessionSkillCatalog 不在：技能目录的读路径不可用',
        )
      }
      const dshSessionId = deps.sessionOf(sid)
      if (dshSessionId === undefined) {
        throw new ProtocolError('session/not-found', `会话 ${sid} 不在别名表里`)
      }
      const value = await service.list(
        { sessionId: dshSessionId },
        AbortSignal.timeout(SKILL_CATALOG_TIMEOUT_MS),
      )
      const raw = value?.skills
      if (!Array.isArray(raw)) return { skills: [] }
      const skills: SkillRow[] = []
      for (const row of raw) {
        if (typeof row !== 'object' || row === null) continue
        const { name, description, modelInvocable } = row as Record<
          string,
          unknown
        >
        if (typeof name !== 'string' || name === '') continue
        skills.push({
          name,
          // 空说明视同没给（线上就是"这个键不出现"，手机那一列不画）。
          ...(typeof description === 'string' && description !== ''
            ? { description }
            : {}),
          ...(typeof modelInvocable === 'boolean' ? { modelInvocable } : {}),
        })
      }
      return { skills }
    },
  }
}
