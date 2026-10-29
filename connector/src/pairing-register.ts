/**
 * 出码登记的网络调用（契约 §12.1 的"出码登记"）。
 *
 * 两件事值得单独成层：
 *
 * 1. **`ws://` → `http://` 的派生**：`relayUrl` 是 WSS 地址（连接层用它拨号），
 *    而登记是一个 HTTP POST。这一步写错的表现是"配对总是失败"，而日志里只有一条 fetch 错误 ——
 *    所以它要被测，而不是靠每次手改。
 * 2. **失败的形状**：非 2xx 与网络错误都要**抛**（出码核心据此拒绝出码）。
 *    静默成功会让操作者拿到一张配不上的二维码。
 *
 * 不重试：出码是操作者手动触发的一次动作，失败时他能立刻再点一次（文案里也这么写）。
 * 自动重试反而会在中转短暂不可用时给出一个"稍后才生效"的假象。
 */
import type { ChannelLogger } from './observability.js'
import { relayUrlOf } from './transport/relay-url.js'

export interface PairingRegistrarOptions {
  /**
   * 连接层用的 WSS 地址（配置里的 `relayUrl`）。
   *
   * 是**函数**：面板可以热改地址（`loader/volatile-update`），而登记打的是
   * "当前那台中转"的 HTTP 面 —— 存成字符串就会出现"连接已经换到新中转，
   * 出码却还登记到旧中转"（那张码手机扫了配不上）。
   */
  relayUrl: () => string
  allowInsecureLocal?: () => boolean
  /** 公网明文（自部署中转）：与手机侧 checkedRelayUri 的第二档同一判据。 */
  allowInsecurePublic?: () => boolean
  /**
   * 取连接器令牌。
   *
   * 是**函数而不是字符串**：令牌在凭据面里（§12.2），而 `readRelayToken` 有意不缓存 ——
   * 出码是低频人工动作，每次现读能让"操作者换了令牌"立刻生效；
   * 也避免了装配层为了一个只在出码时用到的值去安排初始化顺序。
   */
  tokenSource: () => Promise<string>
  /** 注入 `fetch` 以便测（装配层用全局的那个）。 */
  fetchImpl?: typeof fetch
  log?: ChannelLogger
}

/** `wss://host/path` → `https://host`（**丢掉路径**：HTTP 端点不在 WS 的那条路径上）。 */
export function httpBaseOf(
  relayUrl: string,
  allowInsecureLocal = false,
  allowInsecurePublic = false,
): string {
  const url = relayUrlOf(relayUrl, allowInsecureLocal, allowInsecurePublic)
  const protocol = url.protocol === 'wss:' ? 'https:' : url.protocol === 'ws:' ? 'http:' : url.protocol
  return `${protocol}//${url.host}`
}

export function createPairingRegistrar(
  options: PairingRegistrarOptions,
): (offerId: string) => Promise<void> {
  const doFetch = options.fetchImpl ?? fetch
  const endpointOf = (): string =>
    `${httpBaseOf(
      options.relayUrl(),
      options.allowInsecureLocal?.() ?? false,
      options.allowInsecurePublic?.() ?? false,
    )}/pairing/register`

  return async (offerId) => {
    const endpoint = endpointOf()
    const token = await options.tokenSource()
    const response = await doFetch(endpoint, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ v: 2, offerId }),
    })
    if (!response.ok) {
      // 把状态码带上：401 是"令牌不对"、409 是"配对登记不可用"，两者的下一步动作不同。
      const detail = await response.text().catch(() => '')
      throw new Error(`配对登记被拒（HTTP ${response.status}）${detail === '' ? '' : `：${detail.slice(0, 200)}`}`)
    }
    options.log?.debug('配对登记成功', { endpoint })
  }
}
