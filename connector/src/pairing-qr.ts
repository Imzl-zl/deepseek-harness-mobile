/**
 * 把配对邀请编码成二维码（`dsh-mobile-pair` 出码命令与插件管理页面共用）。
 *
 * ## 消费者
 *
 * **唯一入口是 DSH 界面里的插件面板**：浏览器半侧 `client.js` 注册
 * `plugins.bundle.config` slot（`ui-plugin-manager/src/client/PluginManagerPage.tsx:735`），
 * 渲染在「插件」页的本组合包详情页里。它调 `POST /api/dsh-mobile/pair`
 * （`admin/routes.ts`）拿 `{svg, expiresAt}`。
 *
 * 曾经还有一个独立网页 `/dsh-mobile/`，**已删**（2026-10-15）：它与插件面板功能
 * 完全重复，而且它并不额外起进程 —— `webServer.register` 只是往 DSH 已有的
 * web server 上挂第二条路由，RPC 与 client bundle 同在同一个 server 上，
 * 留着没有隔离收益，只有"两套 UI 两个维护点"的代价。
 *
 * ### 曾经走错过的一段路（留档，别再走）
 *
 * 一开始只做了独立网页，理由是"先例 `packages/experimental/inspector/src/host/plugin.ts`
 * 用 `ctx.webServer.register({kind:'prefix'})` + `serveStatic`"。
 * **那是错的**：inspector 是一个自起路由的调试工具，不是插件 UI 的正道。
 * 插件往 DSH 界面里贡献 UI 的机制是 **Slots**（`reference/subsystems/slots`），
 * 官方 `ui-*` 包与第三方插件走同一套 `ctx.slots.inject` / `ctx.slots.register`。
 * 以偏概全的来源是只看了 inspector 一个例子，且从未问过"DSH 里插件这个概念的
 * UI 载体是什么"。
 *
 * ## 为什么斜杠命令用不了它
 *
 * DSH 的 `CommandResult` 只有 `{kind:'success', text?}` / `{kind:'error', text}`
 * 两种（已核实 `packages/interaction/commands/src/types.ts:34`），没有图片/markdown
 * 出口 —— 所以二维码没法从命令输出里出来，必须有个**界面**承载。
 * **但"界面"不等于"另起一个网页"**：注册进插件页就是界面。
 * 原来的结论"必须自服务一个页面"是错的推理。
 *
 * ## 为什么是二维码，而不是只给一段 JSON
 *
 * 手机上要扫的是**图**。只吐一段 JSON 文本的话，用户得手动复制粘贴 ——
 * 而那段 JSON 有 290 字节（含两把 64 字符的公钥），粘贴既容易错也没法"扫"。
 * 编码成二维码之后，手机摄像头对着屏幕就完事了。
 *
 * ## 载荷就是配对 JSON 原样
 *
 * **不改成短码 / 不改成 URL**：载荷的形状由 `pairing-v2.md` §12.1 定死
 * （公钥只从二维码来），手机侧 `PairingPage` 解析的也正是这个形状。
 * 在这里再造一层编码，等于给"二维码里是什么"添第二个答案，而两处迟早不一致。
 *
 * ## 输出选 SVG 而不是 PNG
 *
 * - SVG 是文本，能直接嵌进页面的 `data:` URI，也被 `<img src>` 吃掉；
 * - PNG 要过一遍位图编码，而二维码是纯黑白方块，SVG 反而更小更清晰。
 *
 * ## 真值判据
 *
 * `tests/admin-face.test.ts` 有一条**真 round-trip**：把本函数的产出按 SVG 的
 * 横向游程铺回位图，用 `jsqr` 解回来，断言与编码前的载荷逐字相同。
 * 期望值因此来自"编出来再解回去"，不是手抄的常量。
 */
import { toString as qrToString } from 'qrcode'

/** 二维码的纠错等级。`M` 是默认推荐值:约 15% 破损可恢复,密度也合适。 */
const QR_ERROR_CORRECTION = 'M' as const

/**
 * 把配对邀请编成一张 SVG 二维码。
 *
 * @param payload - 配对 JSON(形如 `{"v":2,"relay":…,"pcId":…,"pcPubEd":…,…}`)
 * @returns SVG 字符串;**载荷不合法时抛** —— 静默给一张空二维码会让
 *   用户扫到一个解不开的东西,而那比不出码更难排查。
 */
export async function pairingQrSvg(payload: string): Promise<string> {
  if (payload.length === 0) {
    throw new Error('配对载荷为空:没有可编码的内容')
  }
  // `qrcode` 的容量上限(版本 40 + 纠错 L)约 2953 字节;配对载荷远小于它,
  // 但真超了它会抛,所以这里不预先判长度 —— 让库说,别猜。
  return qrToString(payload, {
    type: 'svg',
    errorCorrectionLevel: QR_ERROR_CORRECTION,
    margin: 2,
    // 深色背景上的浅色前景:二维码本身仍是黑块白底(SVG 的 rect),
    // 这里只控制 SVG 根元素的背景,让它嵌进深色界面时不显得突兀。
    color: {
      dark: '#000000',
      light: '#ffffff',
    },
  })
}

/** 把 SVG 包成 markdown 能吃的 `data:` URI(命令输出与页面共用)。 */
export function svgDataUri(svg: string): string {
  return `data:image/svg+xml;base64,${Buffer.from(svg, 'utf8').toString('base64')}`
}
