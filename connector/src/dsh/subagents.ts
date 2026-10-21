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

import type { PromptPart } from './sessions.js'

/**
 * 子代理的执行形态。
 *
 * `external` 是 DSH **0.2.1 新增**的取值（`subagent` 包的 catalog v2：
 * "v2 records external executions"，`catalog.d.ts` 的 `SubagentCatalogEvent` 注释）。
 * **原样过线，不折叠成 `unknown`**：它是"这个子代理不在本机执行"这一事实，
 * 折叠掉手机就只能说"不明"，而用户看不出"它其实是外部后端在跑"。
 * 手机侧 `model/subagent.dart` 的枚举与 `endpointKindLabel` 同一条纪律 ——
 * 未知取值不静默当默认值。
 */
export type SubagentMode = 'one-shot' | 'continuable' | 'unknown' | 'external'

/** `listChildren` 的行。**没有活动态** —— 原始类型里就没有。 */
export interface SubagentEntry {
  id: string
  createdAt: number
  mode: SubagentMode
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
      mode: SubagentMode
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

/** 给可继续子会话投递一条人写的消息（`subagent.prompt` 的落点）。 */
export interface SubagentDelivery {
  /** 父会话的 DSH id（宿主要按它找"活着的直接父级"）。 */
  parentSessionId: string
  /** 子会话的 DSH id。 */
  childSessionId: string
  /** **人铸的幂等键**：宿主把它持久在被接受的那条消息上。 */
  requestId: string
  content: readonly PromptPart[]
  /** `queue` = 排到下一轮；`steer` = 塞进最近一步。 */
  delivery: 'queue' | 'steer'
}

export interface SubagentsPort {
  /** 直接子代；无活动态。 */
  children(dshSessionId: string, signal?: AbortSignal): Promise<readonly SubagentEntry[]>
  /** 递归子代，带活动态与深度。 */
  descendants(dshSessionId: string, signal?: AbortSignal): Promise<readonly SubagentRow[]>
  /**
   * 给**可继续**子会话投递一条消息。
   *
   * **这是子会话唯一的写入口**：对子会话直接调 `sessionController.prompt` 会被
   * 宿主拒成 `internal: session "…" is owned by subagent routing`
   * （2026-10-21 真机实测：手机上表现成「发送失败」）。DSH 的入口是
   * `SubagentRuntime.prompt`（`packages/subagent/subagent/src/index.ts:447` 的
   * `@Remote('prompt')`，服务键 `subagents`，请求形状 `control-types.ts:94-112`）。
   */
  deliver(request: SubagentDelivery, signal?: AbortSignal): Promise<{ messageId: string }>
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

    async deliver(request, signal) {
      // `prompt(request: SubagentPromptRequest, signal): Promise<SubagentPromptReceipt>`
      // （`packages/subagent/subagent/src/index.ts:447-448`）。
      // `mode` 是**必填判别式**（`control-types.ts:97`）：只有可继续子会话能收人写的消息，
      // 一次性 / 外部任务的子会话在手机上本来就是只读框（`docs/subsystems/subagent-page.md` §5）。
      const receipt = await subagents.prompt(
        {
          requestId: request.requestId as never,
          parentSessionId: request.parentSessionId as never,
          childSessionId: request.childSessionId as never,
          mode: 'continuable',
          delivery: request.delivery,
          content: request.content as never,
        },
        signal ?? new AbortController().signal,
      )
      return { messageId: receipt.messageId }
    },
  }
}
