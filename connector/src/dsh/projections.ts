/**
 * 会话投影的读取面（`session.projections`，契约 §5.7）。
 *
 * ## 为什么是这一个方法，而不是每面一个
 *
 * DSH 的 `SessionController` 有一个 `@Remote('projections')`
 * （`packages/api/session-controller/src/index.ts:506`），请求体只有
 * `{ sessionId }`，返回**所有已注册投影的当前值**。已核实的键里与
 * "界面上看得见的东西"相关的有 20+ 个：`modelSelection` / `permissions` /
 * `subagentCatalog` / `deliverables` / `tokenUsage` / `contextPressure` /
 * `sessionStats` / `turnOutline` / `todos` / `goal` / `plan` / `inbox` /
 * `title` / `workingDirectory` / `agentPreset` / `userQuestions` …
 *
 * 每面各开一个通道方法（`session.tokenUsage` / `session.turnOutline` / …）
 * 等于把 DSH 已有的投影面**翻译一遍** —— 而"翻译层就是漂移层"：投影改一个字段，
 * 我们要跟着改 N 个方法。只透传这一个口，形状变了只改一处解析。
 *
 * ## 为什么原样透传，不挑字段
 *
 * 投影的 `viewSchema` 是 zod `.strict()`，多一个字段都会被拒。
 * 在这里"挑着发"就要预先知道全部键，而那正是会漂移的那份清单。
 * 手机侧按需取、认不出就不给（`app_model.dart` 的 `_parseSessionList`
 * 已经是这个纪律）。
 *
 * ## 为什么要拆掉 DSH 的那层信封
 *
 * `@Remote('projections')` 的返回类型是 `SessionProjectionValue` 联合
 * （`session-controller/src/index.ts:507`）：`null`（会话不存在）或
 * `{kind: 'sequenced' | 'migration-required', asOfSeq, values}`。
 * **契约 §5.7 承诺给手机的是"所有已注册投影的当前值"**，也就是 `values`；
 * `kind` / `asOfSeq` 是 DSH 自己的传输细节，手机不需要认识它。
 *
 * 2026-10-15 直接把整个信封透传了下去，于是手机拿到的 Map 的键是
 * `kind` / `asOfSeq` / `values`，`tokenUsage` / `permissions` / `subagentCatalog`
 * **一个都取不到** —— 统计条、上下文环、子智能体面板在生产里全是空态，
 * 而单测全绿（测试替身直接返回 `values` 映射，绕开了信封）。
 * 教训与 `tools.md` 里"两个零件各自测过不等于接起来能跑"同一条：
 * **替身必须复现真值的形状，否则它证明的是别的东西。**
 * 取舍（为何拆在连接器而不是手机侧）见
 * `.agents/notes/implemented/2026-10-15-projections-envelope-must-be-unwrapped.md`。
 *
 * ## 代价
 *
 * 一次响应是一大包（所有键）。已核实的键有 20+ 个，单次可能几十 KB。
 * 若实测太大，退路是"只读需要的键"—— 但那要动契约，本期不做。
 */
import type { SessionController } from '@deepseek-ai/dsh-api-session-controller'

/** 投影读取面（**收窄成这一层真正用到的方法**）。 */
export interface ProjectionsPort {
  /**
   * 读一个会话的全部投影当前值。
   *
   * @param dshSessionId - DSH 的会话 id（**不是**手机见的 `sid`；别名映射在方法面）
   * @returns 投影值映射；形状由 DSH 定，本层不改一个投影键
   */
  of(dshSessionId: string): Promise<unknown>
}

/**
 * 从 DSH 的 `SessionProjectionValue` 联合里取出 `values`。
 *
 * `null`（会话不存在）与"没有 `values` 字段"都归一成**空映射**而不是 `null`：
 * 手机侧的空态由"这个键没有值"驱动，而一个空映射让所有只读面一致地显示空态；
 * 回 `null` 会让 `refreshProjections` 早退，于是**上一次的旧值继续显示**——
 * 那正是"投影读不到却挂着旧数字"的形态。
 */
function valuesOf(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || value === null) return {}
  const values = (value as { values?: unknown }).values
  return typeof values === 'object' && values !== null ? (values as Record<string, unknown>) : {}
}

/**
 * 建投影面。
 *
 * 直接收 `SessionController`（而不是从 `ctx.get` 拿）：`sessionController`
 * 是本插件的**必需**服务（缺了它插件根本不挂载），而"挂不挂这个方法"的判据
 * 是另一个服务 `sessionProjections` 在不在（见 `index.ts` 的注入点）——
 * 两个服务分开判，才不会出现"controller 在但投影服务不在"还硬着头皮调。
 */
export function createProjectionsPort(controller: SessionController): ProjectionsPort {
  return {
    async of(dshSessionId) {
      // `@Remote('projections')` 的签名是 `(request, signal)`；
      // 方法面没有请求级信号（手机没有"取消这次读取"），
      // 用一个永不中止的信号比每次现造一个 `AbortController` 再丢掉更直白。
      const value = await controller.projections(
        { sessionId: dshSessionId as never },
        AbortSignal.timeout(30_000),
      )
      // **拆信封**：给手机的是 `values`，不是 DSH 的 `{kind, asOfSeq, values}`
      // （理由见文件头"为什么要拆掉 DSH 的那层信封"）。
      return valuesOf(value)
    },
  }
}
