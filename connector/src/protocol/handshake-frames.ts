/**
 * 握手三帧的组装、解析与 transcript 拼接（契约 §4.1）。
 *
 * ```text
 * 手机 → 电脑   hello     { box: { ephPubA(32B), devId, nonceA(32B) } }
 * 电脑 → 手机   hello-ack { box: { ephPubB(32B), pcId,  nonceB(32B), sigB } }
 * 手机 → 电脑   confirm   { box: { sigA, transcriptHash[0..8) } }
 * ```
 *
 * ## transcript 为什么从字段拼、而不是拼两帧 box
 *
 * `sigB` 就在 hello-ack 的 `box` 里，而 transcript 又要被 `sigB` 签 —— 拼 box 等于
 * 「签一段包含自己签名的字节」，是循环定义，不存在自洽取值（实测：用占位签名算
 * transcript 再回填，对端拿真实帧必然验不过）。所以被签的是**除签名外的字段**序列：
 *
 * ```text
 * dsh-mobile/v1|hello|ephPubA|devId|nonceA|hello-ack|ephPubB|pcId|nonceB
 * ```
 *
 * 握手的 `box` 只是编码容器、不是保密手段（`frame.ts` 的 `seal` 是可逆占位），
 * 所以把签名留在箱内不损失保密性；这一改动只修定义的自洽性。
 *
 * ## 校验在编解码两侧对称
 *
 * `encode*` 与 `parse*` 走**同一组**校验函数。只校验一侧会让坏值在本地被放行、
 * 到对端才炸 —— 而那时的错误信息指向对端，不是生产坏值的那一侧。
 */
import { ProtocolError } from './errors.js'
import { ID_PATTERN, seal, unseal } from './frame.js'

const HEX32 = 64
const HEX64 = 128
const HEX8 = 16

/** transcript 的固定前缀。改动它等于改协议版本。 */
export const TRANSCRIPT_LABEL = 'dsh-mobile/v1'

export interface HelloFields {
  ephPubA: string
  devId: string
  nonceA: string
}

export interface HelloAckFields {
  ephPubB: string
  pcId: string
  nonceB: string
}

export interface ConfirmFields {
  sigA: string
  transcriptHash: string
}

/**
 * 两个端点必须算出**同一段字节**（§4.1）。顺序是协议的一部分：
 * 换顺序不会报错，只会让两侧算出不同的 transcript —— 于是签名验不过，
 * 而错误信息会说是「公钥被替换」。
 */
export function transcriptFromFields(hello: HelloFields, ack: HelloAckFields): Buffer {
  return Buffer.from(
    [
      TRANSCRIPT_LABEL,
      'hello',
      hello.ephPubA,
      hello.devId,
      hello.nonceA,
      'hello-ack',
      ack.ephPubB,
      ack.pcId,
      ack.nonceB,
    ].join('|'),
    'utf8',
  )
}

function hex(value: unknown, field: string, length: number): string {
  if (typeof value !== 'string' || value.length !== length || !/^[0-9a-f]+$/i.test(value)) {
    throw new ProtocolError(
      'protocol/bad-frame',
      `${field} 必须是 ${length / 2} 字节的十六进制`,
    )
  }
  return value
}

function id(value: unknown, field: string): string {
  if (typeof value !== 'string' || !ID_PATTERN.test(value)) {
    throw new ProtocolError('protocol/bad-frame', `${field} 必须是 ASCII 安全字符集`)
  }
  return value
}

function checkHello(input: HelloFields): HelloFields {
  return {
    ephPubA: hex(input.ephPubA, 'ephPubA', HEX32),
    devId: id(input.devId, 'devId'),
    nonceA: hex(input.nonceA, 'nonceA', HEX32),
  }
}

function checkHelloAck(input: HelloAckFields): HelloAckFields {
  return {
    ephPubB: hex(input.ephPubB, 'ephPubB', HEX32),
    pcId: id(input.pcId, 'pcId'),
    nonceB: hex(input.nonceB, 'nonceB', HEX32),
  }
}

function checkConfirm(input: ConfirmFields): ConfirmFields {
  return {
    sigA: hex(input.sigA, 'sigA', HEX64),
    transcriptHash: hex(input.transcriptHash, 'transcriptHash', HEX8),
  }
}

function unbox(box: string, field: string): Record<string, unknown> {
  let payload: unknown
  try {
    payload = unseal<unknown>(box)
  } catch (error) {
    throw new ProtocolError('protocol/bad-frame', `${field} 无法解析：${String(error)}`)
  }
  if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) {
    throw new ProtocolError('protocol/bad-frame', `${field} 必须是 JSON 对象`)
  }
  return payload as Record<string, unknown>
}

export function encodeHello(fields: HelloFields): string {
  return seal(checkHello(fields))
}

export function encodeHelloAck(fields: HelloAckFields & { sigB: string }): string {
  return seal({ ...checkHelloAck(fields), sigB: hex(fields.sigB, 'sigB', HEX64) })
}

export function encodeConfirm(fields: ConfirmFields): string {
  return seal(checkConfirm(fields))
}

export function parseHello(box: string): HelloFields {
  return checkHello(unbox(box, 'hello') as unknown as HelloFields)
}

export function parseHelloAck(box: string): HelloAckFields & { sigB: string } {
  const raw = unbox(box, 'hello-ack')
  return {
    ...checkHelloAck(raw as unknown as HelloAckFields),
    sigB: hex(raw['sigB'], 'sigB', HEX64),
  }
}

export function parseConfirm(box: string): ConfirmFields {
  return checkConfirm(unbox(box, 'confirm') as unknown as ConfirmFields)
}
