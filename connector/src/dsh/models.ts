/**
 * 模型状态的原生读取面（`session/modelCatalog` + `modelSelection` 投影）。
 *
 * ## 为什么是这两条，而不是自己拼
 *
 * 手机上的"当前模型 / 可切模型"曾经是**写死的占位**（`chat_page.dart` 里
 * `modelName: 'claude-opus'` 加一份手抄的四个模型列表）—— 于是手机上显示的模型
 * 与电脑侧真实状态毫无关系。DSH 原生就提供了两样东西，接它们比维护第二份真值可靠：
 *
 * 1. **`session/modelCatalog`**（`packages/api/session-controller/src/index.ts` 的
 *    `@Remote('modelCatalog')`，实现在 `catalog.ts` 的 `buildModelCatalog`）：
 *    按 provider 分组的模型、每档 reasoning effort、以及部署默认值。
 *    它是**给浏览器生成选择器**用的，形状就是选择器要的形状。
 * 2. **`modelSelection` 投影**（`session-controller/src/model-selection-projection.ts`）：
 *    每个会话**持久**的 `{lastUsed, next}`。`next` 是"下一次请求将用哪个"，
 *    `lastUsed` 是"上一次请求实际用了哪个"—— 两者都在会话事件流里
 *    （`model/selection` 写入、`request/header` 消费），所以对"只存在于落盘里的会话"
 *    也读得到。
 *
 * 两处都**不复制字段**：投影的线格式（`view: state => ({lastUsed, next})`）与目录的
 * 分组形状原样过线，手机侧按同一份投影渲染。抄一遍就多一处会漂移的地方。
 *
 * Note: 切模型的**写**路径不在这里 —— 它在 `dsh/sessions.ts` 的 `selectModel`
 * （`session/select-model`，与 Web 同一个 DSH 方法）。本文件只负责"读"。
 * 曾经这里写着"`selectModel` 会把选择写回全局默认，所以本期只读不写"——
 * **那个结论是错的，已翻案**：写回的是"以后新建的 agent 默认跟随"，
 * 而那是 Web 一直有的行为（`agent-default-model/src/index.ts:82-94` + README），
 * 不是副作用。错在把一条**测试纪律**（测试 profile 与日常 profile 共用 `~/.dsh/`）
 * 错升成了**产品约束**。完整翻案见 `memory.md` 的"模型切换翻案"。
 */
import type { Context } from '@deepseek-ai/cordis'

/** 一次模型选择：provider 路由 + 该路由下的模型 id（effort 可选）。 */
export interface ModelRef {
  readonly provider: string
  readonly model: string
  readonly reasoningEffort?: string
}

/** `modelCatalog` 过线的原样形状（DSH 的 `ModelCatalog`，本插件不改一个字段）。 */
export type ModelCatalogView = unknown

/** `modelSelection` 投影的线格式（`model-selection-projection.ts` 的 `wire.view`）。 */
interface ModelSelectionProjectionView {
  readonly lastUsed?: ModelRef | null
  readonly next?: ModelRef | null
}

/** `sessionProjections` 的读取面（服务键不在本插件的依赖里，所以按形状收窄）。 */
interface SessionProjectionsService {
  stateOf(
    session: unknown,
    key: 'modelSelection',
  ): ModelSelectionProjectionView | undefined
}

/** `sessionController` 的读取面（只取本插件要的两个方法）。 */
interface SessionControllerService {
  modelCatalog(): Promise<ModelCatalogView>
}

/** `agents` 注册表的读取面（`packages/core/agent/src/index.ts:566` 的 `get`）。 */
interface AgentsRegistry {
  get(id: string): { session?: unknown } | undefined
}

export interface ModelFaceDeps {
  /** 通道别名 → DSH 会话 id（契约 §5.1）。不认识的别名返回 `undefined`。 */
  sessionOf(sid: string): string | undefined
}

export interface ModelFace {
  /** 按 provider 分组的可路由模型 + 部署默认值。拿不到就返回 `undefined`（能力位为 false）。 */
  catalog(): Promise<ModelCatalogView | undefined>
  /**
   * 一个会话**下一次**将用的模型；没有待定时退回**上一次实际用过**的。
   *
   * 两者都取不到（新会话、或投影还没落）时返回 `undefined` —— 手机侧显示"未选择"，
   * 而不是猜一个。猜一个就是把"看起来连着"当成"连着"。
   */
  modelOf(sid: string): ModelRef | undefined
}

/**
 * 建模型面的 DSH 半边。
 *
 * 三个服务键全部走 `ctx.get`（缺了就是能力位为 false，不是抛异常 ——
 * 裸读 `ctx.sessionController` 在服务缺失时抛，见 `dsh/caps.ts` 的文件头）。
 */
export function createModelFace(ctx: Context, deps: ModelFaceDeps): ModelFace {
  const controllerOf = (): SessionControllerService | undefined =>
    (ctx.get('sessionController') as SessionControllerService | undefined) ?? undefined
  const projectionsOf = (): SessionProjectionsService | undefined =>
    (ctx.get('sessionProjections') as SessionProjectionsService | undefined) ?? undefined
  const agentsOf = (): AgentsRegistry | undefined =>
    (ctx.get('agents') as AgentsRegistry | undefined) ?? undefined

  return {
    async catalog() {
      const controller = controllerOf()
      if (controller === undefined) return undefined
      try {
        return await controller.modelCatalog()
      } catch {
        // 目录是**展示用**的：某个 provider 的 key 没配时 DSH 自己会隔离失败并返回其余分组
        // （`catalog.ts` 的 `Promise.all` + 分组 try）。到这里还抛就是真异常，
        // 让能力位退化成"没有目录"，手机显示"未选择"而不是崩。
        return undefined
      }
    },

    modelOf(sid) {
      const dshSessionId = deps.sessionOf(sid)
      if (dshSessionId === undefined) return undefined
      const projections = projectionsOf()
      const agents = agentsOf()
      if (projections === undefined || agents === undefined) return undefined
      const session = agents.get(dshSessionId)?.session
      if (session === undefined) return undefined
      const view = projections.stateOf(session, 'modelSelection')
      const picked = view?.next ?? view?.lastUsed
      if (picked === undefined || picked === null) return undefined
      return picked
    },
  }
}
