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
import { PAIRING_TTL_MS, type Pairing } from './pairing.js'

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

export async function offerForScanning(deps: PairingOfferDeps): Promise<OfferResult> {
  const offer = deps.pairing.offer()
  try {
    await deps.register(offer.offerId)
  } catch (error) {
    deps.log?.warn('配对登记失败：拒绝出码（否则会给出扫了也配不上的二维码）', error)
    return {
      kind: 'error',
      text: '没能把这次配对登记到中转：请检查中转是否在运行、连接器令牌是否有效。这次没有出码，重新执行即可。',
    }
  }
  deps.log?.info(`已出码并登记到中转（${Math.round((offer.expiresAt - Date.now()) / 1000)} 秒内有效）`)
  // 码**只在这里出现**：它进操作者眼前的二维码，不落盘、不进日志。
  // 有效期**从常量算**，不写死数字：写死的话，改 `PAIRING_TTL_MS` 会留下一句撒谎的提示
  //（操作者按它安排时间，而码已经过期了）。
  const minutes = Math.round(PAIRING_TTL_MS / 60_000)
  return { kind: 'success', text: `手机扫码配对（${minutes} 分钟内有效，一次性）：\n${offer.payload}` }
}
