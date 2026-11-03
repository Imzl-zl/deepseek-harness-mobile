/**
 * 插件配置(Schemastery)。
 *
 * 字段表见 docs/subsystems/connector-and-relay.md §1.1。
 * `.volatile()` 的字段会进手机端的通用表单;`.role('credential-ref')` 表示这里只放凭据引用,本体走 ctx.credentials。
 *
 * 写法照 DSH 的 volatile 配置样例
 * packages/web/web-search-deepseek/src/index.ts:49-76:interface 字段用 `Volatile<T>`,
 * 无 default 的字段带 `| undefined`;有 `.volatile()` 时不写 `Schema<Interface>` 标注。
 *
 * 工程形态与版本策略见 .agents/notes/implemented/2026-10-01-connector-workspace-shape.md
 */
import type { Volatile } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'

export interface ConnectorConfig {
  /** 中转地址(wss)。有默认值（内置中转），面板里可换成自部署的。 */
  relayUrl: Volatile<string>
  /** 仅允许非公网地址的明文联调，默认关闭。 */
  allowInsecureLocal: Volatile<boolean>
  /** 允许公网明文（用户自部署中转、暂无域名/证书）。默认关，由用户显式打开。 */
  allowInsecurePublic: Volatile<boolean>
  /** 连接器令牌的凭据引用;本体走 ctx.credentials,不进配置文件。 */
  relayTokenRef: Volatile<string | undefined>
  /**
   * **直连拓扑**的监听端口(契约 §14.6 的第一跳)。`0` = 不监听(只走中转)。
   *
   * 默认 0 而不是某个固定端口:不配置就等于这个功能不存在,而不是"监听了但没人用"。
   */
  listenPort: Volatile<number>
  /** 监听地址。默认只在本机;直连要走 tailnet 时显式写那个地址。 */
  listenHost: Volatile<string>
  /** 推送摘要粒度。 */
  pushDigest: Volatile<'rich' | 'doorbell'>
  /** 单帧上限。 */
  frameLimitBytes: Volatile<number>
  /** 超过此体积的对象改走重取,不内联。 */
  refetchThresholdBytes: Volatile<number>
  /** 增量缓冲的帧数上界。 */
  windowFrames: Volatile<number>
  /** 增量缓冲的字节上界。 */
  windowMaxBytes: Volatile<number>
}

/**
 * 内置中转（这个项目自己的那台）。**是默认值，不是强制**：
 * 面板「连接」卡里随时能换成自部署的地址，换完立刻重建中转通道。
 *
 * 为什么给默认值（2026-11-03）：装插件只写 `dsh.profile.bundles`、不写 config 段，
 * 没有默认值就等于"装完还得去编辑 YAML"。而缺地址时管理面连挂都挂不上（它挂在
 * 最后一步），用户连"在界面里选一条"的机会都没有。
 * 取舍见 `.agents/notes/implemented/2026-11-03-builtin-relay-is-the-default.md`。
 */
export const BUILTIN_RELAY_URL = 'wss://dsh.0t0.me/ws/connector'

/**
 * 生效的中转地址：**空着就是内置中转**。
 *
 * 为什么必须有这一层（2026-11-03 真机踩到）：`relayUrl` 是 `.volatile()` 字段，
 * `Config({})` 这种直接构造会带上 schema 默认值（单测因此是绿的），而 loader 交给
 * `apply()` 的那份 config 在"profile 里没有这一格"时给的是空 —— 于是"装完即用"
 * 在真机上退化成"点启动就报地址解析失败"。兜底写在读取处，schema 默认值只当文档。
 */
export const relayUrlOrDefault = (value: string | undefined): string =>
  value === undefined || value === '' ? BUILTIN_RELAY_URL : value

/**
 * 直连监听面的默认值：**装完就开着**（2026-11-03 用户要求「局域网的也能启动」）。
 *
 * 为什么默认开：局域网直连是"中转不通时的唯一活路"（同一 WiFi 下不经过任何服务器）。
 * 代价是每台机器都会多一个监听端口 —— 但那条连接要过设备身份的握手，未配对的
 * 对端握不上手，所以它不是"开放的门"，只是"开着的窗"。
 *
 * **`0` 仍然是"关"**：`undefined`（没配）才落到默认值。这一格不能反 ——
 * 卡片上的「停用直连」写的就是 `0`，混了就关不掉了。
 */
export const DEFAULT_LISTEN_PORT = 8790
export const DEFAULT_LISTEN_HOST = '0.0.0.0'

export const listenPortOrDefault = (value: number | undefined): number =>
  value === undefined ? DEFAULT_LISTEN_PORT : value

export const listenHostOrDefault = (value: string | undefined): string =>
  value === undefined || value === '' ? DEFAULT_LISTEN_HOST : value

export const Config = z.object({
  relayUrl: z
    .string()
    .default(BUILTIN_RELAY_URL)
    .volatile()
    .description(
      '中转地址，要带 /ws/connector 路径。默认是内置中转；自部署填自己的域名或公网 IP：' +
        'wss://relay.example.com/ws/connector，或（无证书时）ws://1.2.3.4:8787/ws/connector。',
    ),
  allowInsecureLocal: z
    .boolean()
    .default(false)
    .volatile()
    .description('允许非公网地址的明文 ws://（局域网直连、组网）。默认关。'),
  allowInsecurePublic: z
    .boolean()
    .default(false)
    .volatile()
    .description('允许公网地址的明文 ws://（自部署中转、暂无域名/证书）。默认关。'),
  relayTokenRef: z
    .string()
    .role('credential-ref')
    .volatile()
    .description('连接器令牌的凭据引用（令牌本体在 DSH 凭据里，不写进配置）。'),
  // `0` = 关。范围到 65535;`.min(0)` 允许"显式关掉"这个写法。
  listenPort: z
    .number()
    .step(1)
    .min(0)
    .max(65535)
    .default(DEFAULT_LISTEN_PORT)
    .volatile()
    .description('局域网直连监听端口（0 = 关）。默认 8790，手机在同一 WiFi 下会直连它。'),
  listenHost: z.string().default(DEFAULT_LISTEN_HOST).volatile(),
  // **这里不设 `deviceLimit`**：契约规定「设备上限：不设上限」（`docs/subsystems/remote-channel.md:811`），
  // 配对路径上没有"第 N 台拒绝"这个判据；而一个没人读的 `.volatile()` 字段只会进手机端通用表单
  // （假旋钮）。别再加回来：取舍见 `.agents/notes/implemented/2026-10-29-drop-inert-device-limit.md`。
  pushDigest: z.union([z.const('rich'), z.const('doorbell')]).default('rich').volatile(),
  frameLimitBytes: z.number().step(1).min(1).default(8_388_608).volatile(),
  refetchThresholdBytes: z.number().step(1).min(1).default(1_048_576).volatile(),
  windowFrames: z.number().step(1).min(1).default(10_000).volatile(),
  windowMaxBytes: z.number().step(1).min(1).default(16_777_216).volatile(),
})
