/**
 * 配对端点（契约 §12.1 的第 3 步：**电脑侧校验并落设备记录**）。
 *
 * 单独成一层是为了让**产品装配与测试用同一处逻辑**：这一段是安全边界
 * （"谁成为设备"由它决定），两边各写一遍必然会分叉 —— 而分叉的表现是
 * "测试里配对成功、真机上不行"（或反过来），最难查的一种。
 *
 * ## 三条纪律
 *
 * 1. **从不抛**：配对失败不是协议错误，而是一件**要告诉手机的事**
 *    （"码过期了"要能显示出来）。所以所有失败都变成 `pair-ack` 里的原因；
 *    连"载荷不是 JSON"也只回一个 `bad-request`，**不关连接**（§9：结构化错误不关连接）。
 * 2. **先落设备行再回执**：回执是"你可以用这个身份握手了"的意思；先回执后落行的话，
 *    手机可能立刻握手，而那时 `peerOf(devId)` 还查不到 —— 表现为"配对成功但连不上"。
 * 3. **落行失败要如实回执**：那一行没写成就不是配对成功，不能报 `ok`。
 */
import type { ChannelLogger } from './observability.js'
import type { Pairing, PairingRequest } from './pairing.js'

/** 回执里的结果（两端约定的一种；`reason` 直接给用户看）。 */
export type PairingReply =
  | { ok: true; devId: string; sas: string }
  | { ok: false; reason: string }

/** 设备行（与 `store/` 的 `devices` 表同形，但只留这一层真正要写的字段）。 */
export interface PairedDeviceRow {
  name: string
  edPubHex: string
  dhPubHex: string
  pairingId: string
  pairedAt: number
}

export interface PairingEndpointOptions {
  pairing: Pairing
  /** 落设备行（`store/` 的 `devices` 表）。 */
  putDevice: (devId: string, row: PairedDeviceRow) => Promise<void>
  /** 把回执发出去（明文 `pair-ack`）。 */
  reply: (frame: { id: string; payload: PairingReply }) => void
  log?: ChannelLogger
}

export interface PairingEndpoint {
  /** 处理一个入站 `pair` 帧。**从不抛**。 */
  handle(frame: { id: string; box: string }): Promise<void>
}

/** 把失败原因翻成用户看得懂的话（手机侧直接显示，不必再维护一张映射表）。 */
const REASON_TEXT: Record<string, string> = {
  expired: '配对码已过期，请在电脑上重新出码',
  mismatch: '配对码不对，请核对后重试',
  consumed: '这个配对码已经用过了，请在电脑上重新出码',
}

export function createPairingEndpoint(options: PairingEndpointOptions): PairingEndpoint {
  const { pairing, putDevice, reply, log } = options

  const fail = (id: string, reason: string): void => {
    log?.warn(`配对失败（${reason}）`)
    reply({ id, payload: { ok: false, reason: REASON_TEXT[reason] ?? '配对失败' } })
  }

  return {
    async handle(frame) {
      let request: PairingRequest
      try {
        const parsed = JSON.parse(frame.box) as unknown
        if (typeof parsed !== 'object' || parsed === null) throw new Error('不是对象')
        request = parsed as PairingRequest
      } catch (error) {
        // 载荷坏掉不是协议错误：回一个原因、**不关连接**（手机要能显示"格式不对"）。
        log?.warn('配对载荷不是合法 JSON', error)
        reply({ id: frame.id, payload: { ok: false, reason: '配对请求格式不对' } })
        return
      }

      const accepted = pairing.accept(request)
      if ('rejected' in accepted) {
        fail(frame.id, accepted.rejected)
        return
      }

      try {
        // **先落行再回执**：反过来会出现"配对成功但连不上"（手机立刻握手时设备行还没写）。
        await putDevice(accepted.device.devId, {
          name: accepted.device.name,
          edPubHex: accepted.device.edPubHex,
          dhPubHex: accepted.device.dhPubHex,
          pairingId: accepted.device.pairingId,
          pairedAt: accepted.device.pairedAt,
        })
      } catch (error) {
        // 行没写成就不是配对成功 —— 报 ok 会让手机拿着一个不存在的身份去握手。
        log?.warn('配对成功但设备行写入失败', error)
        reply({ id: frame.id, payload: { ok: false, reason: '电脑侧没能保存这台设备，请重试' } })
        return
      }

      log?.info(`已配对设备 ${accepted.device.devId}（SAS ${accepted.sas}）`)
      reply({ id: frame.id, payload: { ok: true, devId: accepted.device.devId, sas: accepted.sas } })
    },
  }
}
