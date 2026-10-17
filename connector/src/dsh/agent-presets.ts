/**
 * Agent 预设（就是 DSH 界面上的「标准模式 / PTC 模式 / 极简模式 / 创造模式」）：
 * 只读目录。
 *
 * ## 为什么手机要它
 *
 * DSH 的**新会话页**在输入框上面摆两枚 chip：工作区 + Agent 预设
 * （`ui-conversation/src/client/skeleton/ConversationContent.tsx:110-134` 的
 * `heroWorkspaceRow`，预设那枚由 `conversation.hero.agentPreset` 槽占位）。
 * 手机连上电脑后落到的第一屏就是那个 blank 会话页，所以这两枚 chip 也是手机要有的东西
 * —— 而预设名单**只能从电脑侧取**：内置四个的 id 在代码里（`display.ts:41-44`），
 * 但部署可以再声明自己的预设，手抄一份就是第二份真值。
 *
 * ## 只加"读"，不加"写"（方法面 +1 而不是 +2）
 *
 * 写路径 DSH 有两条，**都不需要新方法**：
 *
 * 1. `agentPresets.select(sessionId, id)`（`@Remote('select')`，
 *    `packages/preset/agent-preset-registry/src/index.ts:346-347`，Web 侧调用点在
 *    `ui-agent-preset/src/client/seat-store.ts:230`）。它对**跑过一轮**的会话会拒
 *    （`:351` 抛 `agent-preset/locked`，原注释 "a session's composition is fixed
 *    once its conversation starts"）。
 * 2. `session.create({agentPreset})` —— 建会话时就带上。
 *
 * 手机侧走第 2 条更干净：hero 上选预设的那一刻本来就是"**要开一个新任务**"，
 * 而 `session.create` **已经收 `agentPreset`**（`connector/src/handlers.ts` 的
 * `session.create`；DSH 侧形状 `SessionCreateRequest`
 * `packages/api/session-controller/src/types.ts:288-293`）——
 * 于是"跑过就锁"这条限制根本不会碰到，也不用把 `select` 那套
 * staged/refusal/locked 的客户端状态机搬到手机上。取舍见
 * `.agents/notes/implemented/2026-10-17-blank-session-hero.md`。
 *
 * ## 当前会话跑的是哪个预设：不走这个方法
 *
 * 它是 `agentPreset` **投影**（`stateSchema = string | null`，
 * `agent-preset-registry/src/session.ts:35-44`；Web 读法见
 * `ui-agent-preset/src/client/AgentPresetLabel.tsx:46-49`），随已有的
 * `session.projections` 到手机 —— 所以本文件**不碰**它，同一个状态不会有第二个来源
 * （与权限档"清单走方法、当前值走投影"同一条纪律，见 `dsh/permissions.ts` 的文件头）。
 *
 * ## 名单原样过线（不在这里过滤）
 *
 * DSH 的 roster 行是 `{id, name?, description?, isDefault, broken?}`
 * （`types.ts:8-19`，`remoteExportList` 在 `index.ts:194-198`），
 * 而"哪些能选"是**客户端**规则：Web 的 `presetOptions` 只留
 * `broken === undefined` 的项（`ui-agent-preset/src/client/settings-store.ts:119-127`），
 * 管理页却要把 broken 的也列出来（同文件 `:109-110` 的注释）。
 * 也就是说"过滤"与"展示"是两件事 —— 连接器挑一次字段就等于替手机决定了其中一件。
 * 所以这里**整包透传**，过滤留给手机（它才知道这一屏是选择器还是清单）。
 */
import type { Context } from '@deepseek-ai/cordis'

/** `agentPresets` 服务面（`super(ctx, 'agentPresets')`，`agent-preset-registry/src/index.ts:65`）。 */
interface AgentPresetsService {
  /** `@Remote('list')` 的实现体（`:194-198`）。 */
  remoteExportList(): Promise<unknown>
}

export interface AgentPresetsFace {
  /**
   * 当前部署声明的全部预设（原样）。
   *
   * 拿不到返回 `undefined`（调用方据此回 `{available:false}`）——
   * 与 `permission.catalog` / `session.modelCatalog` 同一条纪律：
   * 空数组会被手机读成"这个部署没有预设"，而真实原因可能是服务没起来。
   */
  roster(): Promise<unknown | undefined>
}

/**
 * 建 Agent 预设面的 DSH 半边。
 *
 * 只依赖一个服务键（`agentPresets`），拿不到就是能力位为 false ——
 * 裸读在服务缺失时抛异常，所以走 `ctx.get`（理由见 `dsh/caps.ts` 的文件头）。
 */
export function createAgentPresetsFace(ctx: Context): AgentPresetsFace {
  const serviceOf = (): AgentPresetsService | undefined =>
    (ctx.get('agentPresets') as AgentPresetsService | undefined) ?? undefined

  return {
    async roster() {
      const service = serviceOf()
      if (service === undefined) return undefined
      try {
        return await service.remoteExportList()
      } catch {
        // 目录是**展示用**的：读不到就让调用方回 `{available:false}`，
        // 手机说"拿不到预设目录"，而不是摆一个空列表（那会被读成"一个预设都没有"）。
        return undefined
      }
    },
  }
}
