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
 * 5 load-identity       取（或首次生成）本机身份种子（§12.1）
 * 6 start-transport     出站 WSS，并把 §4.1 的握手交给驱动器
 * ```
 *
 * 两处刻意的选择：
 *
 * - **`inject` 只列必需服务**。可选能力一律 `ctx.get` 读出来当能力位 —— 因为
 *   `inject` 里写了一个不存在的服务会让 fiber 永远 PENDING，而那是**无异常、无日志、
 *   无 UI 报错**的静默降级（`caps.ts` 有完整理由）。
 * - **配置不全就拒绝挂载**，不是"空跑等配置"。一个连着中转却没有 relayUrl 的插件
 *   会在服务端制造一条永远不完整的配对记录，排查起来比挂载失败难得多。
 *   身份同理：拿不到身份种子就不启动通道，而不是每次重启换一套新身份。
 *
 * `credentials` 从"可选"升成了必需服务（`caps.ts` 有 cite）：电脑侧身份种子存在凭据 seam 里，
 * 没有它连握手都构造不出来 —— 把这种前提当可选项，只会得到一个永远握不了手的空壳。
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
import { loadOrCreateIdentity, type Identity } from './dsh/identity.js'
import { registerInteractions, type RemoteInteractionPort } from './dsh/interactions.js'
import type { TakeoverDevice, TakeoverMode } from './protocol/takeover.js'
import type { WireFrame } from './protocol/frame.js'
import { createHandshakeDriver } from './protocol/handshake-driver.js'
import { createBoxCodec } from './protocol/box.js'
import { createHandlers } from './handlers.js'
import { createMethodFace } from './method-face.js'
import { createIdempotency, type DedupeRows } from './idempotency.js'
import { mount, type LifecycleStep } from './lifecycle.js'
import { METRIC, createChannelLogger, createMetrics, type ChannelLogger, type ChannelMetrics } from './observability.js'
import { createAliases, type Aliases } from './alias.js'
import { createSessionsAdapter } from './dsh/sessions.js'
import type { DeviceRecord } from './store/index.js'
import { coreDomain, initialMeta, migrateMeta, windowsDomain } from './store/index.js'
import { createConnection, type Connection } from './transport/connection.js'

export const name = 'dsh-mobile-connector'

export { Config }

/**
 * `pcId` 的默认值。只在存储里还没有 `connectorId` 时写入一次，之后一直读存储的那个 ——
 * 它参与握手 transcript，换一次就等于所有设备的握手全部验签失败。
 */
const DEFAULT_CONNECTOR_ID = 'local'

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
  /** 接管档位（契约 §6.2）。同样是挂载时取一次快照。 */
  approvalTakeover: TakeoverMode
}

function buildSteps(assembly: Assembly): LifecycleStep[] {
  const { ctx, relayUrl, relayTokenSecretRef, approvalTakeover, logger, metrics, abort } = assembly

  let closeStore: (() => Promise<void>) | null = null
  let connection: Connection | null = null
  let unregisterInteractions: (() => void) | null = null

  /** 设备状态与档位。真值在 store 里，这里给出 transport 需要的读取面。 */
  /**
   * 挂载期才可用的东西。`open-store` 之前都是 null —— 所以 `takeover` 里的读取
   * 一律走可选链，而不是假设它们已就绪。
   */
  let aliases: Aliases | null = null
  let devicesTable: {
    get(key: string): DeviceRecord | undefined
    keys(): Iterable<string>
  } | null = null
  /** 幂等表（`core` 域的 `dedupe` 表）。写在库里的行要参与 §5.6 的"命中即回上次结果"。 */
  let dedupeRows: DedupeRows | null = null
  /** 本机身份（§4.1）。在 `load-identity` 之前是 null，`start-transport` 之前必然已就绪。 */
  let identity: Identity | null = null
  /** 本机标识：进 `hello-ack` 的 `pcId`，因而参与 transcript。 */
  let connectorId = ''

  /**
   * 已认证设备的**瞬时**状态（在线、前台、已订阅、最近交互）。
   *
   * 持久部分（身份、配对时间）在设备表里；这一份由连接层在设备完成鉴权后写入。
   * **现在恒为空** —— 设备鉴权与 presence 上报还没落地，所以 answerer 仍然不会 claim。
   * 但原因从"别名查不到"变成了"还没有设备在线"，这是正确的中间状态，不是缺陷。
   */
  const liveRegistry = new Map<
    string,
    {
      online: boolean
      foreground: boolean
      subscribed: string[]
      lastInteractedAt?: Record<string, number>
    }
  >()

  const liveDevices = (): readonly TakeoverDevice[] => {
    const table = devicesTable
    if (table === null) return []
    const rows: TakeoverDevice[] = []
    for (const [id, live] of liveRegistry) {
      const record = table.get(id)
      // **连接层认证过不等于授权过**：没配过对、或已吊销的设备一律不参与仲裁。
      if (record === undefined || record.revokedAt !== undefined) continue
      rows.push({
        id,
        pairedAt: record.pairedAt,
        online: live.online,
        foreground: live.foreground,
        subscribed: live.subscribed,
        ...(live.lastInteractedAt === undefined
          ? {}
          : { lastInteractedAt: live.lastInteractedAt }),
      })
    }
    return rows
  }

  const takeover = {
    mode: (): TakeoverMode => approvalTakeover,
    devices: liveDevices,
    sidOf: (dshSessionId: string): string | undefined => aliases?.sidOf(dshSessionId),
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
              connectorId: DEFAULT_CONNECTOR_ID,
              relayUrl: relayUrl ?? '',
              connTokenSecretRef: relayTokenSecretRef ?? '',
            }),
          )
        }

        metrics.gauge(METRIC.pairedDevices, [...core.table('devices').keys()].length)

        // 本机标识：`pcId` 进 transcript，必须**稳定** —— 换一次，所有在途握手都会验签失败。
        // 空串是「尚未配置」的哨兵（见 store/index.ts），这里用与写入时同一个默认值。
        connectorId = migrated.connectorId === '' ? DEFAULT_CONNECTOR_ID : migrated.connectorId

        // 别名：先对账两个方向再用 —— 崩在两次 put 之间的残留在这一步被清掉，
        // 否则残缺的 by_sid 会让入站 sid 校验失败，或让 ensure 重复分配别名。
        devicesTable = core.table('devices')
        dedupeRows = core.table('dedupe')
        aliases = createAliases(
          { bySid: core.table('by_sid'), bySession: core.table('by_session') },
          { initialVersion: migrated.aliasVersion },
        )
        const repaired = await aliases.reconcile()
        if (repaired > 0) {
          logger.warn(`清理了 ${repaired} 条残留的会话别名（上次可能崩在写中间）`)
        }
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
      name: 'load-identity',
      async run() {
        // `credentials` 在 `inject` 里（必需服务，见 `caps.ts`），所以这里可以裸读 ——
        // 与 `open-store` 读 `ctx.storageDomain` 同一个写法。
        const loaded = await loadOrCreateIdentity(ctx.credentials)
        identity = loaded
        logger.debug('本机身份已就绪', { pcId: connectorId })
      },
    },

    {
      name: 'start-transport',
      async run() {
        const local = identity
        if (local === null) {
          // 步骤顺序由 `lifecycle.ts` 保证，所以走到这里必然是装配写错了，而不是"还没准备好"。
          throw new Error('start-transport 在身份就绪前被调用：装配顺序有误')
        }

        // 方法面：先建 handler 表（`repo.info` 报的就是这张表的键），再交给方法面接线。
        // 两者都在这一步构造：它们依赖 `open-store`/`publish-service` 的产物，且**每次挂载一套**。
        // 幂等表在挂载时先收敛一次：TTL（24h）与容量（10000）在契约里是硬约束，
        // 而它没有定时器 —— 收敛点就取"挂载"与"超容量"两处。
        const idempotency =
          dedupeRows === null ? null : createIdempotency({ rows: dedupeRows, log: logger })
        if (idempotency !== null) {
          const removed = await idempotency.prune()
          if (removed > 0) logger.debug(`幂等表挂载时收敛：清掉 ${removed} 条过期/超容条目`)
        }

        const methodFace = createMethodFace({
          handlers: createHandlers({
            caps: () => readCaps(ctx),
            aliasVersion: () => aliases?.version ?? 0,
            sessions: createSessionsAdapter(ctx.sessionController),
            aliases: {
              ensure: (dshSessionId) => {
                if (aliases === null) {
                  // 步骤顺序由 `lifecycle.ts` 保证：`open-store` 一定先跑过。
                  throw new Error('别名表尚未就绪：装配顺序有误')
                }
                return aliases.ensure(dshSessionId)
              },
            },
            devices: () =>
              devicesTable === null
                ? []
                : [...devicesTable.keys()].flatMap((id) => {
                    const record = devicesTable?.get(id)
                    if (record === undefined) return []
                    return [
                      {
                        id,
                        name: record.name,
                        pairedAt: record.pairedAt,
                        revoked: record.revokedAt !== undefined,
                      },
                    ]
                  }),
          }),
          ...(idempotency === null ? {} : { idempotency }),
          onError: (message, detail) => logger.warn(message, detail),
        })
        logger.debug(`方法面已就绪：${methodFace.implemented.length} 个方法`, {
          methods: [...methodFace.implemented],
        })

        const next = createConnection({
          url: relayUrl ?? '',
          // Node 22+ 自带全局 WebSocket；不引第三方客户端。
          dial: (url) => new WebSocket(url) as never,
          log: logger,
          secure: {
            handshake: createHandshakeDriver({
              identity: { dh: local.keys.dh, signSeedHex: local.keys.signSeedHex },
              pcId: connectorId,
              peerOf: (devId) => {
                const record = devicesTable?.get(devId)
                // 未配对、已吊销、查不到一律 undefined：对手机都是同一件事（§3.1 的 not-paired）。
                if (record === undefined || record.revokedAt !== undefined) return undefined
                return {
                  edPubHex: record.edPub,
                  dhPubHex: record.dhPub,
                  pairingId: record.pairingId,
                }
              },
            }),
            // 电脑侧永远是应答方（`responder` = B）：`kA2B` 解入站、`kB2A` 封出站。
            // 映射写在协议层一处，写反了不会报错、只会两侧都解不开（§4.1 的教训）。
            createCipher: (keys) => createBoxCodec({ keys, role: 'responder' }),
          },
          onEstablished: ({ devId }) => {
            metrics.increment(METRIC.handshakesEstablished)
            logger.info(`握手完成：设备 ${devId} 已建立端到端会话`)
          },
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
              // 连接层保活。回 pong 让对端不必等超时。空载荷也要封箱（§3）。
              next.send({ v: 1, t: 'pong', box: '' })
              return
            case 'pong':
            case 'credit':
            case 'presence':
              // 保活与流控记账已在 connection 内部处理；这里无需再动作。
              return
            case 'req':
              // 方法面。**异步**：handler 可能要等 DSH 服务，而收帧路径不能阻塞
              // （同一条 socket 上还有 `credit` / 保活要走）。
              void methodFace.handle(frame).then((response) => {
                if (response === null) return
                // 发不出去就留声：手机在等这个 `res`，静默丢弃会变成"永远转圈"。
                if (!next.send(response)) {
                  metrics.increment(METRIC.rejectedFrames)
                  logger.warn(`应答 ${frame.id} 没发出去（连接不在服务态或窗口拒绝）`)
                }
              })
              return
            default:
              // **不静默丢弃**：手机端会看到"发出去但没回应"，而电脑侧一片安静 ——
              // 那是最难查的一类故障。`res` / `ev` / `live` / `persisted` 都是电脑侧发出的方向，
              // 从手机收到它们说明对端跑错了协议。
              metrics.increment(METRIC.rejectedFrames)
              logger.warn(`收到电脑侧方向的帧：${frame.t}（手机不该发这个）`)
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
  const approvalTakeover = config.approvalTakeover.get()

  ctx.effect(() => {
    const abort = new AbortController()
    let mounted: Awaited<ReturnType<typeof mount>> | null = null

    const started = mount(
      buildSteps({
        ctx,
        relayUrl,
        relayTokenSecretRef,
        approvalTakeover,
        logger,
        metrics,
        abort,
      }),
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
