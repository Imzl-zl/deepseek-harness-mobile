/**
 * 出码入口的核心（契约 §12.1 第 1 步）。
 *
 * ## 顺序里藏着一条判断
 *
 * **先把 `offerId` 登记到中转，再把二维码给操作者**。反过来的话（先出码、登记失败就只记个日志），
 * 操作者会拿到一张"扫了也配不上"的二维码 —— 而手机那侧的失败表现是"配对码不对/请重新出码"，
 * 人会以为是手机的问题，真因却在电脑侧的一条日志里。
 *
 * ## 但这条判断只在"只有中转"时成立
 *
 * 载荷里有局域网直连地址（`lan`）时，手机根本不需要中转保管这次 offer，也不需要中转转告
 * "有候选要连进来" —— 它直接拨电脑，电脑自己持有 offer。于是登记失败**不再**意味着
 * "这张码配不上"，只意味着"跨网那条路没了"：出码照出，**载荷标 `lanOnly`**，
 * 命令文案与插件面板同时说出来 —— 降级不再只进日志。
 *
 * 反过来（有 lan 就跳过登记）是另一种错误：中转可用时，登记能让**同一张码**在跨网
 * 场景也能用（手机不在同一 WiFi 时拨中转）。所以顺序是"先试着登记，失败再看有没有退路"。
 *
 * 命令的接线（`ctx.commands.register`）留在装配层；这里只管"能不能出码、出什么"，
 * 于是它可以脱离 DSH 与网络测（登记做成端口）。
 *
 * **2026-11-24 起没有斜杠命令了**：面板是唯一入口（用户原话「谁在会话生成？
 * 我肯定在插件界面啊」）。原来命令那条路绕过 {@link planPairingOffer}，
 * 同一件事有两个结论；`offerForScanning` 随之删除（没有第二个调用方）。
 *
 * Note: 为什么"登记失败"只在没有局域网退路时才拒绝出码 —— 见
 * `.agents/notes/implemented/2026-11-03-pairing-without-relay.md`；
 * 为什么降级必须写进载荷并让三处说出来 —— 见
 * `.agents/notes/implemented/2026-11-04-pairing-degradation-is-visible.md`。
 */
import type { ChannelLogger } from './observability.js'
import { markOfferLanOnly, type Pairing, type PairingOffer } from './pairing.js'

export interface PairingOfferDeps {
  pairing: Pairing
  /**
   * 把 `offerId` 登记到中转（§12.1 的"出码登记"）。
   *
   * **失败要抛**：调用方据此判断这张码还有没有退路（有 `lan` 就降级，没有就拒绝出码）。
   */
  register: (offerId: string) => Promise<void>
  /**
   * 这张码要不要**带中转那条路**（由装配层按能力给：中转控制面连上了才是 `true`）。
   *
   * `false` = 这条腿此刻不存在：**不登记**（没人会去换票），载荷里只留局域网。
   * 本函数只负责"别登记、别承诺中转"，**不判断直连是否可用** —— 那是
   * {@link planPairingOffer} 的判据。
   */
  withRelay?: boolean
  log?: ChannelLogger
}

/**
 * 出码那一刻这台电脑的**能力**：哪几条腿能写进码。
 *
 * 判据与面板、手机无关，只有两条事实：直连有没有一条**可上报的地址**（监听在跑
 * 不等于有地址），中转控制面有没有 `connected`（配了地址不等于连上）。
 */
export interface PairingCapacity {
  /** 直连那条腿能不能进码（监听在跑 **且** 选得出一个可上报的主地址）。 */
  readonly lanAvailable: boolean
  /** 中转控制面此刻连上了吗。 */
  readonly relayConnected: boolean
  /**
   * `lanAvailable === false` 时的人话原因。
   *
   * **必须区分两档**：监听没开，和"监听开着但没有可上报的主地址"（默认路由拿不到、
   * 主地址被用户隐藏）。混成一句"直连没开"会让明明开着监听的人无从下手 ——
   * 2026-11-17 用户原话："我明明开着直连，它说没开"。
   */
  readonly lanReason?: string
}

/**
 * 这张码能不能出、要不要带中转 —— **出码的唯一判据**（斜杠命令与管理面板共用）。
 *
 * 2026-11-17 起没有"这张码给谁用"这一档：码里写哪几条路只由此刻的能力决定，
 * 选哪条是手机上的事。两条都没有时抛错，文案分别说清缺的是哪条、为什么。
 *
 * Note: 为什么删掉那个二选一、为什么 `lanReason` 必须分两档 —— 见
 * `.agents/notes/implemented/2026-11-17-offer-carries-what-is-alive.md`。
 */
export function planPairingOffer(capacity: PairingCapacity): { readonly withRelay: boolean } {
  if (!capacity.lanAvailable && !capacity.relayConnected) {
    const lanWhy = capacity.lanReason ?? '直连不可用'
    throw new Error(
      `无法生成配对码：${lanWhy}；中转未连接。请先启动直连监听或中转拨号。`,
    )
  }
  return { withRelay: capacity.relayConnected }
}

/**
 * 异常 → 一句能读的原因，嵌进给人看的失败文案里。
 *
 * 截断是为了不让中转的应答体把整条提示淹掉（那条信息仍然完整留在 warn 日志里）。
 */
const causeText = (error: unknown): string => {
  const message = error instanceof Error ? error.message : String(error)
  return message.replace(/\s+/g, ' ').trim().slice(0, 180)
}

/**
 * 出码核心：**先登记到中转；登记失败时看有没有局域网退路**。
 *
 * 插件面板（`admin/`）是唯一调用方 —— 这条判断只有一处，写两份就会有一处先腐化。
 *
 * @returns 可用的 offer（含 `payload` 与 `expiresAt`）。
 * @throws 登记失败**且**没有局域网地址：调用方各自把失败呈现给它的用户
 *   （命令回 error 文本，页面回 500）。
 */
export async function issuePairingOffer(deps: PairingOfferDeps): Promise<PairingOffer> {
  const offer = deps.pairing.offer()
  // 中转这条腿此刻不存在（用户选了"同一 WiFi"，或控制面没连上）：**不登记**。
  // 登记是给"跨网换票"用的，而这张码不会去换 —— 以前无条件登记，
  // 于是二维码会承诺一条已经死掉的路（2026-11-13 修）。
  if (deps.withRelay === false || !offer.routes.includes('relay')) {
    deps.log?.info(
      `已出码：只含局域网地址（${offer.lanUrls.length} 个，未登记中转）`,
    )
    return markOfferLanOnly(offer)
  }
  try {
    await deps.register(offer.offerId)
  } catch (error) {
    if (offer.lanUrls.length === 0) {
      deps.log?.warn('配对登记失败：拒绝出码（否则会给出扫了也配不上的二维码）', error)
      // **把中转的原话带上**（状态码 + 应答体，见 `pairing-register.ts`）：只写
      // "检查中转是否在运行、令牌是否有效"会把人引向错误的方向 —— 2026-11-03 那
      // 次真因是中转按另一个 id 找电脑（409），字面却像"你没启动中转"。
      throw new Error(
        `配对登记失败（${causeText(error)}）。未生成二维码：当前没有可用的局域网地址。`
        + '请启动直连监听后重试，或按上述原因修复中转。',
      )
    }
    // 有局域网地址 = 手机拨得通电脑，登记只影响"跨网也能扫同一张码"。
    // **降级必须可见**：载荷带上 `lanOnly`，命令与面板把它说出来 —— 以前这条只进 warn 日志，
    // 用户出门才发现"这张码配不上"。
    const degraded = markOfferLanOnly(offer)
    deps.log?.warn(
      `配对登记失败：这张码只能走局域网直连（${offer.lanUrls.length} 个地址仍在二维码里）`
      + ' —— 已在载荷里标 lanOnly，手机与面板都会显式提示',
      error,
    )
    return degraded
  }
  deps.log?.info(
    `已出码并登记到中转（${Math.round((offer.expiresAt - Date.now()) / 1000)} 秒内有效`
    + `${offer.lanUrls.length === 0 ? '' : `；另有 ${offer.lanUrls.length} 个局域网地址`}）`,
  )
  return offer
}
