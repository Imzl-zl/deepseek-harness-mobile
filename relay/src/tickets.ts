/**
 * 中转的一次性 ticket（契约 §2 的连接建立）。
 *
 * 手机不把长期令牌放进 URL（URL 会进日志、进代理记录、进浏览器历史），
 * 而是先 `POST /ws-ticket` **用令牌换一张一次性票**，再拿票去升级 WS。
 * 于是"凭据出现在 URL 里"这件事被压缩成"一张 60 秒内有效、用过即废的随机票"。
 *
 * ## 四处都必须有，缺一处都不成
 *
 * 1. **票是 128 位随机**（不是可猜的序号）：它本身就是凭据，猜中就等于冒充那台设备。
 * 2. **只存哈希**：与配对码（§12.1）、令牌摘要（§12.2）同一条纪律 ——
 *    中转的库或日志被读到时，里面的东西不该直接能用。票值是**一次性**的，
 *    所以"存哈希"在这里的代价为零（换票时才需要比对，而比对就是算一次哈希）。
 * 3. **绑定设备身份**：换票时认证出的设备 id 记在票上，升级时必须拿回同一个 id ——
 *    不然 A 设备的票能被 B 拿去做"我是 A"的升级。
 * 4. **一次性 + 短 TTL**：认领即删（任何路径都不会被用两次）；
 *    过期在认领时就地作废，不指望清扫兜正确性（与去重表、配对登记的惰性过期同一条纪律）。
 */
import { createHash, randomBytes as nodeRandomBytes } from 'node:crypto'

import type { ChannelLogger } from './logger.ts'

/** 票值长度（16 字节 = 128 位；与 `requestId`、配对码同规格）。 */
export const TICKET_BYTES = 16

/**
 * 票据寿命。契约只说"一次性"，没定秒数；取 **60 秒**：
 * 够一次"换票 → 立刻升级"的网络往返（含手机端弱网重试一两次），
 * 又短到"泄露的票基本没有可用窗口"。这是个**我们的选择**，写在笔记里。
 */
export const TICKET_TTL_MS = 60_000

export interface TicketIssue {
  /** 票值：**只在这一刻返回**，中转不留明文。 */
  readonly ticket: string
  readonly expiresAt: number
  readonly deviceId: string
}

export interface TicketStoreOptions {
  now?: () => number
  ttlMs?: number
  randomBytes?: (size: number) => Uint8Array
  log?: ChannelLogger
}

export interface TicketStore {
  /** 给一台**已认证**的设备发票（认证在调用方那一步完成）。 */
  issue(deviceId: string): TicketIssue
  /**
   * 升级时消费一张票。
   *
   * @returns 这张票绑定的设备 id；票不存在 / 已过期 / 已用过 → `undefined`。
   */
  consume(ticket: string): string | undefined
  /** 清掉过期票。返回清掉几张。 */
  prune(): number
  readonly stats: { tickets: number }
}

const hashOf = (ticket: string): string => createHash('sha256').update(ticket, 'utf8').digest('hex')

export function createTicketStore(options: TicketStoreOptions = {}): TicketStore {
  const now = options.now ?? (() => Date.now())
  const ttlMs = options.ttlMs ?? TICKET_TTL_MS
  const random = options.randomBytes ?? ((size: number) => nodeRandomBytes(size))
  const log = options.log

  /** `票的哈希 → { deviceId, expiresAt }`。**没有明文票**。 */
  const tickets = new Map<string, { deviceId: string; expiresAt: number }>()

  return {
    get stats() {
      return { tickets: tickets.size }
    },

    issue(deviceId) {
      const ticket = Buffer.from(random(TICKET_BYTES)).toString('base64url')
      const expiresAt = now() + ttlMs
      tickets.set(hashOf(ticket), { deviceId, expiresAt })
      log?.debug(`已发票给设备 ${deviceId}（${tickets.size} 张待用）`)
      return { ticket, expiresAt, deviceId }
    },

    consume(ticket) {
      const key = hashOf(ticket)
      const entry = tickets.get(key)
      if (entry === undefined) return undefined
      // 一次性：先删再返回，任何路径都不会让同一张票被用两次。
      tickets.delete(key)
      if (entry.expiresAt <= now()) {
        log?.debug('票已过期（按未命中处理）')
        return undefined
      }
      return entry.deviceId
    },

    prune() {
      const at = now()
      let removed = 0
      for (const [key, entry] of tickets) {
        if (entry.expiresAt > at) continue
        tickets.delete(key)
        removed += 1
      }
      return removed
    },
  }
}
