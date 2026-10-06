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
 * 6 start-transport     出站 WSS，并把 §4.1 的握手交给驱动器；配了 `listenPort` 时**同时**起直连监听面
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
 * **本文件只管"挂载级"的装配**（一条连接一份的东西都不在这里）：入站帧的处理、方法面、
 * 会话订阅、配对端点全是**每连接**的，装配在 `connection-scope.ts` 的
 * `createConnectionScope(port, deps)` 里 —— `port` 就是"每条 socket 各一份"的那条缝。
 * 为什么这条缝只有 4 个成员、以及哪些构造物**不**该跟着连接走（增量缓冲），见那个文件与
 * `.agents/notes/implemented/2026-10-01-per-connection-scope-is-an-extraction.md`。
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
import { deriveIdentity } from './protocol/crypto.js'
import { loadOrCreateIdentity, type Identity } from './dsh/identity.js'
import { PAIRING_TTL_MS, createPairing } from './pairing.js'
import type { PairedDeviceRow } from './pairing-endpoint.js'
import { readRelayToken } from './dsh/relay-token.js'
import { createPairingRegistrar } from './pairing-register.js'
import { offerForScanning } from './pairing-offer.js'
import { registerInteractions, type RemoteInteractionPort } from './dsh/interactions.js'
import type { TakeoverDevice, TakeoverMode } from './protocol/takeover.js'
import { createHandshakeDriver } from './protocol/handshake-driver.js'
import { createBoxCodec } from './protocol/box.js'
import type { WireFrame } from './protocol/frame.js'
import type { HandlerDeps } from './handlers.js'
import { createIdempotency, type DedupeRows } from './idempotency.js'
import {
  createConnectionScope,
  type ConnectionScope,
  type ConnectionScopeDeps,
} from './connection-scope.js'
import { mount, type LifecycleStep } from './lifecycle.js'
import { METRIC, createChannelLogger, createMetrics, type ChannelLogger, type ChannelMetrics } from './observability.js'
import { createAliases, type Aliases } from './alias.js'
import type { JobRegistry } from '@deepseek-ai/dsh-jobs'
import { createJobsPort, createJobControlPort, type JobControlService } from './dsh/jobs.js'
import { createSessionBuffer } from './session-buffer.js'
import { createSessionsAdapter } from './dsh/sessions.js'
import type { DeviceRecord } from './store/index.js'
import { coreDomain, initialMeta, migrateMeta, windowsDomain } from './store/index.js'
import { createConnection, type Connection, type DialSocket } from './transport/connection.js'
import { startListener, type Listener } from './transport/listener.js'

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
  /** 直连监听面（§1.7）：`0` = 不监听。同样是挂载时取一次快照。 */
  listenPort: number
  listenHost: string
  /** 接管档位（契约 §6.2）。同样是挂载时取一次快照。 */
  approvalTakeover: TakeoverMode
}

function buildSteps(assembly: Assembly): LifecycleStep[] {
  const { ctx, relayUrl, relayTokenSecretRef, listenPort, listenHost, approvalTakeover, logger, metrics, abort } =
    assembly

  let closeStore: (() => Promise<void>) | null = null
  let connection: Connection | null = null
  /** 直连监听面（§1.7）。只有配了 `listenPort` 才非空。 */
  let listener: Listener | null = null
  /**
   * 这条连接的**已认证设备**由 `connection-scope.ts` 记着（增量缓冲的水位按设备记，
   * 契约 §5.5）—— 它是每连接的状态，所以不放在这里。
   */
  let unregisterInteractions: (() => void) | null = null
/** 出码命令的注销（ctx.commands.register 返回的就是它）。 */
let unregisterPairingCommand: (() => void) | null = null

  /** 设备状态与档位。真值在 store 里，这里给出 transport 需要的读取面。 */
  /**
   * 挂载期才可用的东西。`open-store` 之前都是 null —— 所以 `takeover` 里的读取
   * 一律走可选链，而不是假设它们已就绪。
   */
  let aliases: Aliases | null = null
  let devicesTable: {
    get(key: string): DeviceRecord | undefined
    keys(): Iterable<string>
    /** 配对成功要写设备行（§12.1 第 3 步）—— 这是**唯一**新增设备的路径。 */
    put(key: string, value: DeviceRecord): Promise<void>
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
        unregisterPairingCommand?.()
        unregisterPairingCommand = null
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

        // 下面这一段全是**挂载级**的东西：与"有几条连接"无关，一条也不该按连接重建。
        // 每连接的装配物（方法面 / 订阅 / 翻页器 / 配对端点）在 `connection-scope.ts` 里，
        // 由 `createConnectionScope(next, scopeDeps)` 按连接建一次。

        // 幂等表在挂载时先收敛一次：TTL（24h）与容量（10000）在契约里是硬约束，
        // 而它没有定时器 —— 收敛点就取"挂载"与"超容量"两处。
        const idempotency =
          dedupeRows === null ? null : createIdempotency({ rows: dedupeRows, log: logger })
        if (idempotency !== null) {
          const removed = await idempotency.prune()
          if (removed > 0) logger.debug(`幂等表挂载时收敛：清掉 ${removed} 条过期/超容条目`)
        }

        // 任务控制是**另一个**可选服务（`dsh-web-app` 提供，base 没有）：缺了就只列不停。
        const jobControl =
          ctx.get('jobController') === undefined
            ? null
            : createJobControlPort(ctx.get('jobController') as JobControlService)

        // 会话面适配器是纯闭包、无状态 —— 挂载时建一次，订阅流与翻页共用同一个。
        const sessions = createSessionsAdapter(ctx.sessionController)

        // 增量缓冲（§5.5）：每个被订阅的会话一段，裁剪权在手机手里（全部配对设备确认过才裁）。
        // **挂载级**：它的存在理由就是"断线重连后按 `since` 接着收"，跟着连接走会退化成每次灌快照
        //（完整理由见 `connection-scope.ts` 的文件头）。
        const sessionBuffer = createSessionBuffer({
          pairedDevices: () =>
            devicesTable === null
              ? []
              : [...devicesTable.keys()].filter((id) => devicesTable?.get(id)?.revokedAt === undefined),
          log: logger,
        })

        // 配对（§12.1）：核心由**主种子派生**（`Identity` 只存种子），与哪条连接无关。
        // `putDevice` 落 `devices` 表 —— 那是**唯一**新增设备的路径；配对成功后握手才认得出这台设备。
        const pcIdentity = deriveIdentity(local.masterSeed)
        const pairingCore = createPairing({
          // 二维码里的地址：**中转地址**（契约 §2 的拓扑里手机连的是中转）。
          relayUrl: relayUrl ?? '',
          pcPubEd: pcIdentity.sign.publicKeyHex,
          pcPubDh: pcIdentity.dh.publicKeyHex,
        })
        /** 字段名在这一层对齐（配对的设备行叫 `edPubHex`，域表叫 `edPub`）。 */
        const putDevice = async (devId: string, row: PairedDeviceRow): Promise<void> => {
          if (devicesTable === null) {
            throw new Error('devices 表尚未就绪：装配顺序有误')
          }
          await devicesTable.put(devId, {
            edPub: row.edPubHex,
            dhPub: row.dhPubHex,
            name: row.name,
            pairedAt: row.pairedAt,
            pairingId: row.pairingId,
          })
        }

        // 出码入口：一条斜杠命令。**登记不成就不出码**（`offerForScanning` 的判断），
        // 否则操作者会拿到一张扫了也配不上的二维码，而失败面出现在手机侧。
        const commands = ctx.get('commands') as
          | { register(definition: unknown): () => void }
          | undefined
        if (commands === undefined) {
          // `commands` 不在服务清单里时插件仍能工作（配对靠别的方式触发），所以只留声。
          logger.warn('commands 服务不在：`dsh-mobile-pair` 出码命令不可用')
        } else {
          const registerPairing = createPairingRegistrar({
            relayUrl: relayUrl ?? '',
            // 令牌**现读**（`readRelayToken` 不缓存）：出码是人工动作，换令牌后立刻生效；
            // 也省得为这个只在出码时用到的值安排装配顺序。
            tokenSource: () => readRelayToken(ctx.credentials, relayTokenSecretRef ?? ''),
            log: logger,
          })
          unregisterPairingCommand = commands.register({
            name: 'dsh-mobile-pair',
            description: `生成手机配对二维码（一次性、${Math.round(PAIRING_TTL_MS / 60_000)} 分钟有效）`,
            handler: () => offerForScanning({ pairing: pairingCore, register: registerPairing, log: logger }),
          })
        }

        /**
         * 方法面的挂载级依赖。**每连接的那三个端口不在这里** ——
         * `createHandlers` 的 deps 类型上已经不收它们（见 `ConnectionScopeDeps.handlers`）。
         */
        const handlerDeps: ConnectionScopeDeps['handlers'] = {
          caps: () => readCaps(ctx),
          aliasVersion: () => aliases?.version ?? 0,
          sessions,
          // 任务服务是**可选**的（`caps.ts` 的 OPTIONAL_SERVICES）：缺了就不挂 `job.*`，
          // 手机侧看到的是"这个方法不存在"，而不是一个会回错的按钮。
          ...(ctx.get('jobs') === undefined
            ? {}
            : { jobs: createJobsPort(ctx.get('jobs') as JobRegistry) }),
          ...(jobControl === null ? {} : { jobControl }),
          aliases: {
            ensure: (dshSessionId) => {
              if (aliases === null) {
                // 步骤顺序由 `lifecycle.ts` 保证：`open-store` 一定先跑过。
                throw new Error('别名表尚未就绪：装配顺序有误')
              }
              return aliases.ensure(dshSessionId)
            },
            sessionOf: (sid) => aliases?.sessionOf(sid),
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
        }

        /**
         * 每连接装配的输入。**拨号路径与将来的监听面共用这一份** ——
         * 一条 socket 一份的是 `port`，不是这里的东西。
         */
        const scopeDeps: ConnectionScopeDeps = {
          logger,
          metrics,
          handlers: handlerDeps,
          sessions,
          buffer: sessionBuffer,
          jobControl,
          pairing: pairingCore,
          putDevice,
          idempotency,
        }

        // 连接器令牌（§12.2）：**拨号与出码登记共用同一个值**，所以在这一步开头读一次。
        // 读不到就**大声失败**（`readRelayToken` 的契约）：起来一个连不上中转的插件没有意义。
        const relayToken = await readRelayToken(ctx.credentials, relayTokenSecretRef ?? '')

        /**
         * 每连接的装配产物。
         *
         * **必须在 `next.start()` / `attach()` 之前赋值**：两者都会**同步**推进状态
         * （`idle → connecting`），而下面的回调那时已经在用 `scope` —— 顺序反了会静默丢掉
         * 第一条状态回调。回调里的 `scopeOf()` 因此不是防御性写法，而是**装配顺序的断言**：
         * 走到"还没赋值"这条路上只可能是装配写错了（与 `lifecycle.ts` 的其他几处同一个口径）。
         *
         * 抽成工厂是因为**拨号与接受两条路各要一份**（监听面每 accept 一条就调一次）。
         * 两者共用同一份 `scopeDeps`，差别只有 `dial`：接受来的连接没有拨号目标。
         */
        const makeConnection = (dial: (url: string) => DialSocket): Connection => {
          let scope: ConnectionScope | null = null
          const scopeOf = (): ConnectionScope => {
            if (scope === null) {
              throw new Error('连接在每连接装配就绪前就开始收帧/迁状态：装配顺序有误')
            }
            return scope
          }

          const made = createConnection({
            url: relayUrl ?? '',
            dial,
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
              scopeOf().deviceEstablished(devId)
            },
            onStateChange: (from, to) => {
              metrics.increment(METRIC.stateTransitions)
              if (to === 'connecting') metrics.increment(METRIC.connects)
              logger.debug(`连接状态 ${from} → ${to}`)
              if (from === 'serving' && to !== 'serving') scopeOf().servingEnded()
            },
            onFrame: (frame: WireFrame) => {
              metrics.increment(METRIC.inboundFrames)
              scopeOf().handleFrame(frame)
            },
          })

          // 赋值必须在返回之前：调用方拿到它就会 `start()` / `attach()`。
          scope = createConnectionScope(made, scopeDeps)
          return made
        }

        /**
         * 拨号连接：连中转。**自愈** —— 断开后退避重连 `relayUrl`。
         *
         * Node 22+ 自带全局 WebSocket；不引第三方客户端。
         *
         * **连接器令牌走升级头的 `Authorization`**（§2.2）：实测 Node 的全局 `WebSocket`
         * 支持第二参数传 options 对象（undici 的非标准扩展，见笔记），所以这里能带头 ——
         * 三参数形式与裸调用都收不到（服务端只会看到 `(none)`）。
         * 令牌在装配时读一次（`readRelayToken` 不缓存，但**每次拨号都由同一个连接对象发起**，
         * 于是运行期换令牌需要重连 —— 这是可接受的：换令牌本来就意味着换一次连接）。
         */
        const dialed = makeConnection(
          (url) =>
            new WebSocket(url, {
              headers: { authorization: `Bearer ${relayToken}` },
            } as never) as never,
        )
        connection = dialed
        dialed.start()

        /**
         * 直连监听面（§1.7）。**只有配置里 `listenPort` 非 0 才起**，否则一行都不做 ——
         * 于是"没配监听"与"不监听"是同一件事，不是两套代码路径。
         *
         * 每 accept 一条就 `makeConnection` 一次：方法面 / 订阅 / 翻页器 / 配对端点都是
         * **每连接**的，两条共用一份会串台（第二台手机连上了但收不到事件）。
         */
        if (listenPort !== 0) {
          listener = await startListener({
            port: listenPort,
            host: listenHost,
            log: logger,
            accept: () => {
              const accepted = makeConnection(() => {
                // 接受来的连接没有拨号目标：`attach()` 用 `heals: false` 收口，
                // 所以这个拨号器**不该被调到**。真被调到说明装配错了 —— 抛，不静默拨号。
                throw new Error('接受来的连接没有拨号目标：不该走到 dial')
              })
              return {
                port: accepted,
                attach: (socket) => accepted.attach(socket as DialSocket),
                stop: () => accepted.stop(),
              }
            },
          })
        }

        abort.signal.addEventListener('abort', () => {
          void listener?.close().catch((error: unknown) => {
            logger.warn('关闭直连监听面时出错（已接受的连接可能没全收干净）', error)
          })
          listener = null
          connection?.stop()
          connection = null
        })
      },
      undo() {
        // 先停监听面：不再接受新连接，再收已接受的（它们的连接由监听面自己 stop）。
        // 收口失败只留声：卸载是尽力而为（`lifecycle.ts`），这里抛会盖住后面的步骤。
        void listener?.close().catch((error: unknown) => {
          logger.warn('关闭直连监听面时出错（已接受的连接可能没全收干净）', error)
        })
        listener = null
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
  const listenPort = config.listenPort.get()
  const listenHost = config.listenHost.get()

  ctx.effect(() => {
    const abort = new AbortController()
    let mounted: Awaited<ReturnType<typeof mount>> | null = null

    const started = mount(
      buildSteps({
        ctx,
        relayUrl,
        relayTokenSecretRef,
        listenPort,
        listenHost,
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
