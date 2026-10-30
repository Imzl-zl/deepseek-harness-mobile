/**
 * 插件面板的 RPC 端点（`/api/dsh-mobile/*`）—— 管理面自己的读面与写面。
 *
 * ## 为什么走 `ctx.connection.fetch.register`，而不是再开一条路
 *
 * DSH 的 Connection 服务已经在 `/api` 上挂了一个**带认证**的共享通道
 * （`packages/client/connection/src/index.ts:156` 注册前缀路由，准入判据在
 * `rpc-host.ts:107-117`：Host/Origin 栅栏 + 浏览器 cookie）。往它上面注册
 * 精确路由（`rpc.ts:144-153` 的 `ConnectionFetchRoute`）就**白拿认证**，
 * 不必自己实现一套 token 校验 —— 自己实现的那套只会更弱。
 * 先例：`packages/experimental/inspector/src/host/plugin.ts:64-69`
 * 用同一条路注册 inspector 的 bootstrap 端点。
 *
 * ## 为什么端点名是 `/dsh-mobile/*`
 *
 * 管理面与手机通道面是**两件事**：前者是操作者在浏览器里看这台电脑的桥接状态、
 * 出配对码、吊销设备；后者是契约 §5.7 的方法表（手机 ⇄ 电脑）。
 * 所以它**不进 §5.7 的方法表**，也不进 `repo.info` 的 `methods` ——
 * 混在一起会让"契约定义了哪些手机面"这个问题的答案变糊。
 *
 * ## 停用/启用是一对布尔端点，不是两个动作
 *
 * 先例 `setBundleEnabled(name, enabled)`
 * （`packages/boot/plugin-manager/src/index.ts:476`）—— 同一个名字的同一个能力，
 * 一个布尔决定它在不在。本面板的 `POST /devices/enabled` 照这个形状：
 * `enabled:false` 停用（标 `revokedAt`）、`enabled:true` 解禁（把 `revokedAt`
 * 从行上拿掉）。两个端点会让"停用"与"解禁"看起来像两件不相干的事，
 * 而它们本来就是同一件的两个值。
 *
 * ## 传输面：按"方式"分开关，路由按通道生成
 *
 * 2026-10-17 用户原话：「不是有两中方式为啥就一个开关？……后面我要是再加新的方式
 * 也就一个开关吗？」。所以传输面是**通道注册表**（`transport/channels.ts`）：
 * `GET /transport` 列通道，`POST /transport/{id}/{start,stop}` 各停各的。
 *
 * **路由按 `deps.channels()` 在挂载时生成**，id 不写死在路由表里 —— Connection 的
 * Fetch 路由是**精确路径匹配**（`rpc-host.ts:141` 的 `fetchRoutes.get(pathname)`），
 * 没有路径参数通配。于是"加第三种方式（Tailscale / 服务器中转）"只是注册表多一个
 * 端口，路由与 UI 开关自动跟上，**形状不变** —— 这条由
 * `tests/admin-face.test.ts`（三个端口的注册表 ⇒ 三对路由）钉住。
 *
 * 批量启停（同时开 / 同时关）**不设服务端端点**：两个通道各自的成败要能分别报回
 * 界面，一个批量端点只会把其中一个的失败藏掉。批量是 UI 的顺序调用。
 *
 * ## 破坏性操作单独一个端点，且页面二次确认
 *
 * 停用一台设备 = 那台手机下次握手就通不过；删除 = 那台手机要重新配对。
 * 它们走 `POST` 而不是 GET，就是为了不让"误点到一行链接"成为破坏性操作。
 * 确认框在浏览器半侧（`client.js`），是**页面内 DOM 对话框**而不是
 * `window.confirm` —— 2026-10-15 事故里 chrome-devtools 的 `evaluate_script`
 * 有个默认 accept 的 `dialogAction`，脚本点到"清掉当前离线"就把 31 条记录
 * 硬删了。原生对话框挡不住自动化，页面内的才挡得住。
 *
 * ## 删除：显式多选可以删在线的，按状态批量绝不碰在线的
 *
 * `POST /devices/remove` 的 body 二选一：`{devIds: string[]}`（显式多选，
 * 单个删除就是长度 1 的数组）或 `{scope: 'revoked' | 'all'}`（按状态批量）。
 *
 * **没有 `offline` scope**：那个 scope 的人口专门命中"暂时离线但还在用"的
 * 设备 —— 事故里被删掉的正是用户自己那台（他当时在排查重连，处于离线态），
 * 而服务端"跳过在线"保护不了它。要删具体的几台用多选。
 *
 * **在线豁免只属于按状态批量**（`device-admin.ts` 不变量 2）：scope 的人口是
 * 隐式的一整类，事故的危险正来自隐式人口；而 `devIds` 是操作者指着某一行、
 * 逐个勾的，意图无歧义 —— 手机丢了还在线，要立刻弄死它，为此先"让那台手机
 * 断开连接"是荒谬的。所以 `skippedOnline` 只对 scope 形状非 0。
 */
import type { Caps } from '../dsh/caps.js'
import type { ChannelState } from '../transport/channels.js'
import type { AdvertiseKind, AdvertiseView } from './advertise.js'
import type { ConnectionSaveResult, ConnectionView } from './connection-card.js'

/**
 * Connection 的精确 Fetch 路由（`packages/client/connection/src/rpc.ts:144-153`）。
 *
 * **按形状在这里重声明，不 import DSH 那个包**：连接器只在运行时经 `ctx.get('connection')`
 * 拿到这个服务，类型上不需要它；而 `@deepseek-ai/dsh-client-connection` 不是本插件的依赖
 * （装进 profile 时它由宿主提供）。加一个只为类型的 devDependency 会多一处版本协调，
 * 而形状就三行。
 */
export interface ConnectionFetchRoute {
  /**
   * **完整路径，含 `/api` 前缀**。
   *
   * 文档（`rpc.ts:145`）写的是 "Absolute path below `/api`"，容易读成"不要带 /api"；
   * 但消费它的 `createSharedFetchHandler` 是 `this.fetchRoutes.get(new URL(request.url).pathname)`
   * （`rpc-host.ts:141`）—— **键是完整 pathname**。带少了就是 404，而那个 404
   * 长得和"路由没注册"一模一样（都是 `not found`）。
   */
  readonly path: string
  readonly methods: readonly string[]
  readonly requestBody: 'buffered' | 'streaming'
  readonly fetch: (request: Request) => Promise<Response>
}

/** 管理面需要的一切（装配层给；这里不认识 cordis，便于纯 Node 单测）。 */
export interface AdminDeviceRow {
  id: string
  name: string
  pairedAt: number
  revoked: boolean
  /** 这台设备**现在**连着吗。**只对本次进程运行期间连过的设备准确** ——
   *  presence 的 live 表在内存里，重启即空（`presence.ts:38-44`）。 */
  online: boolean
  /**
   * 这台设备**正占着服务位**（独占 1:1，`presence.serving()`）。
   *
   * 与 `online` 的关系：此刻在服务的那台 `online` 必为 true；反过来不一定 ——
   * 面板要能分出"有台设备在线"与"就是它占着这台电脑"（后者才是新手机连不上的原因）。
   * 非在线的行恒为 false。
   */
  serving: boolean
  /** 它的 App 在前台吗（决定审批仲裁选它还是退给桌面）。 */
  foreground: boolean
  /** 最后交互时刻（毫秒）；从未交互过就没有这个字段。 */
  lastInteractedAt?: number
}

export interface AdminDeps {
  caps(): Caps
  metrics(): Readonly<Record<string, number>>
  devices(): readonly AdminDeviceRow[]
  /** 当前拨向的中转地址；没有配 `relayUrl` 就是 `null`。 */
  relayUrl(): string | null
  /**
   * 传输通道列表（按"方式"分开关的数据源，`transport/channels.ts`）。
   *
   * 路由表按它生成（`/transport/{id}/{start,stop}`），所以**加一种方式不改
   * 管理面形状**；UI 也按它渲染。见文件头「传输面」一节。
   */
  channels(): readonly ChannelState[]
  /** 起或停一条传输通道。失败抛出（归一成 400 + 原因带回界面）。 */
  setChannel(id: string, running: boolean): Promise<void>
  /**
   * 「上报哪些地址」：藏掉虚拟网卡、追加不在枚举里的地址（如 Tailscale）。
   *
   * 它影响的是 `endpoint.describe` 的输出 —— 也就是**手机看到哪些可拨地址**。
   * 见 `admin/advertise.ts` 的文件头。
   */
  advertise: {
    view(): AdvertiseView
    set(url: string, kind: AdvertiseKind | 'clear'): Promise<void>
  }
  /**
   * 出一次配对码（**已登记到中转**）。
   *
   * 实现是 `issuePairingOffer` + `pairingQrSvg`：登记失败就不出码
   * （否则给出一张扫了也配不上的码）。
   *
   * **只回 svg 与过期时刻，不回 payload**：载荷里有两把 64 hex 公钥，
   * 而浏览器只负责把它画成图。让 payload 过线等于把密钥材料送到一个
   * 不需要它的地方 —— 少送一个字段就少一处泄漏面。
   */
  offer(): Promise<{ svg: string; expiresAt: number }>
  /**
   * 停用（`enabled: false`）或解禁（`enabled: true`）一台设备。
   *
   * **一对布尔，不是两个动作** —— 照 DSH `setBundleEnabled(name, enabled)`
   * （`packages/boot/plugin-manager/src/index.ts:476`）。实现是
   * `device-admin.ts` 的 `setEnabled`：停用写 `revokedAt`，解禁把它从行上拿掉。
   */
  setEnabled(devId: string, enabled: boolean): Promise<void>
  /**
   * **真删除**指定的几台设备（`domainTable.delete`，`storage-domain/src/domain.ts:80`）。
   *
   * 与 {@link setEnabled} 的区别：停用只标 `revokedAt`，记录还在表里、列表还显示；
   * 删除把行抹掉。用户要的是"把这些记录弄干净"，只有删除能做到。
   * **单台就是长度 1 的数组** —— 没有单独的单删形状，两条路必须同一条规则。
   *
   * **显式点名，可以删在线的**：操作者指着某一行 / 逐个勾的，意图无歧义
   * （手机丢了还在线，要立刻弄死它）。见 `device-admin.ts` 不变量 2。
   *
   * @returns 实际删了几台。**恒为 0 的 `skippedOnline`** 也一并回，形状与
   *   {@link removeScope} 保持一致
   */
  remove(devIds: readonly string[]): Promise<{ removed: number; skippedOnline: number }>
  /**
   * 按状态真删除。
   *
   * @param scope - `revoked` 已停用 / `all` 全部。**没有 `offline`**：那个 scope
   *   专门命中"暂时离线但还在用"的设备，2026-10-15 事故删掉的正是用户自己那台。
   * @returns 实际删了几台，以及**跳过几台在线的**（按状态批量绝不误伤）
   */
  removeScope(scope: 'revoked' | 'all'): Promise<{ removed: number; skippedOnline: number }>
  /**
   * 面板「连接」卡的读写面。
   *
   * **逻辑全在 `connection-card.ts`**：白名单、`relayUrlOf` 校验、一次写入、
   * 冲突归一都在那边；本文件只把 HTTP 形状接上 —— 路由层不认识 settings、
   * 也不认识凭据 seam，这样那三条判据才能脱 DSH 单测。
   */
  connection: {
    read(): Promise<ConnectionView>
    save(body: unknown): Promise<ConnectionSaveResult>
  }
}

const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8' }

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: JSON_HEADERS })

/** 读请求体里的 JSON；不是对象就抛（调用方归一成 400）。 */
async function bodyOf(request: Request): Promise<Record<string, unknown>> {
  let parsed: unknown
  try {
    parsed = await request.json()
  } catch {
    throw new Error('请求体不是合法 JSON')
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error('请求体必须是 JSON 对象')
  }
  return parsed as Record<string, unknown>
}

/** 把端点里的失败归一成 400 + 消息（不让它炸成 Connection 桥接的 500 文本）。 */
const badRequest = (error: unknown): Response =>
  json({ ok: false, error: error instanceof Error ? error.message : String(error) }, 400)

/** 管理面的端点。顺序无关，都是精确路由。路径**含 `/api` 前缀**（见接口注释）。 */
const STATUS_PATH = '/api/dsh-mobile/status'
const PAIR_PATH = '/api/dsh-mobile/pair'
const TRANSPORT_PATH = '/api/dsh-mobile/transport'
const ADVERTISE_PATH = '/api/dsh-mobile/advertise'
const ENABLED_PATH = '/api/dsh-mobile/devices/enabled'
const REMOVE_PATH = '/api/dsh-mobile/devices/remove'
const CONNECTION_PATH = '/api/dsh-mobile/connection'

export function createAdminRoutes(deps: AdminDeps): ConnectionFetchRoute[] {
  const routes: ConnectionFetchRoute[] = [
    {
      path: STATUS_PATH,
      methods: ['GET'],
      requestBody: 'buffered',
      fetch: () =>
        Promise.resolve(
          json({
            caps: deps.caps(),
            metrics: deps.metrics(),
            relayUrl: deps.relayUrl(),
            devices: deps.devices(),
          }),
        ),
    },

    // 「连接」卡：**一条路由按方法分支**（同 `/advertise` 的理由 —— DSH 的精确
    // 路由不能同 path 注册两条，`rpc-host.ts:141` 的 `fetchRoutes.get(pathname)`）。
    {
      path: CONNECTION_PATH,
      methods: ['GET', 'POST'],
      requestBody: 'buffered',
      fetch: async (request: Request) => {
        if (request.method === 'GET') return json(await deps.connection.read())
        let body: unknown
        try {
          body = await request.json()
        } catch {
          return badRequest(new Error('请求体不是合法 JSON'))
        }
        // 失败的**形状也由卡片决定**（带 `field` 与保存后的真值），
        // 路由层不再自己拼错误体 —— 否则两处各有一套错误词表。
        const result = await deps.connection.save(body)
        return json(result.body, result.status)
      },
    },

    // 传输面：**按通道**列与停启。停 ≠ 卸载：不清凭据、不动身份，
    // 重起时配对过的手机一条都不用重扫（2026-10-17 用户要求：连接器不能只有
    // 命令行一种起法；同轮要求：两个方式两个开关，加第三种方式不改形状）。
    {
      path: TRANSPORT_PATH,
      methods: ['GET'],
      requestBody: 'buffered',
      fetch: () => Promise.resolve(json({ channels: deps.channels() })),
    },

    {
      path: PAIR_PATH,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async () => {
        // 出码是**有副作用的**（登记一次 offer），所以是 POST 而不是 GET：
        // GET 会被预取/刷新重复触发，那会白烧一堆一次性 offer。
        const offer = await deps.offer()
        return json(offer)
      },
    },

    // 上报地址：**一条路由，按方法分支**（GET 看 / POST 改）。
    //
    // 不能写成两条同路径的 route —— DSH 的 `registerFetchRoute` 按路径注册，
    // 两条**同 path** 会在挂载期抛
    // `connection: exact Fetch route "/api/dsh-mobile/advertise" is already registered`
    // （0.2.1 起校验；0.2.0 不校验）。而挂载异常会让连接器停在 `start-transport`
    // 那一步，症状是"插件已加载但直连面起不来"—— 2026-10-18 升级 0.2.1 时实测。
    {
      path: ADVERTISE_PATH,
      methods: ['GET', 'POST'],
      requestBody: 'buffered',
      fetch: async (request: Request) => {
        if (request.method === 'GET') return json(deps.advertise.view())

        let body: Record<string, unknown>
        try {
          body = await bodyOf(request)
        } catch (error) {
          return badRequest(error)
        }
        const url = body['url']
        if (typeof url !== 'string' || url === '') {
          return badRequest(new Error('url 必填'))
        }
        const kind = body['kind']
        // 三态封闭：hide（藏掉自报的）/ extra（追加一条）/ clear（回到默认）。
        if (kind !== 'hide' && kind !== 'extra' && kind !== 'clear') {
          return badRequest(new Error('kind 必须是 hide / extra / clear'))
        }
        try {
          await deps.advertise.set(url, kind)
        } catch (error) {
          return badRequest(error)
        }
        return json({ ok: true, ...deps.advertise.view() })
      },
    },

    {
      path: ENABLED_PATH,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request: Request) => {
        let body: Record<string, unknown>
        try {
          body = await bodyOf(request)
        } catch (error) {
          return badRequest(error)
        }
        const devId = body['devId']
        if (typeof devId !== 'string' || devId === '') {
          return badRequest(new Error('devId 必填'))
        }
        const enabled = body['enabled']
        // 形状照 `setBundleEnabled(name, enabled)`：**一个布尔**，不是"停用/解禁"两个动作。
        if (typeof enabled !== 'boolean') {
          return badRequest(new Error('enabled 必须是布尔值'))
        }
        const known = deps.devices().some((row) => row.id === devId)
        // **不认识的设备 id 不当成功**：那会让页面显示"已停用"而实际上什么都没发生。
        if (!known) return json({ ok: false, error: `未知设备：${devId}` }, 400)
        try {
          await deps.setEnabled(devId, enabled)
        } catch (error) {
          // 失败必须带原因（照 DSH `停用失败：{reason}` / `启用失败：{reason}`，
          // `presentation.ts:63-70` 的 FAILED_KEYS）—— 静默的失败会让人以为按钮坏了。
          // id 刚验过还在，这里还抛只可能是并发删掉了那行；归一成 400 把原话带回界面。
          return badRequest(error)
        }
        return json({ ok: true, enabled, devices: deps.devices() })
      },
    },

    {
      path: REMOVE_PATH,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request: Request) => {
        let body: Record<string, unknown>
        try {
          body = await bodyOf(request)
        } catch (error) {
          return badRequest(error)
        }
        // **按状态删**：一键清掉一类。scope 是封闭集，`offline` 已经删掉
        // （它命中"暂时离线但还在用"的设备，见文件头）。
        const scope = body['scope']
        if (scope !== undefined) {
          if (scope !== 'revoked' && scope !== 'all') {
            return badRequest(new Error('scope 必须是 revoked / all'))
          }
          const result = await deps.removeScope(scope)
          return json({ ok: true, ...result, devices: deps.devices() })
        }
        // **多选删**：显式点出来的几台。单个删除就是长度 1 的数组 ——
        // 与按状态共用同一条服务端路径，差别只在"要不要跳过在线"（见文件头）。
        const devIds = body['devIds']
        if (
          !Array.isArray(devIds)
          || devIds.length === 0
          || devIds.some((id) => typeof id !== 'string' || id === '')
        ) {
          return badRequest(new Error('devIds 必须是非空字符串数组（或 scope: revoked|all）'))
        }
        // 上面那条 `typeof id !== 'string'` 已经把每个元素否成了 string，但
        // `Array.isArray` 只把 `unknown` 收窄成 `unknown[]` —— 这里显式落一句。
        const ids = devIds as string[]
        const known = new Set(deps.devices().map((row) => row.id))
        const unknown = ids.find((id) => !known.has(id))
        // **不认识的 id 不当成功**：那会让界面显示"已删除"而实际上什么都没发生。
        // 400 而不是 404 —— 本文件其余失败都走 `badRequest`，404 是异类。
        if (unknown !== undefined) return badRequest(new Error(`未知设备：${unknown}`))
        const result = await deps.remove(ids)
        return json({ ok: true, ...result, devices: deps.devices() })
      },
    },
  ]

  // 传输通道的起停端点：**按注册表生成**，id 不写死在路由表里。
  // 加一种方式（Tailscale / 服务器中转）只是 `deps.channels()` 多一项，
  // 这里自动多一对路由 —— 管理面形状不变（文件头「传输面」一节）。
  for (const channel of deps.channels()) {
    for (const running of [true, false]) {
      routes.push({
        path: `${TRANSPORT_PATH}/${channel.id}/${running ? 'start' : 'stop'}`,
        methods: ['POST'],
        requestBody: 'buffered',
        fetch: async () => {
          try {
            await deps.setChannel(channel.id, running)
          } catch (error) {
            // 启动失败（端口被占等）必须带原因：静默失败会让操作者以为开关生效了。
            return badRequest(error)
          }
          // 回执带**当时的**通道真值（不是"我以为成功了"）—— 按钮的
          // "运行中/未运行"要从电脑侧读，不按本地点击乐观翻转。
          return json({ ok: true, channels: deps.channels() })
        },
      })
    }
  }

  return routes
}
