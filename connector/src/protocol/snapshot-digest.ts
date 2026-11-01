/**
 * 只读快照的**内容摘要**（契约 §5.7 的 `digest` / `notModified`）。
 *
 * ## 它解决什么
 *
 * 一次"回前台、什么都没变"的实测（`d61cf622`，2026-11-01）：出站 230 920 B，
 * 其中快照扇出（12 次只读方法的 `res`）56 536 B 明文 —— 而这 12 份里有 11 份
 * 与上一次逐字相同。摘要让客户端能说"我手里就是这一包"，服务端核对后回
 * `{notModified: true}`（约 20 B）而不是正文。
 *
 * ## 为什么它不是第二份真值（能不能用就取决于这一条）
 *
 * 1. **摘要由"将要发出的那份字节"算出**：算的是 `resFrame()` 产出的 `box`
 *    ——与正文同源，不是另一条独立观察；
 * 2. **答错的方向只可能是"多发一次"**：比对不上就发正文；客户端摘要丢了 / 过期了
 *    也发正文。服务端**每次都重算**，所以绝不会"服务端说没变、客户端却是旧值"；
 * 3. 客户端算的是它**收到的那一包**：不靠服务端报一个自称的摘要，
 *    于是服务端写错摘要也藏不住内容变化（那会把"服务端 bugs"退化成"多发字节"）。
 *
 * ## 边界
 *
 * - 仍是一次往返（省字节，不省 RTT）；
 * - **只对只读快照方法生效**（{@link SNAPSHOT_DIGEST_METHODS}）：写方法的应答
 *   带的是这次执行的结果，不是"某一版数据"，拿摘要去省它没有语义；
 * - 不带 `digest` 的老客户端行为**逐字不变**。
 *
 * 取舍、预期收益与被否方案（跨重连保留快照 / 给每个 key 造 rev / 行级增量）见
 * `.agents/notes/proposed/2026-11-01-never-pull-unchanged.md`。
 */
import { createHash } from 'node:crypto'

import { HOST_STATE_KEYS } from './host-state.js'
import type { MethodName } from './methods.js'

/**
 * 允许带 `digest` 的方法 —— **封闭集**。
 *
 * 判据与 `host` 帧那张登记表同源：那九个 key **就是**"手机按通知重取的那些快照"，
 * 所以直接从 {@link HOST_STATE_KEYS} 派生，不另写一份字面量（两份必然漂移，
 * 而漂移的表现是"某个 key 的摘要悄悄永不命中"：多发字节，没人看得出来）。
 *
 * `endpoint.describe` 额外列在这里：它不在 `host` 帧的 key 里（宿主没有"地址变了"
 * 的事件），但它是纯只读的端点自报，且**每次连上都会拉一次**（首屏那批），
 * 内容几乎永不变。
 */
export const SNAPSHOT_DIGEST_METHODS: ReadonlySet<string> = new Set<string>([
  ...HOST_STATE_KEYS,
  // 只读、每次连上必拉、内容几乎不变。
  'endpoint.describe',
])

/** 这个方法认不认 `digest`（不认就当它没带 —— 老客户端行为不变）。 */
export function acceptsSnapshotDigest(method: MethodName | string): boolean {
  return SNAPSHOT_DIGEST_METHODS.has(method)
}

/** sha256 摘要的 base64url 长度（32 字节 → 43 字符，无填充）。 */
export const SNAPSHOT_DIGEST_LENGTH = 43

const DIGEST_PATTERN = /^[A-Za-z0-9_-]{43}$/

/**
 * 形状校验：`base64url(sha256(...))` = 恰好 43 个 base64url 字符、无填充。
 *
 * 形状不对是**协议错误**（`protocol/bad-frame`），不是"当作没带"：
 * 一个想省字节的客户端写错摘要，若被静默忽略，症状是"摘要上线了但一个字节也没省"
 * 且没有任何一处会报 —— 那正是这条通道最爱犯的安静型故障。
 */
export function isSnapshotDigest(value: unknown): value is string {
  return typeof value === 'string' && DIGEST_PATTERN.test(value)
}

/**
 * 一包明文 `box` 的摘要。
 *
 * @param box - `resFrame()` 产出的 `box`（**将要发出的那份字节**，不是 `result` 的
 *   重新序列化 —— 两者在字段顺序 / 数字格式上可能不同，那会让客户端算的摘要
 *   永远对不上，而症状只是"从没命中过"）。
 */
export function snapshotDigestOf(box: string): string {
  return createHash('sha256').update(box, 'utf8').digest('base64url')
}
