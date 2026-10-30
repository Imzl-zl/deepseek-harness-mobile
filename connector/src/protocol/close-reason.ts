/**
 * 拒绝的关闭理由（契约 §4.1）：`协议码` 或 `协议码 说明`。
 *
 * ## 为什么说明要挤在关闭理由里
 *
 * 握手拒绝发生在**业务帧之前**：那时没有方法面、没有 `res`，连接上唯一的
 * 可读信息就是关闭码与理由（`transport/connection.ts` 的 `socket.close(4003, reason)`，
 * 理由来自这里 / `ProtocolError.code`）。所以"被谁占着"这种要给人看的话，
 * 只能跟在这个字符串里。
 *
 * ## 两条硬约束
 *
 * 1. **码必须是第一个空格之前的全部字节**：手机按第一个空格切，
 *    切出来的码要能逐字命中封闭表（否则会归成 `internal`，用户看到的是"未知错误"）。
 * 2. **总长 ≤ 120 字节**：WebSocket 的关闭理由上限是 **123 字节**（RFC 6455 §5.5），
 *    超了 `ws` 会抛 `RangeError` 而**整条关闭路径失效** —— 连接反而留在那里。
 *    截断按**码点**做，不能把多字节字符切成半个（那是无效 UTF-8）。
 *
 * 说明里的换行一律压成空格：关闭理由是一行文本，换行会在日志与界面上都变成两行。
 */

/** 关闭理由的字节上限（WS 硬上限 123，留 3 字节余量）。 */
export const REFUSAL_REASON_MAX_BYTES = 120

export function refusalReason(code: string, detail?: string): string {
  if (detail === undefined) return code
  const flat = detail.replace(/[\r\n]+/g, ' ').trim()
  if (flat === '') return code
  const budget = REFUSAL_REASON_MAX_BYTES - Buffer.byteLength(code, 'utf8') - 1
  if (budget <= 0) return code
  return `${code} ${truncateUtf8(flat, budget)}`
}

/** 按码点截断到 ≤ [maxBytes] 字节（不切断多字节字符）。 */
function truncateUtf8(text: string, maxBytes: number): string {
  let used = 0
  let out = ''
  for (const char of text) {
    const size = Buffer.byteLength(char, 'utf8')
    if (used + size > maxBytes) break
    out += char
    used += size
  }
  return out
}
