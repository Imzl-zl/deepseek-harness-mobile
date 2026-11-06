/**
 * 连接器标识（`pcId` / 中转控制面的 `?id=`）的生成与迁移。
 *
 * ## 为什么默认值不能是 `local`
 *
 * `local` 是首装写死的字面量（`index.ts` 旧注释）。它同时扮演两个角色：
 * ① 握手 `hello-ack` 里的 `pcId`（参与 transcript）；② 中转控制面 `?id=` 的
 * 连接器身份。前者只需要"两台设备之间稳定"，后者要求**跨租户全局唯一** ——
 * 共用中转上两台电脑都叫 `local` 时，令牌表会出现两条指向同一个 `connectorId`
 * 的记录，中转重启直接拒绝启动（`relay/src/token-table.ts` 的启动校验）。
 *
 * ## 为什么新装随机、老装有配对就保留
 *
 * 换 `pcId` 等于**所有已配对设备的握手 transcript 全部验签失败**（它们存着配对时
 * 的 `pcId`），也就是全部重新扫码。所以：
 * - 新装：随机 `pc-…`，一次写死，不再复发；
 * - 老装且**没有任何已配对设备**：没有东西可破坏，顺手迁到随机值；
 * - 老装有已配对设备：保留 `local`，只记一条告警。多租户中转上的残留冲突按
 *   `docs/cookbook/relay-on-a-server.md` §6.6 处理（清掉一条令牌绑定），
 *   或者由用户主动重新配对换新身份。
 *
 * 取舍与被否方案见
 * `.agents/notes/implemented/2026-11-06-connector-id-random-default.md`。
 */
import { randomBytes } from 'node:crypto'

/** 旧装的默认值。只用于识别"这是历史值"，不再作为新装默认。 */
export const LEGACY_CONNECTOR_ID = 'local'/** 令牌表/中转控制面接受的 id 形状（`main.ts` 的自动签发校验同一条）。 */
const CONNECTOR_ID = /^[A-Za-z0-9._-]{1,64}$/

/**
 * 生成一个新标识：`pc-` + 12 字节 base64url（16 字符，总长 19）。
 *
 * 用随机而不是 `os.hostname()` / MAC：主机名会重名、会改；MAC 在虚拟机上会变，
 * 而且把它当中转身份等于把硬件指纹送上网。随机值一次写进存储，之后一直读它。
 */
export function newConnectorId(): string {
  // `node:crypto` 在插件运行时可用（连接器本来就跑在 Node 里）。
  return `pc-${randomBytes(9).toString('base64url')}`
}

/**
 * 决定这次启动用哪个标识。
 *
 * @param stored - 存储里的值；空串是"尚未配置"的哨兵。
 * @param hasPairedDevices - 设备表里有没有已配对行（有 = 换 id 会让它们全部验签失败）。
 * @param generate - 生成函数（测试注入；产品用 {@link newConnectorId}）。
 */
export function resolveConnectorId(
  stored: string,
  hasPairedDevices: boolean,
  generate: () => string = newConnectorId,
): string {
  if (stored === '') return generate()
  // 旧默认值 + 没有已配对设备：迁移是免费的，顺手做掉。
  if (stored === LEGACY_CONNECTOR_ID && !hasPairedDevices) return generate()
  // 其余（包括老装 `local` + 有配对）原样保留：换它等于让所有手机重新扫码。
  return stored
}

/** 形状断言：读回来的值来自我们自己写的存储，坏值说明有人手改了文件。 */
export function isConnectorId(value: string): boolean {
  return CONNECTOR_ID.test(value)
}
