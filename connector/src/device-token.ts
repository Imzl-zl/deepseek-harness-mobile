/**
 * 设备令牌的签发（契约 §12.1 第 3 步：**电脑侧签发**，中转只存摘要）。
 *
 * ## 为什么不由中转签发
 *
 * 中转是转发器，它**不该有签名身份**，也不该能凭空造出"我是某台设备"的凭据。
 * 而身份判定本来就是电脑侧做的（契约原话："身份判定由电脑侧做，中转只转发与记账"），
 * 所以凭据由判定方签发、把**摘要**交给中转 —— 这样中转即使被完全读穿，
 * 它手里的东西也不能用来冒充任何一台设备（§12.2 的 `token_hash`）。
 *
 * ## 两个令牌
 *
 * | 令牌 | 用途 | 寿命 |
 * |---|---|---|
 * | `deviceToken` | 换一次性票（每次重连都用它） | 长期 |
 * | `refreshToken` | 轮换设备令牌 | 长期 |
 *
 * 规格与配对码、连接器令牌、一次性票**同一档**：128 位随机、base64url 无填充
 * （22 字符）。它不是"长期所以可以短一点"——随机性是它唯一的防线。
 *
 * **轮换流程本期不做**（决定见 `.agents/notes/implemented/2026-10-09-token-and-scope-decisions.md`）：
 * 设备令牌长期有效，轮换等于重新扫码。因此**刷新令牌的摘要不再上报中转**——
 * 中转多存一份没有人读的摘要，只会让人以为轮换已经实现；刷新令牌仍是签给手机的
 * **本机凭据**（进系统安全存储），等真要轮换时再加回落点。
 *
 * Note: 为什么由连接器签发而不是中转 —— 见
 * `.agents/notes/implemented/2026-10-02-pairing-bootstrap-and-device-binding.md`
 */
import { createHash, randomBytes as nodeRandomBytes } from 'node:crypto'

/** 令牌长度（16 字节 = 128 位；与配对码、连接器令牌、一次性票同规格）。 */
export const DEVICE_TOKEN_BYTES = 16

export interface IssuedDeviceTokens {
  /** **只在签发这一刻存在**：进明文回执，不落盘、不进日志。 */
  deviceToken: string
  /** 刷新令牌。同上。 */
  refreshToken: string
}

export type RandomBytes = (size: number) => Uint8Array

/** 签发一对令牌（设备令牌 + 刷新令牌）。随机源可注入，便于测试确定化。 */
export function issueDeviceTokens(
  random: RandomBytes = (size) => nodeRandomBytes(size),
): IssuedDeviceTokens {
  return {
    deviceToken: Buffer.from(random(DEVICE_TOKEN_BYTES)).toString('base64url'),
    refreshToken: Buffer.from(random(DEVICE_TOKEN_BYTES)).toString('base64url'),
  }
}

/**
 * `sha256(令牌)` 的十六进制 —— **与中转 `digest-auth.ts` 的 `digestOf` 同一个算式**。
 *
 * 两端必须逐字一致：算错的表现是"配对成功、之后永远 401"，而双方各自看起来都正常。
 * 所以它只该有这样一处定义，且与中转那一处对齐（`relay/src/digest-auth.ts`）。
 */
export function tokenHashOf(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex')
}
