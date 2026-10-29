/**
 * 配置热改的**后果**：哪些键变了要重建哪条通道，以及"重建"这件事的串行队列。
 *
 * ## 为什么单开一层
 *
 * 2026-10-29 的「连接」卡让面板能在不重启 DSH 的前提下改 `relayUrl` / `listenPort`，
 * 生效路径是 loader 把新值提交进运行中的 volatile 引用并发 `loader/volatile-update`
 * （`vendor/loader/src/config/entry.ts:184,191`）。剩下两件事是**我们的政策**：
 *
 * 1. **键集合 → 哪条通道**：`relayUrl` 改了只重建中转，`listenPort` 改了只重建直连。
 *    这条判据原来写在 `index.ts` 的装配闭包里，只能靠隔离实例手工 e2e 验
 *    （改面板 → 看日志里有没有重建、另一条有没有被无辜重启）。
 * 2. **重建必须串行**：手改 `cordis.patch.yml` 连点两次就会排两次，而并发
 *    stop/start 会互踩 —— 第二次 stop 可能落在第一次 start 的半途，结果是一条
 *    "显示已启动、实际没连上"的通道。队列本身**不抛**：失败是界面上的一个原因
 *    （「连接」卡的 `relayError`），不是装配层的异常。
 *
 * 两者都是纯判据/纯状态机，抽出来由 `tests/transport-rebuild.test.ts` 钉住；
 * 装配层只做接线（`tests/assembly-wiring.test.ts` 断言它真的接上了）。
 * 为什么值得单开一层、以及被否的四个替代方案，见
 * `.agents/notes/implemented/2026-10-29-assembly-regression-net.md`。
 *
 * ## 为什么只有这两组键
 *
 * 别的 volatile 字段（`frameLimitBytes`、`refetchThresholdBytes`、四个窗口上界…）改完
 * **下次读写时自然生效**，没有"已经建立的连接还握着旧值"这回事 —— 顺手重启通道
 * 的代价是一次无故掉线。所以不进这张表不是遗漏，是判断。
 */

/** 可重建的通道（顺序即"一次事件命中两条时"的排队顺序）。 */
export const REBUILD_CHANNELS = ['relay', 'direct'] as const
export type RebuildChannel = (typeof REBUILD_CHANNELS)[number]

/**
 * 哪些配置键变了要重建哪条通道。**唯一出处**（改它等于改"哪些改动会让人掉线"）。
 *
 * 键名是 `settings.describe` 里那个条目 `config:` 块的**顶层键**
 * （与 `config.ts` 的 schema 同名），不是凭据或路径。
 */
export const REBUILD_KEYS: Readonly<Record<RebuildChannel, readonly string[]>> = {
  relay: ['relayUrl', 'allowInsecureLocal', 'allowInsecurePublic', 'relayTokenRef'],
  direct: ['listenPort', 'listenHost'],
}

/**
 * `loader/volatile-update` 的载荷 → 要重建的通道（可能为空）。
 *
 * 载荷每格是**路径段数组**（`['relayUrl']`），所以按"段拼点"比较整名，
 * 不是前缀匹配：`relayUrlFoo` 与 `relayUrl` 是两格。
 */
export function channelsToRebuild(
  paths: readonly (readonly string[])[],
): RebuildChannel[] {
  const changed = new Set(paths.map((path) => path.join('.')))
  return REBUILD_CHANNELS.filter((channel) =>
    REBUILD_KEYS[channel].some((key) => changed.has(key)),
  )
}

export interface RebuildQueue {
  /** 排一次重建。返回的 promise **永不 reject**（失败记成原因）。 */
  enqueue(channel: RebuildChannel): Promise<void>
  /** 等当前已排的全部落地（保存回执据此读到重建后的真值）。 */
  settle(): Promise<void>
  /** 最近一次重建的失败原因；之后有一次成功就清掉。 */
  failure(): string | undefined
}

/**
 * 建重建队列。
 *
 * @param rebuild - 真做"停 → 起"的那一步。失败**抛出**，由队列接住。
 * @param onFailure - 失败时的留痕口（日志 + 「连接」卡的原因）。**不接管**失败语义：
 *   队列仍然只把它记成一个可显示的原因，不重试、不换通道 —— 宿主那边没有"重建传输"
 *   这个概念，重试策略是我们的猜测，不是它的语义。
 */
export function createRebuildQueue(
  rebuild: (channel: RebuildChannel) => Promise<void>,
  onFailure: (channel: RebuildChannel, error: unknown) => void = () => {},
): RebuildQueue {
  let tail: Promise<void> = Promise.resolve()
  let failure: string | null = null

  return {
    enqueue(channel) {
      // 关键：只接在**上一次**的尾巴后面。这不只是"排队"，也是"同一时刻只有一次
      // 停/起在跑"的机械保证 —— 并发 stop/start 会互踩（见文件头）。
      const run = tail.then(async () => {
        // 每次重建开始就清空：`settle()` 报的是**这一轮**的原因，
        // 否则一次历史失败会永远挂在界面上。
        failure = null
        try {
          await rebuild(channel)
        } catch (error) {
          failure = error instanceof Error ? error.message : String(error)
          onFailure(channel, error)
        }
      })
      tail = run
      return run
    },
    settle: () => tail,
    failure: () => failure ?? undefined,
  }
}
