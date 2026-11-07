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
 * ## 为什么老装也强制迁移
 *
 * 2026-11-07 用户拍板：现在用户很少、还没宣发，**不要为 `local` 留兼容尾巴**。
 * 所有 `local` 一律迁移成随机值。代价是明确的：
 * - 所有已配对手机都要重新扫码（它们存着配对时的 `pcId`，transcript 对不上）；
 * - 旧中转令牌绑在 `local` 上，迁移时必须清掉，重新自助兑换或由管理员签发。
 *
 * 这不影响"加密身份"：手机真正钉的是 `pcSignPubHex`；`pcId` 只是路由标签。
 * 换标签不改密钥，只是让旧配对作废 —— 这正是"换一台电脑身份"的语义。
 *
 * 取舍与被否方案见
 * `.agents/notes/implemented/2026-11-07-connector-id-force-random.md`。
 */
import { randomBytes } from 'node:crypto'

/** 旧装的默认值。只用于识别"这是历史值"，不再作为新装默认。 */
export const LEGACY_CONNECTOR_ID = 'local'

/** 令牌表/中转控制面接受的 id 形状（`main.ts` 的自动签发校验同一条）。 */
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
 * @param generate - 生成函数（测试注入；产品用 {@link newConnectorId}）。
 */
export function resolveConnectorId(
  stored: string,
  generate: () => string = newConnectorId,
): string {
  // 首装，或旧默认值：都生成新的。旧装即使有已配对设备也照换 ——
  // 用户 2026-11-07 拍板"没多少用户，直接换新的"，不再留 `local` 兼容尾巴。
  if (stored === '' || stored === LEGACY_CONNECTOR_ID) return generate()
  return stored
}

/** 形状断言：读回来的值来自我们自己写的存储，坏值说明有人手改了文件。 */
export function isConnectorId(value: string): boolean {
  return CONNECTOR_ID.test(value)
}
