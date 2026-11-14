/** 首配 v2：公开发现与秘密授权分离，规范见 docs/subsystems/pairing-v2.md。
 * 决策见 .agents/notes/implemented/2026-10-08-pairing-v2-and-device-connections.md。
 */
import { createHash, hkdfSync, randomBytes as nodeRandomBytes, timingSafeEqual } from 'node:crypto'

export const PAIRING_VERSION = 2
export const PAIRING_CODE_BYTES = 16
export const PAIRING_TTL_MS = 5 * 60 * 1000
export const PAIRING_ID_INFO = 'dsh-mobile/v1/pairing'
export const PAIRING_KEY_INFO = 'dsh-mobile/v2/pairing-keys|'
export const SAS_INFO = 'dsh-mobile/v1/sas'
export const MAX_DEVICE_NAME_BYTES = 256

const TOKEN = /^[A-Za-z0-9_-]{22}$/
const PUBLIC_KEY = /^[0-9a-f]{64}$/
const ID = /^[A-Za-z0-9_-]+$/
/** `pairingId` 的形状：32 字节 HKDF 输出的无填充 base64url（43 字符）。 */
const PAIRING_ID = /^[A-Za-z0-9_-]{43}$/
const base64url = (bytes: Uint8Array): string => Buffer.from(bytes).toString('base64url')
const hash = (text: string): Buffer => createHash('sha256').update(text, 'utf8').digest()

/** 二维码里能走的一条路。`routes` 字段的取值。 */
export type PairingRoute = 'lan' | 'relay'

export interface PairingOffer {
  readonly offerId: string
  /** 只交给二维码，不登记到中转。 */
  readonly code: string
  readonly expiresAt: number
  readonly payload: string
  /**
   * 这张码里**实际有哪几条路**（给新版手机读，载荷里的 `routes`）。
   *
   * 由出码那一刻的能力算出来：直连监听在跑才有 `lan`，**中转连上了**才有 `relay`
   * （不是配置里有地址就算）。旧版 App 忽略这个字段，仍按 `relay` + `lan` 试。
   *
   * 2026-11-13 起，"关掉中转"的确定语义就是这里没有 `relay` —— 以前登记成功
   * 就写 `relay`，而那条腿可能已经死了（`issuePairingOffer` 的旧注释解释过）。
   */
  readonly routes: readonly PairingRoute[]
  /**
   * 载荷里那组**局域网直连地址**（`ws://<ip>:<port>`，手机在同网段时直接拨它们）。
   *
   * 单独给出来是为了让 `issuePairingOffer` 不必回头解析自己刚拼的 JSON：
   * "有没有局域网这条路"决定登记失败能不能降级（见那里的注释）。
   * 空数组 = 这次只有中转可走（老载荷形状）。
   *
   * Note: 为什么二维码里要带局域网地址 —— 见
   * `.agents/notes/implemented/2026-11-03-pairing-without-relay.md`
   */
  readonly lanUrls: readonly string[]

  /**
   * 这张码**只有局域网那一条路**：出码时向中转登记失败，跨网那条腿没有接上。
   *
   * 载荷里同时带 `lanOnly: true`（契约 §12.1）：手机据此**显式提示**
   * 「此码只能在同一 Wi-Fi 下使用」，并且不去拨一条注定失败的换票请求。
   * 电脑侧的命令文案与插件面板也读它 —— 三处说的是同一个事实。
   *
   * Note: 为什么登记失败仍然出码、为什么必须让降级可见 —— 见
   * `.agents/notes/implemented/2026-11-04-pairing-degradation-is-visible.md`
   */
  readonly lanOnly: boolean
}

/** 由该连接的持钥证明绑定的候选；不能从 pair-commit 载荷里再取一份身份。 */
export interface PairingCandidate {
  readonly offerId: string
  readonly devPubEd: string
  readonly devPubDh: string
  readonly name: string
}

export interface PairingRequest {
  readonly v: 2
  readonly offerId: string
  readonly code: string
  /**
   * 手机**自报的旧配对标识**（重新配对同一台电脑时带上）。
   *
   * 它**不是认证凭据**：授权完全由一次性二维码秘密与候选持钥证明完成
   * （`accept` 先验 `code` 才 accept，见本文件 `accept`）。它只是**行定位符** ——
   * 电脑侧据此找到"这台手机上一次的配对记录"并整行替换（换密钥、换令牌、
   * 换 pairingId，保留首次配对的 `pairedAt`），于是同一台手机反复扫码不再攒行。
   * 取舍与威胁模型见 `.agents/notes/implemented/2026-10-17-repair-replaces-device-row.md`。
   *
   * 只在 `pair-commit` 的**密文**里出现（中转不可见，I10）；换票请求是匿名的，
   * 绝不能把它放进去。
   */
  readonly previousPairingId?: string
}

export interface PairingAccepted {
  readonly pairingId: string
  readonly expiresAt: number
  readonly device: {
    readonly devId: string
    readonly name: string
    readonly edPubHex: string
    readonly dhPubHex: string
    readonly pairingId: string
    readonly pairedAt: number
  }
  /** 手机自报的旧配对标识（可选）。**行定位符，不是凭据** —— 见 {@link PairingRequest}。 */
  readonly previousPairingId?: string
  readonly sas: string
}

export type PairingRejection = 'expired' | 'mismatch' | 'consumed' | 'invalid'

export interface PairingOptions {
  /**
   * 二维码里给手机的中转地址。**可以是函数** —— 出码时求值，这样电脑换
   * WiFi/IP 后二维码自动带当前地址（配置里的 `relayUrl` 是拨号地址，
   * 两者不是一回事，见 [relayHintFor]）。
   */
  relayUrl: string | (() => string)
  /**
   * 二维码里给手机的**局域网直连地址**（`ws://<ip>:<port>`，不带路径/参数）。
   *
   * 由装配层用 `describeEndpoints` 的 direct 那组算出来（那是"这台机器现在
   * 拨得通哪些地址"的唯一一份答案，见 `endpoints.ts`）；本文件不认识网卡，
   * 只负责把它写进载荷。**同样是出码时求值**：换 WiFi 之后二维码跟着变。
   *
   * 空/缺 = 这次配对只能走中转（老载荷形状，手机按老路换票）。
   */
  lanUrls?: () => readonly string[]
  /**
   * 中转**此刻真的连上了吗**（默认 `true`）。
   *
   * 出码时求值：登记成功不代表跨网那条腿活着 —— 关掉中转通道后登记仍能成功
   * （`/pairing/register` 只验令牌），所以"码里有没有 relay"必须看控制面
   * （`connection.connected`），不看配置里的地址。
   */
  relayAvailable?: () => boolean
  pcId: string
  pcPubEd: string
  pcPubDh: string
  now?: () => number
  randomBytes?: (size: number) => Uint8Array
  deviceIdOf?: (candidate: PairingCandidate) => string
}

export interface Pairing {
  offer(): PairingOffer
  allows(candidate: PairingCandidate): boolean
  accept(request: PairingRequest, candidate: PairingCandidate): PairingAccepted | { rejected: PairingRejection }
  readonly pending: boolean
}

/** 只作电脑侧秘密校验与已有业务 pairingId 派生，绝不再登记到中转。 */
export function pairingCodeHash(code: string): string {
  return hash(code).toString('hex')
}

export function pairingIdOf(codeHash: string): string {
  return base64url(Buffer.from(hkdfSync('sha256', Buffer.from(codeHash, 'utf8'), Buffer.alloc(0), PAIRING_ID_INFO, 32)))
}

/** 辅助显示，不是配对授权判据。 */
export function sasOf(pcPubEd: string, devPubEd: string): string {
  return String(hash(`${SAS_INFO}|${pcPubEd}|${devPubEd}`).readUInt32BE(0) % 1_000_000).padStart(6, '0')
}

export function deviceIdOf(candidate: Pick<PairingCandidate, 'devPubDh'>): string {
  return base64url(hash(candidate.devPubDh).subarray(0, 16))
}

export function isPairingCandidate(value: unknown): value is PairingCandidate {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false
  const record = value as Record<string, unknown>
  return typeof record['offerId'] === 'string' && TOKEN.test(record['offerId'])
    && typeof record['devPubEd'] === 'string' && PUBLIC_KEY.test(record['devPubEd'])
    && typeof record['devPubDh'] === 'string' && PUBLIC_KEY.test(record['devPubDh'])
    && typeof record['name'] === 'string' && record['name'].trim() !== ''
    && Buffer.byteLength(record['name'], 'utf8') <= MAX_DEVICE_NAME_BYTES
}

/** 双端从自己的可信输入构造；中转篡改任一字段会使 transcript 签名不匹配。 */
export function pairingHandshakeContext(
  pc: { pcId: string; pcPubEd: string; pcPubDh: string },
  candidate: PairingCandidate,
): string {
  if (!isPairingCandidate(candidate) || !ID.test(pc.pcId)
    || !PUBLIC_KEY.test(pc.pcPubEd) || !PUBLIC_KEY.test(pc.pcPubDh)) {
    throw new TypeError('配对认证上下文字段不合法')
  }
  return [
    'dsh-mobile/pairing/v2', candidate.offerId, pc.pcId, pc.pcPubEd, pc.pcPubDh,
    deviceIdOf(candidate), candidate.devPubEd, candidate.devPubDh, pairingCodeHash(candidate.name),
  ].join('|')
}

function isRequest(value: unknown): value is PairingRequest {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false
  const record = value as Record<string, unknown>
  // `previousPairingId` 是**可选**的：缺它 = 首配或凭据已丢，走"新行"。
  // 在却格式不对 = 客户端 bug 或篡改 —— **拒**而不是静默忽略：忽略会让
  // "重新配对替换旧行"悄悄退化成"又攒一行"，而用户看不到任何原因。
  if ('previousPairingId' in record
    && (typeof record['previousPairingId'] !== 'string' || !PAIRING_ID.test(record['previousPairingId']))) {
    return false
  }
  return record['v'] === PAIRING_VERSION
    && typeof record['offerId'] === 'string' && TOKEN.test(record['offerId'])
    && typeof record['code'] === 'string' && TOKEN.test(record['code'])
    && !('codeHash' in record)
}

/**
 * 二维码里那个 `relay` 字段的**当前值**。
 *
 * 配置里的 `relayUrl` 是**拨号地址**，二维码里给的必须是**手机拨得通的地址**：
 * 中转就在本机时配置写环回（`ws://127.0.0.1:8787/...`，与网卡无关），
 * 而二维码要填本机的局域网地址 —— 换 WiFi 之后它跟着变，用户不用回去改配置
 * （2026-10-17 真机踩到：配置里写着 192.168.2.43，电脑换网后手机拨不通，
 * 重新出码也还是那个死地址）。
 *
 * 规则（三条，可单测）：
 * - **环回** → 换成 [lanHint]（默认路由网卡的局域网地址；内核选路得来，
 *   不枚举网卡 —— 枚举会抓到 VMware 虚拟网卡，手机拨不通）；
 * - **域名** → 原样返回（中转部署在服务器上，稳定地址，谈不上过期）；
 * - **其它 IP** → 原样返回（用户显式钉的地址，如中转在另一台机器上）。
 *
 * `lanHint` 为 `null`（拿不到默认路由）时环退原样 —— 不猜。
 */
export function relayHintFor(configured: string, lanHint: string | null): string {
  let url: URL
  try {
    url = new URL(configured)
  } catch {
    return configured
  }
  const host = url.hostname.replace(/^\[|\]$/g, '')
  const loopback = host.startsWith('127.') || host === '::1' || host === 'localhost'
  if (!loopback) return configured
  if (lanHint === null || lanHint === '') return configured
  url.hostname = lanHint.includes(':') ? `[${lanHint}]` : lanHint
  return url.toString()
}

/**
 * 登记失败时的**降级标**：返回一份 `lanOnly: true` 的 offer（载荷里也多这一格）。
 *
 * 只改"这张码能怎么走"，不改 offerId / code / 局域网地址 —— 手机拿到的还是同一张码，
 * 只是它现在知道"别去试中转"。**不可变**：返回新对象，调用方手里的原件不动
 * （`issuePairingOffer` 里两个分支用同一个 `offer` 变量，就地改会让日志与返回值对不上）。
 *
 * Note: 为什么保留"有 lan 就出码"但必须显式标记 —— 见
 * `.agents/notes/implemented/2026-11-04-pairing-degradation-is-visible.md`
 */
export function markOfferLanOnly(offer: PairingOffer): PairingOffer {
  const payload = JSON.parse(offer.payload) as Record<string, unknown>
  // 只有局域网：`routes` 里不能还留着一个 `relay` —— 新版手机据此跳过换票，
  // 旧版手机本来就会先试 `lan`（这一格只是让"承诺"和"事实"对齐）。
  const routes = offer.routes.filter((route) => route !== 'relay')
  return {
    ...offer,
    lanOnly: true,
    routes,
    payload: JSON.stringify({ ...payload, lanOnly: true, routes }),
  }
}

export function createPairing(options: PairingOptions): Pairing {
  const now = options.now ?? (() => Date.now())
  const random = options.randomBytes ?? ((size: number) => nodeRandomBytes(size))
  const identify = options.deviceIdOf ?? deviceIdOf
  let current: {
    offerId: string
    codeHash: Buffer
    expiresAt: number
    candidate: string | null
    accepted: PairingAccepted | null
  } | null = null

  return {
    get pending() {
      return current !== null && current.expiresAt > now() && current.accepted === null
    },

    offer() {
      const offerId = base64url(random(PAIRING_CODE_BYTES))
      const code = base64url(random(PAIRING_CODE_BYTES))
      if (!TOKEN.test(offerId) || !TOKEN.test(code) || offerId === code) {
        throw new Error('配对随机源必须生成独立的邀请与秘密')
      }
      const expiresAt = now() + PAIRING_TTL_MS
      current = { offerId, codeHash: hash(code), expiresAt, candidate: null, accepted: null }
      const lanUrls = [...(options.lanUrls?.() ?? [])]
      // 码里有哪几条路：直连看地址、中转看**控制面**（不是配置）。
      const relayAvailable = options.relayAvailable?.() ?? true
      const routes: readonly PairingRoute[] = [
        ...(lanUrls.length === 0 ? [] : (['lan'] as const)),
        ...(relayAvailable ? (['relay'] as const) : []),
      ]
      return {
        offerId, code, expiresAt, lanUrls, lanOnly: false, routes,
        payload: JSON.stringify({
          v: PAIRING_VERSION,
          // **出码时求值**：电脑换 WiFi 后二维码带的是当前地址，
          // 用户不用回去改 yml 再重启（2026-10-17 真机踩到的坑）。
          relay: typeof options.relayUrl === 'function' ? options.relayUrl() : options.relayUrl,
          // 局域网直连地址：手机先拨这组，全拨不通才回落中转（见 `pairing-lan.ts`）。
          // **空就不写这一格** —— 老载荷形状照旧，手机按老路走。
          ...(lanUrls.length === 0 ? {} : { lan: lanUrls }),
          // **这张码能走哪几条路**（新版手机读；旧版忽略）。
          routes,
          pcId: options.pcId,
          pcPubEd: options.pcPubEd, pcPubDh: options.pcPubDh, offerId, code,
        }),
      }
    },

    allows(candidate) {
      if (!isPairingCandidate(candidate) || current === null || current.expiresAt <= now()
        || candidate.offerId !== current.offerId) return false
      return current.candidate === null || current.candidate === pairingHandshakeContext(options, candidate)
    },

    accept(request, candidate) {
      if (!isRequest(request) || !isPairingCandidate(candidate)) return { rejected: 'invalid' }
      if (current === null) return { rejected: 'consumed' }
      if (current.expiresAt <= now()) return { rejected: 'expired' }
      if (request.offerId !== current.offerId || candidate.offerId !== current.offerId
        || !timingSafeEqual(hash(request.code), current.codeHash)) return { rejected: 'mismatch' }

      const fingerprint = pairingHandshakeContext(options, candidate)
      if (current.accepted !== null) {
        return current.candidate === fingerprint ? current.accepted : { rejected: 'consumed' }
      }
      const pairingId = pairingIdOf(current.codeHash.toString('hex'))
      const accepted: PairingAccepted = {
        pairingId,
        expiresAt: current.expiresAt,
        sas: sasOf(options.pcPubEd, candidate.devPubEd),
        device: {
          devId: identify(candidate), name: candidate.name,
          edPubHex: candidate.devPubEd, dhPubHex: candidate.devPubDh,
          pairingId, pairedAt: now(),
        },
        ...(request.previousPairingId === undefined ? {} : { previousPairingId: request.previousPairingId }),
      }
      current.candidate = fingerprint
      current.accepted = accepted
      return accepted
    },
  }
}
