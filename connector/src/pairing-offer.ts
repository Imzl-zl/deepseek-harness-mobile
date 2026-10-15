/**
 * 出码入口的核心（契约 §12.1 第 1 步）。
 *
 * 顺序里藏着一条判断：**先把 `offerId` 登记到中转，再把二维码给操作者**。
 * 反过来的话（先出码、登记失败就只记个日志），操作者会拿到一张"扫了也配不上"的二维码 ——
 * 而手机那侧的失败表现是"配对码不对/请重新出码"，人会以为是手机的问题，
 * 真因却在电脑侧的一条日志里。所以：**登记不成，就不出码**。
 *
 * 命令的接线（`ctx.commands.register`）留在装配层；这里只管"能不能出码、出什么"，
 * 于是它可以脱离 DSH 与网络测（登记做成端口）。
 */
import type { ChannelLogger } from './observability.js'
import { PAIRING_TTL_MS, type Pairing, type PairingOffer } from './pairing.js'

export interface PairingOfferDeps {
  pairing: Pairing
  /**
   * 把 `offerId` 登记到中转（§12.1 的"出码登记"）。
   *
   * **失败要抛**：调用方据此拒绝出码。吞掉它等于发出一张注定配不上的二维码。
   */
  register: (offerId: string) => Promise<void>
  log?: ChannelLogger
}

/** 命令结果（与 DSH 的 `CommandResult` 同形；这里不 import 它，免得这一层依赖 DSH）。 */
export type OfferResult = { kind: 'success'; text: string } | { kind: 'error'; text: string }

/**
 * 斜杠命令那一侧：把出码核心的结果翻译成 `CommandResult`。
 *
 * 与管理页面**共用 `issuePairingOffer`**（"登记不成就不出码"只有一条规则），
 * 差别只在失败怎么呈现：命令只能回文本，所以 catch 成 `{kind:'error'}`；
 * 管理页面那边让它抛，由 Connection 的桥接归一成 500 + 消息。
 */
export async function offerForScanning(deps: PairingOfferDeps): Promise<OfferResult> {
  try {
    const offer = await issuePairingOffer(deps)
    const minutes = Math.round(PAIRING_TTL_MS / 60_000)
    return {
      kind: 'success',
      text: `手机扫码配对（${minutes} 分钟内有效，一次性）：\n${offer.payload}`,
    }
  } catch (error) {
    return { kind: 'error', text: error instanceof Error ? error.message : String(error) }
  }
}

/**
 * 出码核心：**先登记到中转，再交出 offer**。
 *
 * 斜杠命令（`offerForScanning`）与管理页面（`admin/`）共用这一个判断 ——
 * "登记不成就不出码"是一条规则，写两份就会有一处先腐化。
 *
 * @returns 已登记的 offer（含 `payload` 与 `expiresAt`）。
 * @throws 登记失败：调用方各自把失败呈现给它的用户（命令回 error 文本，页面回 500）。
 */
export async function issuePairingOffer(deps: PairingOfferDeps): Promise<PairingOffer> {
  const offer = deps.pairing.offer()
  try {
    await deps.register(offer.offerId)
  } catch (error) {
    deps.log?.warn('配对登记失败：拒绝出码（否则会给出扫了也配不上的二维码）', error)
    throw new Error(
      '没能把这次配对登记到中转：请检查中转是否在运行、连接器令牌是否有效。这次没有出码，重新执行即可。',
    )
  }
  deps.log?.info(`已出码并登记到中转（${Math.round((offer.expiresAt - Date.now()) / 1000)} 秒内有效）`)
  return offer
}
