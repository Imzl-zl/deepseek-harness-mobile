/**
 * 插件入口：装配、发布服务、dispose（契约 §1.3）。
 *
 * 顺序由 `lifecycle.ts` 的引擎保证（含 mount 中途失败的回滚、dispose 的尽力而为），
 * 本文件只负责**把零件接成那五步**：
 *
 * ```text
 * 1 validate-config     校验 relayUrl / 令牌引用存在
 * 2 open-store          两个 domain 打开 + meta 按 schema 逐代迁移
 * 3 publish-service     ctx.provide('dshMobileConnector', api) ← 手机端能力门控读它
 * 4 register-answerers  审批与提问的 claim-or-delegate（§6.2）
 * 5 start-transport     出站 WSS
 * ```
 *
 * 两处刻意的选择：
 *
 * - **`inject` 只列必需服务**。可选能力一律 `ctx.get` 读出来当能力位 —— 因为
 *   `inject` 里写了一个不存在的服务会让 fiber 永远 PENDING，而那是**无异常、无日志、
 *   无 UI 报错**的静默降级（`caps.ts` 有完整理由）。
 * - **配置不全就拒绝挂载**，不是"空跑等配置"。一个连着中转却没有 relayUrl 的插件
 *   会在服务端制造一条永远不完整的配对记录，排查起来比挂载失败难得多。
 *
 * **方法面（契约 §5.7）尚未实现**：本节只处理连接层的四类帧（`ping` / `pong` /
 * `credit` / `presence`），其余帧按「未实现」**显式告警并计数**，不静默丢弃 ——
 * 静默丢弃会让手机端看到"请求发出去了但永远没有回应"，而电脑侧一片安静。
 *
 * 用到的 cordis 宿主接口（路径相对 DSH checkout 根）：
 *
 * | 接口 | 位置 |
 * |---|---|
 * | `ctx.provide(name, value?)` → 返回 disposer | `vendor/cordis/src/reflect.ts:44-46`（实现 `:277`） |
 * | `ctx.effect(execute, label?)` → 回调返回值即清理 | `vendor/cordis/src/fiber.ts:415-418` |
 * | `ctx.logger(name)` 取具名 logger；方法是 printf 风格 | `vendor/cordis/src/context.ts:27-28`、`vendor/cordis/src/logger.ts:191` |
 * | `ctx.get(name)` 探测服务（裸读会抛） | `vendor/cordis/src/reflect.ts:233-243`（裸读抛在 `:144`、`:159-161`） |
 * | `export const inject` 的语义（缺服务则永不激活） | `vendor/cordis/src/registry.ts:105-106`（`ctx.inject` 在 `:169-176`） |
 */
import type { Context } from '@deepseek-ai/cordis'

import { type ConnectorConfig, Config } from './config.js'
import { REQUIRED_SERVICES, readCaps, type Caps } from './dsh/caps.js'
import { registerInteractions, type RemoteInteractionPort } from './dsh/interactions.js'
import type { TakeoverDevice, TakeoverMode } from './protocol/takeover.js'
import type { WireFrame } from './protocol/frame.js'
import { mount, type LifecycleStep } from './lifecycle.js'
import { METRIC, createChannelLogger, createMetrics, type ChannelLogger, type ChannelMetrics } from './observability.js'
import { coreDomain, initialMeta, migrateMeta, windowsDomain } from './store/index.js'
import { createConnection, type Connection } from './transport/connection.js'

export const name = 'dsh-mobile-connector'

export { Config }

/** 只有必需服务进 `inject`；可选能力走 `ctx.get`（见文件头）。 */
export const inject: string[] = [...REQUIRED_SERVICES]

/** 发布给宿主的服务面。手机端的能力门控读 `caps()`。 */
export interface ConnectorService {
  caps(): Caps
  metrics(): Readonly<Record<string, number>>
}

/** 装配需要的东西。抽成一个对象，便于将来按需替换某一层。 */
interface Assembly {
  ctx: Context
  logger: ChannelLogger
  metrics: ChannelMetrics
  /** dispose 时用来打断在途异步。 */
  abort: AbortController
  /**
   * 中转地址与令牌引用，**在挂载时各取一次**。
   *
   * `Volatile<T>` 是稳定引用（`{ get() }`）而不是普通值，文档明说「保留引用，或为单次操作取值」。
   * 这两个值在挂载时就校验并用来建连，之后改它们需要**重新挂载** —— 参数是响应式的，
   * 但已经建立的连接不会自己换地址。如实写在这里，比假装支持热改要好。
   */
  relayUrl: string | undefined
  relayTokenSecretRef: string | undefined
}

function buildSteps(assembly: Assembly): LifecycleStep[] {
  const { ctx, relayUrl, relayTokenSecretRef, logger, metrics, abort } = assembly

  let closeStore: (() => Promise<void>) | null = null
  let connection: Connection | null = null
  let unregisterInteractions: (() => void) | null = null

  /** 设备状态与档位。真值在 store 里，这里给出 transport 需要的读取面。 */
  const takeover = {
    mode: (): TakeoverMode => 'foreground',
    devices: (): readonly TakeoverDevice[] => [],
    sidOf: (_dshSessionId: string): string | undefined => undefined,
  }

  const port: RemoteInteractionPort = {
    async askApproval(prompt, signal) {
      logger.debug('审批转手机（方法面未实现，按 fail-closed 收束）', { sid: prompt.sid })
      metrics.increment(METRIC.failClosed)
      void signal
      return 'reject'
    },
    async askQuestion(prompt) {
      metrics.increment(METRIC.failClosed)
      void prompt
      throw new Error('提问方法面尚未实现：不能返回空答案伪装成「用户全跳过」')
    },
  }

  return [
    {
      name: 'validate-config',
      run() {
        if (relayUrl === undefined || relayUrl === '') {
          throw new Error('relayUrl 未配置：拒绝挂载，而不是连上一个不完整的中转')
        }
        if (relayTokenSecretRef === undefined || relayTokenSecretRef === '') {
          throw new Error('relayTokenRef 未配置：连接器令牌的凭据引用缺失')
        }
      },
    },

    {
      name: 'open-store',
      async run() {
        const facility = ctx.storageDomain
        const core = await facility.open(coreDomain)
        const windows = await facility.open(windowsDomain)
        closeStore = async () => {
          await core.close()
          await windows.close()
        }

        // 迁移到当前 schema（契约 §1.4）。低于当前逐代升，高于当前拒绝启动。
        const stored = core.global.get()
        const migrated = migrateMeta(stored)
        if (migrated !== stored) {
          await core.global.set(migrated)
          logger.info(`存储 schema 已从 v${stored.schema} 迁移到 v${migrated.schema}`)
        } else if (migrated.connectorId === '') {
          // 「尚未配置」用空串表达（见 store/index.ts）：首次挂载时写入初值。
          await core.global.set(
            initialMeta({
              connectorId: 'local',
              relayUrl: relayUrl ?? '',
              connTokenSecretRef: relayTokenSecretRef ?? '',
            }),
          )
        }

        metrics.gauge(METRIC.pairedDevices, [...core.table('devices').keys()].length)
        abort.signal.addEventListener('abort', () => {
          void closeStore?.()
        })
        logger.debug('存储已打开', { domains: [core.name, windows.name] })
      },
      async undo() {
        await closeStore?.()
        closeStore = null
      },
    },

    {
      name: 'publish-service',
      run() {
        const service: ConnectorService = {
          caps: () => readCaps(ctx),
          metrics: () => metrics.snapshot(),
        }
        // `provide` 返回一个 disposer；挂到 ctx.effect 上让它随 fiber 回收。
        const dispose = ctx.provide('dshMobileConnector', service)
        ctx.effect(() => dispose)
      },
    },

    {
      name: 'register-answerers',
      run() {
        unregisterInteractions = registerInteractions(ctx, { port, takeover, log: logger })
      },
      undo() {
        unregisterInteractions?.()
        unregisterInteractions = null
      },
    },

    {
      name: 'start-transport',
      async run() {
        const next = createConnection({
          url: relayUrl ?? '',
          // Node 22+ 自带全局 WebSocket；不引第三方客户端。
          dial: (url) => new WebSocket(url) as never,
          log: logger,
          onStateChange: (from, to) => {
            metrics.increment(METRIC.stateTransitions)
            if (to === 'connecting') metrics.increment(METRIC.connects)
            logger.debug(`连接状态 ${from} → ${to}`)
          },
          onFrame: (frame: WireFrame) => {
            metrics.increment(METRIC.inboundFrames)
            handleFrame(frame)
          },
        })
        connection = next

        const handleFrame = (frame: WireFrame): void => {
          switch (frame.t) {
            case 'ping':
              // 连接层保活。回 pong 让对端不必等超时。
              next.send({ v: 1, t: 'pong' })
              return
            case 'pong':
            case 'credit':
            case 'presence':
              // 保活计时已在 connection 内部按「任一方向有帧」重置；这里无需再动作。
              return
            default:
              // **不静默丢弃**：方法面未实现时，手机端会看到"发出去但没回应"，
              // 而电脑侧一片安静 —— 那是最难查的一类故障。
              metrics.increment(METRIC.rejectedFrames)
              logger.warn(`收到尚未实现的方法面帧：${frame.t}（契约 §5.7 未落地）`)
          }
        }

        next.start()
        abort.signal.addEventListener('abort', () => {
          connection?.stop()
          connection = null
        })
      },
      undo() {
        connection?.stop()
        connection = null
      },
    },
  ]
}

export function apply(ctx: Context, config: ConnectorConfig): void {
  const logger = createChannelLogger(ctx.logger(name))
  const metrics = createMetrics()
  // `Volatile<T>` 是稳定引用而非普通值：取一次快照，之后不再重新读（见 `Assembly` 的说明）。
  const relayUrl = config.relayUrl.get()
  const relayTokenSecretRef = config.relayTokenRef.get()

  ctx.effect(() => {
    const abort = new AbortController()
    let mounted: Awaited<ReturnType<typeof mount>> | null = null

    const started = mount(
      buildSteps({ ctx, relayUrl, relayTokenSecretRef, logger, metrics, abort }),
    ).then(
      (lifecycle) => {
        mounted = lifecycle
        logger.info('dsh-mobile connector 已挂载')
      },
      (error: unknown) => {
        // 挂载失败要吵：静默半挂的插件会让手机端一直连不上而电脑侧没有线索。
        logger.error('挂载失败，通道未启动', error)
      },
    )

    return async () => {
      abort.abort()
      await started
      if (mounted !== null) {
        try {
          await mounted.dispose()
          logger.info('dsh-mobile connector 已卸载')
        } catch (error) {
          logger.error('卸载时有步骤失败（其余步骤已尽力执行）', error)
        }
      }
    }
  })
}
