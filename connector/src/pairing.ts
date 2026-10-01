/**
 * 配对（契约 §12.1，**电脑侧那一半**）。
 *
 * 流程只有三步，而三步的顺序就是它的安全性：
 *
 * 1. **电脑侧出码**：生成一次性配对码（16 字节 base64url，5 分钟有效），把
 *    `{ relay, pcPubEd, pcPubDh, code }` 编成二维码。**只存哈希**，不存码本身 ——
 *    它是 bearer 凭据，存明文等于"谁读到库谁能配对"。
 * 2. **手机扫码后带码回来**：`{ code, devPubEd, devPubDh, name }` 经中转转给电脑侧
 *    （§12.1 第 2 步：**中转只转发与记账**）。
 * 3. **电脑侧校验并落设备记录**：码要对、没过期、没用过；然后写 `devices` 行
 *    （含由配对码算出的 `pairingId`），并把**短指纹 SAS** 回给两端做带外核对。
 *
 * ## 两个"只在电脑侧做"的判断
 *
 * - **身份判定在电脑侧**（§12.1 第 3 步的原话）。中转不参与判断，它只转发与记账；
 *   所以本文件不需要信任任何中转提供的字段。
 * - **`pairingId` 由配对码派生**（§12.1 的定义，参数已写进契约）：手机拿到二维码就能算出同一个值，
 *   电脑侧不必额外传。它随后参与握手密钥派生的 `info`（§4.1）——**两端算得不一样就握不上手**，
 *   所以派生参数必须逐字一致，不能各自发挥。
 *
 * ## 一次性是怎么保证的
 *
 * 内存里的 pending 记录 + 消费即销毁（`consumed`）。进程重启会让 pending 消失 ——
 * 那时二维码也一并作废（操作者重新出码即可），而不是留下一个无法判定用没用过的码。
 * 这比"落盘 + 靠过期时间兜"更安全：**没有"可能已被用过"的中间态**。
 */
import { createHash, hkdfSync, randomBytes as nodeRandomBytes } from 'node:crypto'

/** 配对码长度（16 字节 = 128 位；与 `requestId` 同规格，两者都是 bearer 凭据）。 */
export const PAIRING_CODE_BYTES = 16
/** 配对码有效期（契约 §12.1：5 分钟）。 */
export const PAIRING_TTL_MS = 5 * 60 * 1000
/** `pairingId` 派生用的域名分隔串（契约 §12.1，两端逐字一致）。 */
export const PAIRING_ID_INFO = 'dsh-mobile/v1/pairing'
/** 短指纹（SAS）的域名分隔串（契约 §12.1）。 */
export const SAS_INFO = 'dsh-mobile/v1/sas'

export interface PairingOffer {
  /** 只在出码那一刻存在于内存里；**不落盘**。 */
  readonly code: string
  readonly expiresAt: number
  /** 二维码里那段字符串（渲染成图形是实现方的事）。 */
  readonly payload: string
  /** 码的哈希（落盘只落它）。 */
  readonly codeHash: string
}

export interface PairingRequest {
  readonly code: string
  readonly devPubEd: string
  readonly devPubDh: string
  readonly name: string
}

export interface PairingAccepted {
  readonly pairingId: string
  readonly device: {
    readonly devId: string
    readonly name: string
    readonly edPubHex: string
    readonly dhPubHex: string
    readonly pairingId: string
    readonly pairedAt: number
  }
  /** 6 位数字，两端各自算出同一个值，由用户对照（带外核对）。 */
  readonly sas: string
}

/** 配对失败的原因。分开是为了让调用方（与用户）能说清到底哪一步不对。 */
export type PairingRejection = 'expired' | 'mismatch' | 'consumed'

export interface PairingOptions {
  /** 中转地址（写进二维码）。 */
  relayUrl: string
  pcPubEd: string
  pcPubDh: string
  now?: () => number
  randomBytes?: (size: number) => Uint8Array
  /** 设备 id 怎么来（默认：设备公钥的哈希前 16 字节 base64url —— 同一把公钥重配得到同一个 id）。 */
  deviceIdOf?: (request: PairingRequest) => string
}

export interface Pairing {
  /** 出一次码（这一步会覆盖上一次未使用的码：**永远只有一个待用码**）。 */
  offer(): PairingOffer
  /**
   * 校验手机带回来的配对请求。
   *
   * @returns 成功给出 `pairingId`、设备行与 SAS；失败给出原因（三种分得很清）。
   */
  accept(request: PairingRequest): PairingAccepted | { rejected: PairingRejection }
  /** 当前有没有待用的码（自检与测试用）。 */
  readonly pending: boolean
}

const base64url = (bytes: Uint8Array | Buffer): string => Buffer.from(bytes).toString('base64url')
const sha256Hex = (text: string): string => createHash('sha256').update(text, 'utf8').digest('hex')

/**
 * 由配对码派生 `pairingId`（契约 §12.1 的固定定义）。
 *
 * 用 HKDF 而不是裸哈希：**域名分隔**（`info`）让这一个 128 位秘密可以安全地派生出多个用途的
 * 输出而不互相牵连 —— 这里只要一个，但参数与密钥派生（§4.1）保持同一种做法，
 * 免得将来有人顺手把两个用途的输出互换。
 */
export function pairingIdOf(code: string): string {
  const derived = hkdfSync('sha256', Buffer.from(code, 'utf8'), Buffer.alloc(0), PAIRING_ID_INFO, 32)
  return base64url(Buffer.from(derived))
}

/**
 * 短指纹（SAS）：`sha256(info|pcPubEd|devPubEd)` 前 4 字节 mod 10^6，补零成 6 位。
 *
 * 用**公钥**而不是密钥材料：配对还没完成时就得能显示，而公钥本来就是要给对方的东西。
 */
export function sasOf(pcPubEd: string, devPubEd: string): string {
  const digest = createHash('sha256')
    .update(`${SAS_INFO}|${pcPubEd}|${devPubEd}`, 'utf8')
    .digest()
  const value = digest.readUInt32BE(0) % 1_000_000
  return String(value).padStart(6, '0')
}

export function createPairing(options: PairingOptions): Pairing {
  const now = options.now ?? (() => Date.now())
  const random = options.randomBytes ?? ((size: number) => nodeRandomBytes(size))
  const deviceIdOf =
    options.deviceIdOf ??
    ((request: PairingRequest) => base64url(createHash('sha256').update(request.devPubDh, 'utf8').digest().subarray(0, 16)))

  /** 当前待用的码：只留哈希 + 截止时间；**码本身不保留**（出码那一刻返回给调用方就够了）。 */
  let pending: { codeHash: string; expiresAt: number } | null = null

  return {
    get pending() {
      return pending !== null && pending.expiresAt > now()
    },

    offer() {
      const code = base64url(random(PAIRING_CODE_BYTES))
      const expiresAt = now() + PAIRING_TTL_MS
      pending = { codeHash: sha256Hex(code), expiresAt }
      return {
        code,
        expiresAt,
        codeHash: pending.codeHash,
        payload: JSON.stringify({
          v: 1,
          relay: options.relayUrl,
          pcPubEd: options.pcPubEd,
          pcPubDh: options.pcPubDh,
          code,
        }),
      }
    },

    accept(request) {
      if (pending === null) return { rejected: 'consumed' }
      if (pending.expiresAt <= now()) {
        // 过期即作废：**不**留一个"可能还能用"的码。
        pending = null
        return { rejected: 'expired' }
      }
      if (sha256Hex(request.code) !== pending.codeHash) return { rejected: 'mismatch' }

      // 一次性：**先消费再落记录**。反过来的话，落记录失败会留下一个"用过了但没配上"的码，
      // 而操作者只能重新出码 —— 那还不如让它当场失效。
      pending = null

      const pairingId = pairingIdOf(request.code)
      const devId = deviceIdOf(request)
      const at = now()
      return {
        pairingId,
        sas: sasOf(options.pcPubEd, request.devPubEd),
        device: {
          devId,
          name: request.name,
          edPubHex: request.devPubEd,
          dhPubHex: request.devPubDh,
          pairingId,
          pairedAt: at,
        },
      }
    },
  }
}
