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
import { createEndpointsPort } from './endpoints.js'
import { createSubagentsPort } from './dsh/subagents.js'
import type { SubagentRuntime } from '@deepseek-ai/dsh-subagent'
import { createProjectionsPort } from './dsh/projections.js'
import { createSettingsPort } from './dsh/settings.js'
import { createSettingsFace } from './dsh/settings-face.js'
import type { SettingsForms } from '@deepseek-ai/dsh-settings'
import { registerTrajectoryProjection } from './dsh/trajectory.js'
import { deriveIdentity } from './protocol/crypto.js'
import { loadOrCreateIdentity, type Identity } from './dsh/identity.js'
import { PAIRING_TTL_MS, createPairing } from './pairing.js'
import { createPairingEndpoint, findPreviousPairingRow, type PairingEndpoint, type PairedDeviceRow } from './pairing-endpoint.js'
import type { DeviceBinding } from '../../protocol/relay-control.mjs'
import { createRelayLink, type RelayLink } from './transport/relay-link.js'
import { relayUrlOf } from './transport/relay-url.js'
import {
  createTransportChannels,
  describeChannels,
  DIRECT_UNCONFIGURED,
  type ChannelState,
  type TransportChannels,
} from './transport/channels.js'
import { relayHintFor } from './pairing.js'
import { defaultRouteIPv4 } from './lan-address.js'
import { readRelayToken } from './dsh/relay-token.js'
import { createPairingRegistrar } from './pairing-register.js'
import { createDevicePublisher } from './device-publish.js'
import { offerForScanning, issuePairingOffer } from './pairing-offer.js'
import { pairingQrSvg } from './pairing-qr.js'
import { mountAdminFace } from './admin/mount.js'
import { createDeviceAdmin, type DeviceTablePort } from './admin/device-admin.js'
import {
  advertiseMapOf,
  createAdvertiseAdmin,
  type AdvertiseTablePort,
} from './admin/advertise.js'
import { registerInteractions, type RemoteInteractionPort } from './dsh/interactions.js'
import { createQuestionFaceDeps } from './dsh/questions.js'
import { createModelFace } from './dsh/models.js'
import { createPermissionFace } from './dsh/permissions.js'
import { createAgentPresetsFace } from './dsh/agent-presets.js'
import { createDevicePresence } from './presence.js'
import { createInteractionPort } from './interaction-claims.js'
import { createInteractionFace } from './interaction-face.js'
import type { TakeoverDevice, TakeoverMode } from './protocol/takeover.js'
import { createDeviceConnection } from './device-connection.js'
import type { HandlerDeps } from './handlers.js'
import { createIdempotency, type DedupeRows } from './idempotency.js'
import type { ConnectionScopeDeps } from './connection-scope.js'
import { mount, type LifecycleStep } from './lifecycle.js'
import { METRIC, createChannelLogger, createMetrics, type ChannelLogger, type ChannelMetrics } from './observability.js'
import { createAliases, type Aliases } from './alias.js'
import type { JobRegistry } from '@deepseek-ai/dsh-jobs'
import { createJobsPort, createJobControlPort, type JobControlService } from './dsh/jobs.js'
import { createSessionBuffer } from './session-buffer.js'
import { createSessionsAdapter } from './dsh/sessions.js'
import { createWorkspacesPort } from './dsh/workspaces.js'
import type { WorkspaceController } from '@deepseek-ai/dsh-api-workspace-controller'
import { coreDomain, initialMeta, migrateMeta, windowsDomain } from './store/index.js'
import type { Connection, DialSocket } from './transport/connection.js'
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

/**
 * 设备行的展示排序：**此刻对操作者的意义从高到低**。
 *
 * 1. 在线的（用户正在用的那台）—— 永远在最上面；
 * 2. 前台优先于后台；
 * 3. 最近交互过的；
 * 4. 最近配对的（并列时用它打破平手，让列表稳定）。
 *
 * 为什么排这一步：真机联调会攒下几十行"配对过、连过一次、再没连过"的设备
 * （2026-10-15 攒到 31 行）。不排的话用户那台埋在中间，而上面全是测试残留。
 */
function compareDevicesForDisplay(
  a: { online: boolean; foreground: boolean; lastInteractedAt?: number; pairedAt: number },
  b: { online: boolean; foreground: boolean; lastInteractedAt?: number; pairedAt: number },
): number {
  if (a.online !== b.online) return a.online ? -1 : 1
  if (a.foreground !== b.foreground) return a.foreground ? -1 : 1
  const aSeen = a.lastInteractedAt ?? 0
  const bSeen = b.lastInteractedAt ?? 0
  if (aSeen !== bSeen) return bSeen - aSeen
  return b.pairedAt - a.pairedAt
}

/** 发布给宿主的服务面。手机端的能力门控读 `caps()`。 */
export interface ConnectorService {
  caps(): Caps
  metrics(): Readonly<Record<string, number>>
  /**
   * 传输面按"方式"分的通道列表（中转拨号 / 直连监听）。
   *
   * 2026-10-17 用户要求「两个方式两个开关」：原来一把 `startTransport` 同时
   * 起停两条，加第三种方式时 UI 与管理面都要改形状；现在是**注册表**，
   * 加一种方式只是加一个端口。见 `transport/channels.ts`。
   */
  channels(): readonly ChannelState[]
  /** 起（`running: true`）或停（`running: false`）一条传输通道。 */
  setChannel(id: string, running: boolean): Promise<void>
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
  allowInsecureLocal: boolean
  relayTokenSecretRef: string | undefined
  /** 直连监听面（§1.7）：`0` = 不监听。同样是挂载时取一次快照。 */
  listenPort: number
  listenHost: string
  /** 接管档位（契约 §6.2）。同样是挂载时取一次快照。 */
  approvalTakeover: TakeoverMode
}

function buildSteps(assembly: Assembly): LifecycleStep[] {
  const { ctx, relayUrl, allowInsecureLocal, relayTokenSecretRef, listenPort, listenHost, approvalTakeover, logger, metrics, abort } =
    assembly

  let closeStore: (() => Promise<void>) | null = null
  let connection: RelayLink | null = null
  let pairingEndpoint: PairingEndpoint | null = null
  /** 直连监听面（§1.7）。只有配了 `listenPort` 才非空。 */
  let listener: Listener | null = null
  /**
   * 传输面的**通道注册表**（2026-10-17 用户要求：两个方式两个开关）。
   * **占位器**：`start-transport` 步在 `run()` 里才把它换成真的（那时
   * `makeConnection` 等局部物才存在）。
   *
   * 存在的理由是「启停开关」：插件面板上按方式各一个开关，再加一种方式
   * （Tailscale / 服务器中转）只是加一个端口，UI 与管理面形状不变。
   * **停传不清凭据、不动身份** —— 重新起时配对过的手机一条都不用重扫，
   * 这是"开关"与"卸载"的区别。
   */
  let transportChannels: TransportChannels | null = null
  /** 挂载与卸载用：两条通道一起起 / 一起收（用户的常态是同时开同时关）。 */
  let transportStart: (() => Promise<void>) | null = null
  let transportStop: (() => Promise<void>) | null = null
  /**
   * 本机的局域网地址（默认路由网卡的 IPv4，内核选路得来）。
   *
   * 二维码里的中转地址与 `endpoint.describe` 的 direct 排序都用它 ——
   * **不枚举网卡、不认虚拟网卡名**（2026-10-17 用户点醒：只需要知道局域网）。
   * 换 WiFi 后会变，所以出码前刷新（`refreshLanHint`），拿不到就是 `null`
   * （调用方退回配置里的地址，不猜）。
   */
  let lanHint: string | null = null
  const refreshLanHint = async (): Promise<void> => {
    lanHint = await defaultRouteIPv4()
  }
  /**
   * 这条连接的**已认证设备**由 `connection-scope.ts` 记着（增量缓冲的水位按设备记，
   * 契约 §5.5）—— 它是每连接的状态，所以不放在这里。
   */
  let unregisterInteractions: (() => void) | null = null
/** 出码命令的注销（ctx.commands.register 返回的就是它）。 */
let unregisterPairingCommand: (() => void) | null = null
/** 管理面 RPC（`/api/dsh-mobile/*`）的注销。**不用 ctx.effect**，理由见 `admin/mount.ts`。 */
let unregisterAdminFace: (() => void) | null = null

  /** 设备状态与档位。真值在 store 里，这里给出 transport 需要的读取面。 */
  /**
   * 挂载期才可用的东西。`open-store` 之前都是 null —— 所以 `takeover` 里的读取
   * 一律走可选链，而不是假设它们已就绪。
   */
  let aliases: Aliases | null = null
  /**
   * `core` 域的 `devices` 表。
   *
   * 形状（含运行时才有、类型没跟上的 `delete`）见 `admin/device-admin.ts` 的
   * `DeviceTablePort`；设备管理面的三个写操作全在那里，本文件只把表与在线集接上。
   */
  let devicesTable: DeviceTablePort | null = null
  /** 幂等表（`core` 域的 `dedupe` 表）。写在库里的行要参与 §5.6 的"命中即回上次结果"。 */
  let dedupeRows: DedupeRows | null = null
  /** 上报地址的显式表态（`core` 域的 `advertise` 表）。 */
  let advertiseRows: AdvertiseTablePort | null = null
  /** 本机身份（§4.1）。在 `load-identity` 之前是 null，`start-transport` 之前必然已就绪。 */
  let identity: Identity | null = null
  /** 本机标识：进 `hello-ack` 的 `pcId`，因而参与 transcript。 */
  let connectorId = ''

  /**
   * 已认证设备的**瞬时**状态（在线、前台、已订阅、最近交互）—— 契约 §6.2 仲裁判定的输入。
   *
   * 真值在 `presence.ts`，由连接层在四个时机写进来：鉴权完成 / 断开 / 订阅变化 /
   * 收到 `sync.hello`。在它接线之前，完整因果链是
   * 「没人写 liveRegistry → `liveDevices()` 恒空 → `decideTakeover` 永不 claim →
   * answerer 永远 `next()` 交还桌面 → 端口根本跑不到」—— 所以这一步是整条链的地基。
   *
   * 持久部分（身份、配对时间、吊销标记）在 `devices` 表里；这一份进程重启即清零，
   * 重连后由连接层重新上报。
   */
  const presence = createDevicePresence({
    // **连接层认证过不等于授权过**：没配过对、或已吊销的设备一律不参与仲裁。
    // 这条过滤只在 `presence.ts` 的 `devices()` 里做一次。
    pairedAtOf: (devId) => {
      const record = devicesTable?.get(devId)
      return record === undefined || record.revokedAt !== undefined ? undefined : record.pairedAt
    },
  })

  const liveDevices = (): readonly TakeoverDevice[] => presence.devices()

  const takeover = {
    mode: (): TakeoverMode => approvalTakeover,
    devices: liveDevices,
    sidOf: (dshSessionId: string): string | undefined => aliases?.sidOf(dshSessionId),
  }

  /**
   * 交互端口（契约 §6.2）：把审批 / 提问送到仲裁选出的那条连接，并看护到人类回答
   * 或 fail-closed。
   *
   * 待处理项**不在这里推送** —— 它乘会话事件流（`approval/asked` 与 `ask_user_question`
   * 的 `tool/call` 本来就是 DSH 的会话事件，见 `interaction-claims.ts` 的文件头）。
   * 本端口只负责"选中哪条连接、看护多久、答复怎么回来"。
   *
   * 未处理记录目前只有**日志与指标**两条出口：契约 §6.2 说的"推一条通知"需要一种
   * 电脑→手机的推送帧，而本期没有（`pending.changed` 在 §5.7 的事件表里、却不是帧类型）。
   * 如实记成指标 + warn，不假装通知已送达。
   */
  const interactionPort = createInteractionPort({
    presence,
    onUnhandled: (record) => {
      metrics.increment(METRIC.failClosed)
      logger.warn('交互在手机上未被处理，已按 fail-closed 收束', record)
    },
  })
  metrics.gauge(METRIC.pendingInteractions, interactionPort.pending)

  /**
   * 服务面与管理面**共用**的通道操作（带日志）。
   *
   * 注册表还没就绪时是 no-op：管理面在 `start-transport` 步里才挂，能调到
   * 这个方法时注册表必然已存在（与旧的 `transportStart?.()` 占位同一个口径）。
   */
  const setTransportChannel = async (id: string, running: boolean): Promise<void> => {
    const registry = transportChannels
    if (registry === null) return
    await registry.setChannel(id, running)
    logger.info(
      `传输通道${running ? '启动' : '停止'}：${id}（${describeChannels(registry.channels())}）`,
    )
  }

  const port: RemoteInteractionPort = {
    askApproval: (prompt, deviceId, signal) =>
      interactionPort.askApproval(prompt, deviceId, signal),
    askQuestion: (prompt, deviceId, signal) =>
      interactionPort.askQuestion(prompt, deviceId, signal),
  }

  return [
    {
      name: 'validate-config',
      run() {
        if (relayUrl === undefined || relayUrl === '') {
          throw new Error('relayUrl 未配置：拒绝挂载，而不是连上一个不完整的中转')
        }
        relayUrlOf(relayUrl, allowInsecureLocal)
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
        // 上报地址的显式表态（藏掉虚拟网卡 / 追加 Tailscale 之类的地址）。
        // 每次 `endpoint.describe` 现取 —— 管理面改完立刻生效，不用重启。
        advertiseRows = core.table('advertise')
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
          // `direct` 能力位看**监听面起没起来**，不是看配置里写没写：
          // 端口被占时 `startListener` 会抛，那时这一项必须是 false，
          // 否则手机上会多一个必然拨不通的"同一网络"。
          caps: () => readCaps(ctx, { direct: listener !== null }),
          metrics: () => metrics.snapshot(),
          // 启停开关：`start-transport` 步跑完前注册表还是 null（那时也没有
          // 管理面能调这两个方法 —— 管理面就在那一步里挂），如实回空列表。
          channels: () => transportChannels?.channels() ?? [],
          setChannel: async (id, running) => {
            await setTransportChannel(id, running)
          },
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
          pcId: connectorId,
          // 二维码里的地址：**中转地址**（契约 §2 的拓扑里手机连的是中转）。
          // **出码时求值**（`relayHintFor` + 默认路由局域网地址）：电脑换 WiFi 后
          // 二维码带的是当前地址 —— 用户不用回去改 yml 再重启 DSH
          // （2026-10-17 真机踩到：配置里写着已不属于本机的 192.168.2.43，
          //  手机拨存量端点全超时，而二维码再出码也还是那个死地址）。
          relayUrl: () => relayHintFor(relayUrl ?? '', lanHint),
          pcPubEd: pcIdentity.sign.publicKeyHex,
          pcPubDh: pcIdentity.dh.publicKeyHex,
        })
        /**
         * 名册上报的**网络调用**（§8.2 / I7）。
         *
         * 与出码登记共用同一个 `httpBaseOf` 派生与同一个令牌读取面 ——
         * 两者打的是同一台中转的 HTTP 面，各自写一份派生迟早会不一致。
         */
        const publisher = createDevicePublisher({
          allowInsecureLocal,
          relayUrl: relayUrl ?? '',
          tokenSource: () => readRelayToken(ctx.credentials, relayTokenSecretRef ?? ''),
          log: logger,
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
            // 摘要随行存住：它是"中转重启后这台设备还能回来"的唯一依据（I7）。
            ...(row.tokenHash === undefined ? {} : { tokenHash: row.tokenHash }),
          })
        }

        /**
         * 名册上报（§8.2 / I7）：把**整份**设备摘要交给中转，让它重建归属与凭据面。
         *
         * 两处调用：配对成功时（回执之前）与每次连上中转时（`publish-service` 之后的
         * `onEstablished`）。前者让手机拿到的令牌立刻能用，后者让中转重启后设备能自己回来。
         *
         * **没有令牌摘要的行不进名册**：它认不下任何设备，报上去只是噪音 ——
         * 而"漏报"与"报一条没用的"在中转侧是同一件事（那台设备换不到票）。
         */
        const publishDevices = async (): Promise<void> => {
          const table = devicesTable
          if (table === null) {
            throw new Error('devices 表尚未就绪：装配顺序有误')
          }
          const rows = [...table.keys()].flatMap((id) => {
            const record = table.get(id)
            if (record === undefined || record.revokedAt !== undefined) return []
            if (record.tokenHash === undefined) return []
            return [
              {
                id,
                pairingId: record.pairingId,
                devPubEd: record.edPub,
                devPubDh: record.dhPub,
                name: record.name,
                tokenHash: record.tokenHash,
              },
            ]
          })
          await publisher(rows)
        }

        // 出码的**登记面**（`offerId` → 中转）。斜杠命令与管理页面共用同一个实例 ——
        // 两处各建一个的话，"令牌换了哪边先生效"会有两个答案。
        const registerPairing = createPairingRegistrar({
          allowInsecureLocal,
          relayUrl: relayUrl ?? '',
          // 令牌**现读**（`readRelayToken` 不缓存）：出码是人工动作，换令牌后立刻生效；
          // 也省得为这个只在出码时用到的值安排装配顺序。
          tokenSource: () => readRelayToken(ctx.credentials, relayTokenSecretRef ?? ''),
          log: logger,
        })
        /**
         * 出码：登记 → 生成二维码 SVG。
         *
         * **斜杠命令与管理面板共用同一个出码核心**（`issuePairingOffer`）——
         * "登记不成就不出码"这条规则只有一份。命令那一侧只能回文本
         * （DSH 的 `CommandResult` 没有图片出口，已核实
         * `packages/interaction/commands/src/types.ts:34`），所以二维码
         * 由插件面板承载；斜杠命令仍留着，方便在终端里直接出码。
         */
        const offerPairing = async (): Promise<{
          svg: string
          expiresAt: number
        }> => {
          // **出码前刷新局域网地址**：二维码里的中转地址必须是"手机拨得通的
          // 当前地址"（配置里写的是环回拨号地址）。换 WiFi 之后第一次出码
          // 就要带上新地址，否则用户扫了一个拨不通的码。
          await refreshLanHint()
          // 结构化拿 offer，**不从命令文本里解析** —— 那等于解析自己刚拼的字符串。
          const offer = await issuePairingOffer({
            pairing: pairingCore,
            register: registerPairing,
            log: logger,
          })
          // **payload 不返回**：它含两把公钥，而浏览器只负责画图。
          // 公钥只在服务端生成 SVG 时用一次（`admin/routes.ts` 的 `offer` 注释）。
          const svg = await pairingQrSvg(offer.payload)
          return { svg, expiresAt: offer.expiresAt }
        }

        // 出码入口：一条斜杠命令。**登记不成就不出码**（`offerForScanning` 的判断），
        // 否则操作者会拿到一张扫了也配不上的二维码，而失败面出现在手机侧。
        const commands = ctx.get('commands') as
          | { register(definition: unknown): () => void }
          | undefined
        if (commands === undefined) {
          // `commands` 不在服务清单里时插件仍能工作（配对靠管理页面触发），所以只留声。
          logger.warn('commands 服务不在：`dsh-mobile-pair` 出码命令不可用（管理页面仍可出码）')
        } else {
          unregisterPairingCommand = commands.register({
            name: 'dsh-mobile-pair',
            description: `生成手机配对二维码（一次性、${Math.round(PAIRING_TTL_MS / 60_000)} 分钟有效）`,
            handler: () => offerForScanning({ pairing: pairingCore, register: registerPairing, log: logger }),
          })
        }

        // 插件面板的四个 RPC（`/api/dsh-mobile/{status,pair,devices/enabled,devices/remove}`）。
        // UI 在 DSH 界面里（浏览器半侧 `client.js` 注册 `plugins.bundle.config` slot），
        // 不另起网页路由 —— 理由与生命周期见 `admin/mount.ts` 的文件头。
        //
        // **设备行按"此刻对操作者的意义"排**：在线的 > 最近交互的 > 最近配对的。
        // 排序放在服务端：客户端只管渲染，而"怎么算更有意义"是电脑侧该定的。
        // （真机联调会攒下几十行"配对过、连过一次、再没连过"的行 ——
        //  2026-10-15 攒到 31 行，操作者要在最上面看到自己那台。）
        //
        // **三个写操作全在 `device-admin.ts`**：停用/启用、多选删、按状态删。
        // 抽出去是为了让"解禁要把 `revokedAt` 从行上拿掉""在线豁免按形状生效"这两条
        // 不变量有单测可钉（2026-10-15 事故后最不能错的两条）。
        const deviceAdmin = createDeviceAdmin({
          tableOf: () => devicesTable,
          onlineIds: () => new Set(presence.devices().filter((row) => row.online).map((row) => row.id)),
          publish: publishDevices,
        })
        // 「上报哪些地址」的管理面。候选表是**网卡枚举的原始结果**（含被藏掉的），
        // 因为界面要画的是"这台机器上都有哪些地址，各自报不报"。
        const advertiseAdmin = createAdvertiseAdmin({
          tableOf: () => advertiseRows,
          candidatesOf: () => listener?.urls ?? [],
        })
        // 插件面板的 RPC（`/api/dsh-mobile/*`）在**传输section 之后**才挂 ——
        // 按通道生成的起停路由要在 `transportChannels` 注册表存在之后才能生成
        // （2026-10-17 真机抓到的装配顺序 bug：挂早了 channels() 还是空，
        //  4 个 POST 路由根本不注册，而 GET /transport 是基础路由、看起来正常）。
        // UI 在 DSH 界面里（浏览器半侧 `client.js` 注册 slot），不另起网页路由 ——
        // 理由与生命周期见 `admin/mount.ts` 的文件头。
        //
        // **设备行按"此刻对操作者的意义"排**：在线的 > 最近交互的 > 最近配对的。
        // 排序放在服务端：客户端只管渲染，而"怎么算更有意义"是电脑侧该定的。
        // （真机联调会攒下几十行"配对过、连过一次、再没连过"的行 ——
        //  2026-10-15 攒到 31 行，操作者要在最上面看到自己那台。）
        //
        // **三个写操作全在 `device-admin.ts`**：停用/启用、多选删、按状态删。
        // 抽出去是为了让"解禁要把 `revokedAt` 从行上拿掉""在线豁免按形状生效"这两条
        // 不变量有单测可钉（2026-10-15 事故后最不能错的两条）。
        /**
         * 方法面的挂载级依赖。**每连接的那三个端口不在这里** ——
         * `createHandlers` 的 deps 类型上已经不收它们（见 `ConnectionScopeDeps.handlers`）。
         */
        const handlerDeps: ConnectionScopeDeps['handlers'] = {
          caps: () => readCaps(ctx, { direct: listener !== null }),
          aliasVersion: () => aliases?.version ?? 0,
          sessions,
          // 端点自报：**没有监听面就不给**（`endpoint.describe` 于是不出现）。
          // 它现取 `listener`：监听面在后面的 `start-transport` 步才起，
          // 而这个 deps 对象在挂载时就构造好了。
          ...(listenPort === 0
            ? {}
            : {
                endpoints: createEndpointsPort({
                  relayUrl,
                  lanHintOf: () => lanHint,
                  listenerOf: () => listener,
                  // 用户藏掉 / 追加的上报地址（现取：管理面改完立刻生效）。
                  advertiseOf: () => advertiseMapOf(advertiseRows),
                }),
              }),          // 会话投影：**按能力位挂**（`sessionProjections` 服务在不在）。
          ...(ctx.get('sessionProjections') === undefined
            ? {}
            : { projections: createProjectionsPort(ctx.sessionController) }),
          // 任务服务是**可选**的（`caps.ts` 的 OPTIONAL_SERVICES）：缺了就不挂 `job.*`，
          // 手机侧看到的是"这个方法不存在"，而不是一个会回错的按钮。
          ...(ctx.get('jobs') === undefined
            ? {}
            : { jobs: createJobsPort(ctx.get('jobs') as JobRegistry) }),
          // 工作区面（会话列表按它分组）：同样是可选服务。缺了就不挂
          // `workspace.list`，手机的列表退回**不分组**—— 那是如实的降级，
          // 而不是按 `cwd` 猜一个分组（`cwd` 与工作区不是一对一，
          // 猜的那份会漂）。
          ...(ctx.get('workspaceController') === undefined
            ? {}
            : {
                workspaces: createWorkspacesPort(
                  ctx.get('workspaceController') as WorkspaceController,
                ),
              }),
          ...(jobControl === null ? {} : { jobControl }),
          // 子代理面：**写的一面**（给可继续子会话投递人写的消息）。
          // 子会话不能用 `session.prompt`：宿主回
          // `internal: session "…" is owned by subagent routing`（真机实测）。
          ...(ctx.get('subagents') === undefined
            ? {}
            : {
                subagents: createSubagentsPort(
                  ctx.get('subagents') as SubagentRuntime,
                ),
              }),
          // 设置面（`settings.describe` / `settings.update`）：只有 `settings` 服务在时才挂。
          // 读已脱敏、写只发新值 —— 三条安全规则在 `dsh/settings.ts` 里，范围在
          // `dsh/settings-face.ts` 的两张 allowlist 里。
          ...(ctx.get('settings') === undefined
            ? {}
            : {
                settings: createSettingsFace(
                  createSettingsPort({
                    settings: ctx.get('settings') as SettingsForms,
                    credentials: ctx.credentials,
                  }),
                ),
              }),
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
         * 提问 / 计划审查的内核（契约 §6.3）。
         *
         * **只在 `userQuestions` 服务在的时候挂**：缺了它，`interaction.respond` 就不该出现
         * 在 `repo.info` 的 `methods` 里（手机据此置灰按钮，而不是点下去永远转圈）。
         *
         * `settleClaim` 接的是端口的在途表：一次 `open` 提问被应答链堵着时，
         * 答复从这条路回到那个 `await`，而不是走 DSH 的 `answer()`（那个只认 `continued`）。
         */
        const questionFace =
          ctx.get('userQuestions') === undefined
            ? null
            : createInteractionFace({
                ...createQuestionFaceDeps(ctx, {
                  sessionOf: (sid) => aliases?.sessionOf(sid),
                }),
                settleClaim: (sid, callId, answers) =>
                  interactionPort.settleClaim(sid, callId, answers),
              })
        if (questionFace !== null) {
          handlerDeps.interaction = questionFace
        }

        /**
         * 模型目录与每会话当前模型。
         *
         * 判据用 `ctx.get('sessionController')` 而不是某个业务服务：目录是它发的
         * （`@Remote('modelCatalog')`），每会话当前模型走 `modelSelection` 投影，
         * 而投影要经 `agents` 才够得着 live `Session`。三个键任一缺席就整块不挂 ——
         * `repo.info` 的 `methods` 里也就没有 `session.modelCatalog`，
         * `session.list` 的行里没有 `model` 字段（契约 §7 的能力位模型）。
         */
        const modelsFace =
          ctx.get('sessionController') === undefined ||
          ctx.get('sessionProjections') === undefined ||
          ctx.get('agents') === undefined
            ? null
            : createModelFace(ctx, { sessionOf: (sid) => aliases?.sessionOf(sid) })
        if (modelsFace !== null) {
          handlerDeps.models = modelsFace
        }

        /**
         * 权限预设：目录（`permissionPresets.catalog()`）+ 写路径（`/permission <档位>`）。
         *
         * 判据是**三个服务键同时在场**：`permissionPresets` 发目录，
         * `commands` 跑那条斜杠命令，`agents` 把会话 id 换成它要的 live root agent。
         * 任一个缺席就整块不挂 —— `repo.info` 的 `methods` 里也就没有
         * `permission.catalog` / `permission.switch`，手机侧照 DSH 的规则
         * **隐藏控件**（`permission-presets/src/types.ts:58-59`：键缺席即无此能力），
         * 而不是摆一个点下去必然失败的按钮。三个键都在 `bundle/base` 里
         * （`cordis.patch.yml:260` 注册 `@deepseek-ai/dsh-permission-presets`），
         * 所以真实部署下这是一整块能力，不会出现"能读不能写"的半挂状态。
         */
        const permissionFace =
          ctx.get('permissionPresets') === undefined ||
          ctx.get('commands') === undefined ||
          ctx.get('agents') === undefined
            ? null
            : createPermissionFace(ctx, { sessionOf: (sid) => aliases?.sessionOf(sid) })
        if (permissionFace !== null) {
          handlerDeps.permissions = permissionFace
        }

        /**
         * Agent 预设目录（只读）。判据是**一个服务键**：`agentPresets` 就是发名单的那个
         * （`@Remote('list')`，`@deepseek-ai/dsh-agent-preset-registry`）。
         * 缺席就整块不挂 —— `repo.info` 的 `methods` 里也就没有 `agentPresets.list`，
         * 手机 hero 上那枚模式 chip 说"拿不到目录"，而不是摆一份手抄的四个内置预设。
         *
         * **写路径不在这里**：选预设走已经存在的 `session.create({agentPreset})`，
         * 所以这一块只有一个读方法（理由见 `dsh/agent-presets.ts` 的文件头）。
         */
        if (ctx.get('agentPresets') !== undefined) {
          handlerDeps.agentPresets = createAgentPresetsFace(ctx)
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
          idempotency,
          // presence 上报面（挂载级的那一份）。方法面拿到的 `connection.deviceId()`
          // 由 `createConnectionScope` 自己构造，所以这里只需要 sink 本身。
          presence,
        }

        // 连接器令牌（§12.2）：**拨号与出码登记共用同一个值**，所以在这一步开头读一次。
        // 读不到就**大声失败**（`readRelayToken` 的契约）：起来一个连不上中转的插件没有意义。
        const enrollment = createPairingEndpoint({
          pairing: pairingCore, pcId: connectorId, putDevice, announce: publishDevices, log: logger,
          // 重新配对的替换钩子：手机自报的 `previousPairingId` 只是**行定位符**
          // （授权已由一次性二维码秘密完成），据此找到这台手机上一次的行。
          // `findPreviousPairingRow` 是纯函数（`pairing-endpoint.ts`），**不按
          // `revokedAt` 过滤** —— 重新扫码本身就是恢复路径，新行天然不带吊销标记。
          // 取舍与威胁模型：`.agents/notes/implemented/2026-10-17-repair-replaces-device-row.md`。
          findPreviousPairing: (pairingId) => {
            const table = devicesTable
            if (table === null) return null
            return findPreviousPairingRow(
              [...table.keys()].flatMap((id) => {
                const record = table.get(id)
                return record === undefined ? [] : [[id, record] as const]
              }),
              pairingId,
            )
          },
          removeDevice: async (devId) => {
            if (devicesTable === null) {
              throw new Error('devices 表尚未就绪：装配顺序有误')
            }
            await devicesTable.delete(devId)
          },
        })
        pairingEndpoint = enrollment
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
        const makeConnection = (binding?: DeviceBinding): Connection => createDeviceConnection({
          identity: pcIdentity, pcId: connectorId, pairing: pairingCore, enrollment, scope: scopeDeps,
          ...(binding === undefined ? {} : { binding }),
          peerOf: (devId) => {
            const record = devicesTable?.get(devId)
            return record === undefined || record.revokedAt !== undefined ? undefined : {
              edPubHex: record.edPub, dhPubHex: record.dhPub, pairingId: record.pairingId,
            }
          },
        })

        /**
         * 传输面的起 / 停。**在这里定义**（`makeConnection` / `pairingCore` /
         * `publishDevices` 都是本步的局部物），装进外层占位器给服务面与管理面用。
         *
         * 停 ≠ 卸载：只收传输，**不清凭据、不动身份、不摘管理面** ——
         * 重新起时配对过的手机一条都不用重扫。
         * 已 accepted 的连接由监听面自己收干净。
         *
         * **按通道分**（2026-10-17 用户：「不是有两中方式为啥就一个开关」）：
         * 每条通道各自起停，停一条不碰另一条。批量入口（同时开 / 同时关）
         * 由 UI 顺序调用，服务端不为它单开端点 —— 两个通道各自的成败要能
         * 分别报出来，批量端点只会把其中一个的失败藏掉。
         */

        /** 通道一：中转拨号。**自愈** —— 断开后退避重连 `relayUrl`。 */
        const startRelayChannel = async (): Promise<void> => {
          if (connection !== null) return
          /**
           * Node 22+ 自带全局 WebSocket；不引第三方客户端。
           *
           * **连接器令牌走升级头的 `Authorization`**（§2.2）：实测 Node 的全局 `WebSocket`
           * 支持第二参数传 options 对象（undici 的非标准扩展，见笔记），所以这里能带头 ——
           * 三参数形式与裸调用都收不到（服务端只会看到 `(none)`）。
           * 令牌在装配时读一次（`readRelayToken` 不缓存，但**每次拨号都由同一个连接对象发起**，
           * 于是运行期换令牌需要重连 —— 这是可接受的：换令牌本来就意味着换一次连接）。
           */
          connection = createRelayLink({
            url: relayUrl ?? '', token: relayToken, allowInsecureLocal, log: logger,
            onConnected: publishDevices,
            allows: (binding) => {
              if (binding.purpose === 'pairing') return pairingCore.allows(binding.candidate)
              const record = devicesTable?.get(binding.deviceId)
              return record !== undefined && record.revokedAt === undefined
            },
            createData: makeConnection,
          })
          connection.start()
        }
        const stopRelayChannel = async (): Promise<void> => {
          connection?.stop()
          connection = null
        }

        /**
         * 通道二：直连监听面（§1.7）。**只有配置里 `listenPort` 非 0才起**，
         * 否则**报错**而不是静默成功 —— 静默的话界面显示"已启动"而手机上
         * 什么都不会多出来（`caps.direct` 仍为 false）。
         *
         * 每 accept 一条就 `makeConnection` 一次：方法面 / 订阅 / 翻页器 / 配对端点都是
         * **每连接**的，两条共用一份会串台（第二台手机连上了但收不到事件）。
         *
         * 停它 = `listener.close()`：先停所有已接受的连接再关服务端
         * （`tests/listener.test.ts` 的"卸载时收口"覆盖），**不碰**中转上的连接。
         */
        const startDirectChannel = async (): Promise<void> => {
          if (listener !== null) return
          if (listenPort === 0) throw new Error(DIRECT_UNCONFIGURED)
          // **先解析局域网地址再起监听面**：第一次 `endpoint.describe`（手机连上后
          // 立刻会调）要用它给 direct 排序、给中转条目算手机可达地址。
          await refreshLanHint()
          listener = await startListener({
            port: listenPort,
            host: listenHost,
            log: logger,
            accept: () => {
              const accepted = makeConnection()
              return {
                port: accepted,
                attach: (socket) => accepted.attach(socket as DialSocket),
                stop: () => accepted.stop(),
              }
            },
          })
        }
        const stopDirectChannel = async (): Promise<void> => {
          if (listener !== null) {
            await listener.close().catch((error: unknown) => {
              logger.warn('关闭直连监听面时出错（已接受的连接可能没全收干净）', error)
            })
            listener = null
          }
        }

        transportStart = async () => {
          await startRelayChannel()
          await startDirectChannel()
        }
        transportStop = async () => {
          // 先停监听面：不再接受新连接，再收已接受的（它们的连接由监听面自己 stop）。
          // 收口失败只留声：卸载是尽力而为（`lifecycle.ts`），这里抛会盖住后面的步骤。
          await stopDirectChannel()
          await stopRelayChannel()
        }

        /**
         * 通道注册表。**加一种方式就是往这个数组加一项** —— 管理面路由
         * （`routes.ts` 按 `channels()` 生成 `/transport/{id}/{start,stop}`）与
         * UI（`client.js` 按 `GET /transport` 渲染开关）自动跟上。
         */
        transportChannels = createTransportChannels([
          {
            id: 'relay',
            label: '中转拨号',
            running: () => connection !== null,
            start: startRelayChannel,
            stop: stopRelayChannel,
            detail: () => relayUrl ?? '未配置中转',
          },
          {
            id: 'direct',
            label: '直连监听',
            running: () => listener !== null,
            start: startDirectChannel,
            stop: stopDirectChannel,
            detail: () =>
              listenPort === 0 ? DIRECT_UNCONFIGURED : `${listenHost}:${listener?.port ?? listenPort}`,
          },
        ])

        await transportStart()

        // 插件面板的 RPC（`/api/dsh-mobile/{status,pair,transport,devices/*}`）。
        // **必须在 `transportChannels` 创建之后**：按通道生成的起停路由
        // （`POST /transport/{id}/{start,stop}`）在挂载时一次性生成，挂早了
        // `channels()` 还是空数组 —— 2026-10-17 真机实测到这个顺序 bug
        // （4 个 POST 路由 404，而 GET /transport 是基础路由、看起来一切正常）。
        // 停传输时管理面照常工作（出码、设备管理都不依赖它）。
        unregisterAdminFace =
          mountAdminFace(ctx, {
            caps: () => readCaps(ctx, { direct: listener !== null }),
            metrics: () => metrics.snapshot(),
            relayUrl: () => relayUrl ?? null,
            // 启停开关：**按通道**（两个方式两个开关，2026-10-17 用户要求）。
            channels: () => transportChannels?.channels() ?? [],
            advertise: advertiseAdmin,
            setChannel: (id, running) => setTransportChannel(id, running),
            devices: () => {
              if (devicesTable === null) return []
              const live = presence.devices()
              const liveOf = new Map(live.map((row) => [row.id, row]))
              return [...devicesTable.keys()].flatMap((id) => {
                const record = devicesTable?.get(id)
                if (record === undefined) return []
                const present = liveOf.get(id)
                const lastInteractedAt = present?.lastInteractedAt
                return [
                  {
                    id,
                    name: record.name,
                    pairedAt: record.pairedAt,
                    revoked: record.revokedAt !== undefined,
                    online: present?.online ?? false,
                    foreground: present?.foreground ?? false,
                    ...(lastInteractedAt === undefined
                      ? {}
                      : { lastInteractedAt: Math.max(0, ...Object.values(lastInteractedAt)) }),
                  },
                ]
              }).sort(compareDevicesForDisplay)
            },
            offer: offerPairing,
            // 停用/启用：一对布尔（照 DSH `setBundleEnabled` 的形状）。
            setEnabled: (devId, enabled) => deviceAdmin.setEnabled(devId, enabled),
            // 真删除（把行从表里抹掉）：多选与按状态共用 `device-admin.ts` 的同一条
            // `purge`，差别只在"要不要跳过在线的"这个开关 —— **按形状生效**：
            // 按状态批量绝不碰在线的（隐式人口，2026-10-15 事故的危险来源），
            // 显式点名的 id 可以删在线的（操作者的明确目标）。见 device-admin.ts 不变量 2。
            remove: (devIds) => deviceAdmin.remove(devIds),
            removeScope: (scope) => deviceAdmin.removeScope(scope),
            log: logger.info,
          }) ?? null

        abort.signal.addEventListener('abort', () => {
          void transportStop?.()
          unregisterAdminFace?.()
          unregisterAdminFace = null
          pairingEndpoint?.dispose()
          pairingEndpoint = null
        })
      },
      undo() {
        // 先停监听面：不再接受新连接，再收已接受的（它们的连接由监听面自己 stop）。
        // 收口失败只留声：卸载是尽力而为（`lifecycle.ts`），这里抛会盖住后面的步骤。
        void transportStop?.()
        unregisterAdminFace?.()
        unregisterAdminFace = null
        pairingEndpoint?.dispose()
        pairingEndpoint = null
      },
    },
  ]
}

export function apply(ctx: Context, config: ConnectorConfig): void {
  const logger = createChannelLogger(ctx.logger(name))
  const metrics = createMetrics()
  // `Volatile<T>` 是稳定引用而非普通值：取一次快照，之后不再重新读（见 `Assembly` 的说明）。
  const relayUrl = config.relayUrl.get()
  const allowInsecureLocal = config.allowInsecureLocal.get()
  const relayTokenSecretRef = config.relayTokenRef.get()
  const approvalTakeover = config.approvalTakeover.get()
  const listenPort = config.listenPort.get()
  const listenHost = config.listenHost.get()

  // 轨迹投影（`trajectory` 键，契约 §5.7）：**可选注册**。
  // 拿不到 `sessionProjections` 服务时什么都不发生（没有日志、没有报错）——
  // 那是"这台电脑没给时间轴"这条能力缺失，手机侧按缺键显示；
  // 而一个静默没注册上的投影在手机上长得一模一样，所以注册本身失败会抛。
  registerTrajectoryProjection(ctx)

  ctx.effect(() => {
    const abort = new AbortController()
    let mounted: Awaited<ReturnType<typeof mount>> | null = null

    const started = mount(
      buildSteps({
        ctx,
        relayUrl,
        allowInsecureLocal,
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
        // `ctx.logger` 的输出到不了 CLI stdout（实测，见 tools.md 的 Pitfalls），
        // 而"半挂"的症状正是"端点 404、没有任何报错"—— 所以这里必须同时用
        // **能出来的那个出口**，与 `admin/mount.ts` 同一个模式。
        console.error('[dsh-mobile] 挂载失败，通道未启动：', error)
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
