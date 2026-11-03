/**
 * 局域网直连配对的**请求形状**：二维码里的 `lan` 地址 + 升级请求上的 `?pair=`。
 *
 * ## 它解决什么
 *
 * 配对 v2 原来只有一条路：手机拿着 `offerId` 去中转换票，中转再告诉连接器"有候选要连进来"。
 * 同一局域网里这两件事**都不需要服务器** —— 连接器自己持有 offer（`pairing.ts` 的
 * `offer()` / `allows()`），也自己在 `0.0.0.0:8790` 上监听（`transport/listener.ts`）。
 * 所以二维码多给一组 `lan` 地址，手机直接拨过来，握手与提交帧一个都不用改。
 *
 * ## 候选身份为什么在**请求**里，而不是握手帧里
 *
 * 握手的 `hello` 只带 `ephPubA` / `devId` / `nonceA`（`protocol/handshake-frames.ts:5`），
 * 而电脑侧在 `hello` 那一刻就要用**对端的静态公钥**验签、派生会话密钥
 * （`protocol/handshake-driver.ts:174` 的 `peerOf(hello.devId)`）。中转那条路上，
 * 这对公钥是中转在换票时收到、再经控制面 `binding.candidate` 交过来的；局域网上
 * 没有中转，只能由手机在**建连请求**里自报。
 *
 * 自报不等于可信：候选公钥进配对握手上下文（`pairingHandshakeContext`），而那段
 * 上下文被签名进 transcript —— 换掉任何一个字节，两侧算出的密钥就不同，握手在验签处
 * 失败。真正的授权仍然是二维码里的 `code`（`pairing.accept` 先验秘密才 accept）。
 *
 * ## 为什么是 query，不是升级头
 *
 * 这一跳要能被**任何** WS 客户端拨通（真机、`node` 替身、将来的其它端），而自定义
 * 升级头在反代后面会被吞掉一部分；query 是 WebSocket 规范里唯一必然到达服务端的位置
 * （`ws` 的 `connection(socket, request)` 给的就是 `request.url`）。候选里只有公钥与
 * 设备名 —— 都不是秘密，进日志的代价可以接受。
 *
 * Note: 为什么候选在请求里而不是握手帧里、为什么是 query 不是升级头 —— 见
 * `.agents/notes/implemented/2026-11-03-pairing-without-relay.md`
 */
import { isPairingCandidate, type PairingCandidate } from './pairing.js'

/** 触发参数：`?pair=<offerId>`。**它在不在**决定这条连接按配对候选建。 */
export const PAIR_QUERY_KEY = 'pair'
/** 候选身份（base64url 的无填充 JSON，形状同换票请求体）。 */
export const CANDIDATE_QUERY_KEY = 'cand'

/** 一次升级请求里与配对有关的部分。 */
export interface PairingRequestQuery {
  /** `?pair=` 的原文；`undefined` = 这不是一次配对连接（普通直连）。 */
  readonly offerId: string | undefined
  /**
   * 解析成功的候选。
   *
   * `offerId` 有值而它是 `undefined` = **请求形状不对**（缺 `cand`、解不开、
   * 或与 `?pair=` 不是同一个邀请）。调用方按普通连接放行即可 —— 握手会在
   * `peerOf` 处判成 `protocol/not-paired`，而**不要**在这里静默拼一个候选出来。
   */
  readonly candidate: PairingCandidate | undefined
}

/**
 * 读升级请求（`request.url`，形如 `/?pair=…&cand=…`）。
 *
 * **不抛**：一个畸形请求不该把监听面带走。判据只有一条 —— 解析不出来就当没有候选，
 * 由握手给出 `protocol/not-paired`（与"未配对设备"同一个出口）。
 */
export function readPairingRequest(requestUrl: string): PairingRequestQuery {
  const url = parseRequestUrl(requestUrl)
  if (url === null) return { offerId: undefined, candidate: undefined }
  const offerId = url.searchParams.get(PAIR_QUERY_KEY) ?? undefined
  if (offerId === undefined) return { offerId: undefined, candidate: undefined }
  const encoded = url.searchParams.get(CANDIDATE_QUERY_KEY)
  if (encoded === null || encoded === '') return { offerId, candidate: undefined }
  const candidate = decodeCandidate(encoded)
  // `?pair=` 与候选自报的邀请必须是**同一个**：不一致说明请求被拼错了，
  // 而"以其中一个为准"会让人以为它验过另一个。
  if (candidate === undefined || candidate.offerId !== offerId) {
    return { offerId, candidate: undefined }
  }
  return { offerId, candidate }
}

/**
 * 手机该拨的地址：`<lan>/?pair=<offerId>&cand=<候选>`。
 *
 * 与手机侧 `app/lib/core/pairing.dart` 的 `pairingDialUrl` **逐字对应** ——
 * 两边各写一份格式的话，错的那一侧只会表现为"握手超时"。
 */
export function pairingDialUrl(lanUrl: string, candidate: PairingCandidate): string {
  const url = new URL(lanUrl)
  url.searchParams.set(PAIR_QUERY_KEY, candidate.offerId)
  url.searchParams.set(CANDIDATE_QUERY_KEY, encodeCandidate(candidate))
  return url.toString()
}

/** 候选 → query 里的那个字符串（无填充 base64url 的 JSON）。 */
export function encodeCandidate(candidate: PairingCandidate): string {
  return Buffer.from(JSON.stringify(candidate), 'utf8').toString('base64url')
}

/** query → 候选；形状不合法回 `undefined`（**不猜**）。 */
export function decodeCandidate(encoded: string): PairingCandidate | undefined {
  let parsed: unknown
  try {
    parsed = JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8'))
  } catch {
    return undefined
  }
  return isPairingCandidate(parsed) ? parsed : undefined
}

/** `request.url` 只有路径与查询串，没有 scheme/host —— 补一个占位基址再交给 `URL`。 */
function parseRequestUrl(requestUrl: string): URL | null {
  try {
    return new URL(requestUrl, 'http://listener.invalid')
  } catch {
    return null
  }
}
