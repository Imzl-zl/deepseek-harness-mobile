/**
 * 子代理适配（契约 §7）。
 *
 * 服务：`ctx.subagents`（`packages/subagent/subagent/src/index.ts:137-140` 声明、`:215` 注册）。
 *
 * 本文件做两件映射，都是有意的收窄：
 *
 * 1. **把 `listDescendants` 的可辨识联合拍平**：原始行要么是 `kind:'child'`
 *    （带 `activity` / `mode` / `label` / `hasChildren`），要么是 `kind:'diagnostic'`
 *    （**只有** `reason`，没有 `activity`/`mode`/`label`）
 *    （`packages/subagent/subagent/src/control-types.ts:53-70`）。
 *    不拍平的话手机侧会按 child 渲染诊断行、拿到一屏 `undefined`。
 * 2. **只用 `listDescendants` 提供活动态**：`listChildren` 的返回里**根本没有** `activity`
 *    字段（`subagent/src/projection-types.ts:10-19` 只有 `{id, createdAt, mode, label?}`），
 *    只有 `listDescendants` 的行才有（`subagent/src/list-children.ts:16-21`）。
 *
 * `activity` 的语义必须如实传达：取值是 `'running' | 'inactive'`，**只表达会话当前是否驻留**，
 * 源码注释原文 "This does not encode a durable outcome or guarantee continuation delivery"
 * （`subagent/src/control-types.ts:26-33`）。**已正常收工的子代理同样是 `inactive`**，
 * 与「从未成功」「崩溃」不可区分；要区分必须叠加 `subagentTiming.lastTurnCompleted`
 * （`projection-types.ts:22-37`）——DSH 自己的 GUI 就是这么补出三态的
 * （`packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:243-249`）。
 * 所以本文件**不**把 `inactive` 翻译成任何像「已结束」的措辞。
 *
 * 依赖较重且失败策略不对称：`listChildren` 需要 `sessionQuery` 与 `subagentCatalog` 投影
 * （`list-children.ts:36-52`），`listDescendants` 还要 `sessions`（`:69-75`）；
 * **root 读失败整体 reject，子分支不可读只让那一行降级成诊断**（`:100-109`）。
 */
import type { SubagentRuntime } from '@deepseek-ai/dsh-subagent'

/** `listChildren` 的行。**没有活动态** —— 原始类型里就没有。 */
export interface SubagentEntry {
  id: string
  createdAt: number
  mode: 'one-shot' | 'continuable' | 'unknown'
  label?: string
}

/** 拍平后的子代理行。`diagnostic` 不是「一个子代理」，是一条读不出来的分支。 */
export type SubagentRow =
  | {
      kind: 'child'
      id: string
      parentId: string
      /** 距 root 的边数；直接子 = 1。 */
      depth: number
      mode: 'one-shot' | 'continuable' | 'unknown'
      label?: string
      /** **只表示驻留**，不表示结局。 */
      activity: 'running' | 'inactive'
      hasChildren: boolean
    }
  | {
      kind: 'diagnostic'
      id: string
      parentId: string
      depth: number
      reason: 'corrupt' | 'unsupported' | 'unavailable'
    }

export interface SubagentsPort {
  /** 直接子代；无活动态。 */
  children(dshSessionId: string, signal?: AbortSignal): Promise<readonly SubagentEntry[]>
  /** 递归子代，带活动态与深度。 */
  descendants(dshSessionId: string, signal?: AbortSignal): Promise<readonly SubagentRow[]>
}

export function createSubagentsPort(subagents: SubagentRuntime): SubagentsPort {
  return {
    async children(dshSessionId, signal) {
      // `listChildren(parentSessionId, signal?): Promise<SubagentCatalogEntry[]>`
      // （`packages/subagent/subagent/src/index.ts:374`）。
      const entries = await subagents.listChildren(dshSessionId as never, signal)
      return entries.map((entry) => ({
        id: entry.id,
        createdAt: entry.createdAt,
        mode: entry.mode,
        ...(entry.label === undefined ? {} : { label: entry.label }),
      }))
    },

    async descendants(dshSessionId, signal) {
      // `listDescendants(rootSessionId, signal?): Promise<SubagentDescendantListEntry[]>`
      // （`packages/subagent/subagent/src/index.ts:393`）。
      const entries = await subagents.listDescendants(dshSessionId as never, signal)
      return entries.map((entry): SubagentRow => {
        const base = { id: entry.id, parentId: entry.parentId, depth: entry.depth }
        if (entry.kind === 'diagnostic') {
          return { kind: 'diagnostic', ...base, reason: entry.reason }
        }
        return {
          kind: 'child',
          ...base,
          mode: entry.mode,
          activity: entry.activity,
          hasChildren: entry.hasChildren,
          ...(entry.label === undefined ? {} : { label: entry.label }),
        }
      })
    },
  }
}
