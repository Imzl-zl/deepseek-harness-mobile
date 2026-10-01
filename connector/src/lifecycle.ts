/**
 * 生命周期的顺序引擎（契约 §1.3）。
 *
 * ```text
 * mount
 *  ├─ 读配置 → 校验 relayUrl / 令牌存在
 *  ├─ store.open():迁移到当前 schema → 载入 devices / aliases / dedupe
 *  ├─ 发布服务 ctx.provide('dshMobileConnector', api)   ← 手机端能力门控读它
 *  ├─ 注册 answerer(TakeoverGate 判定,§6.2)
 *  ├─ transport.start():出站连接(退避)→ 握手 → serving
 *  └─ 订阅策略:只为"手机已订阅的会话"建立 follow
 *
 * dispose
 *  ├─ 停止接受新请求 → 等待在途请求
 *  ├─ flush:缓冲落盘 + 去重表落盘
 *  ├─ transport.stop():发 close,关闭 WS
 *  └─ store.close()
 * ```
 *
 * 顺序本身是这一节的实质，而且有两处最容易写错：
 *
 * 1. **mount 中途失败必须回滚已完成的步骤**（逆序）。否则一次失败的挂载会留下
 *    一个已打开但没人持有的 store —— 下次挂载时 `open` 会撞 `already-open`，
 *    而错误信息完全指向不了真正的起因。
 * 2. **dispose 必须尽力而为**：某一步抛错不能拦住后面的步骤。尤其 `transport.stop()`
 *    失败时**仍然必须** `store.close()`，否则下一次挂载会看到半开的存储。
 *    所以错误是**收集**起来最后一个抛，不是遇错即停。
 *
 * 本文件不碰 DSH、不碰 I/O：步骤由调用方给，它只管顺序与回滚。
 */

export interface LifecycleStep {
  /** 步骤名，用于错误信息与 `completed` 列表。 */
  name: string
  run(): Promise<void> | void
  /**
   * 逆操作。两处会调用它：mount 中途失败时回滚，以及 `dispose()`。
   *
   * 没有 `undo` 的步骤（比如"发布服务"，它随 fiber 一起回收）在回滚时被跳过 ——
   * 但**必须是有意的**，不要用空函数糊过去。
   */
  undo?(): Promise<void> | void
}

export interface Lifecycle {
  /** 已完成的步骤名，按完成顺序。 */
  readonly completed: readonly string[]
  /** 是否已经 dispose 过。 */
  readonly disposed: boolean
  /** 逆序执行 undo；错误收集后一并抛出。可重复调用（第二次是 no-op）。 */
  dispose(): Promise<void>
}

/** 多个步骤同时失败时，把它们的名字都带上 —— 只报第一个会掩盖后续的连锁失败。 */
export class LifecycleErrors extends Error {
  readonly causes: readonly { step: string; error: unknown }[]

  constructor(phase: string, causes: readonly { step: string; error: unknown }[]) {
    super(
      `${phase} 阶段有 ${causes.length} 个步骤失败：` +
        causes.map((c) => `${c.step}(${c.error instanceof Error ? c.error.message : String(c.error)})`).join('；'),
    )
    this.name = 'LifecycleErrors'
    this.causes = causes
  }
}

async function unwind(
  steps: readonly LifecycleStep[],
): Promise<{ step: string; error: unknown }[]> {
  const failures: { step: string; error: unknown }[] = []
  // 逆序：后建的先拆。这在"先开 store 再注册 answerer"这类依赖上是必须的。
  for (const step of [...steps].reverse()) {
    if (step.undo === undefined) continue
    try {
      await step.undo()
    } catch (error) {
      failures.push({ step: step.name, error })
    }
  }
  return failures
}

/**
 * 按给定顺序执行 mount 步骤。
 *
 * @throws {LifecycleErrors} 任一步骤失败时；抛出前会把**已完成**的步骤逆序回滚。
 */
export async function mount(steps: readonly LifecycleStep[]): Promise<Lifecycle> {
  const done: LifecycleStep[] = []

  for (const step of steps) {
    try {
      await step.run()
    } catch (error) {
      const rollbackFailures = await unwind(done)
      const causes = [{ step: step.name, error }, ...rollbackFailures]
      throw new LifecycleErrors('mount', causes)
    }
    done.push(step)
  }

  let disposed = false
  return {
    get completed() {
      return done.map((s) => s.name)
    },
    get disposed() {
      return disposed
    },
    async dispose() {
      if (disposed) return
      disposed = true
      const failures = await unwind(done)
      // 尽力而为：即使 transport.stop() 失败，store.close() 也已经跑过了。
      if (failures.length > 0) throw new LifecycleErrors('dispose', failures)
    },
  }
}
