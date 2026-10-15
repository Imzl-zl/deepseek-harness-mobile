/**
 * 配对二维码的回归（`pairing-qr.ts`）。
 *
 * ## 为什么必须真解码一遍
 *
 * 二维码是"扫不到就配不上"的那一环,而它的失败方式全是静默的:
 * 编出来一张空图、载荷被改一个字符、模块矩阵错位 ——
 * 手机上表现都只是"扫不出来 / 解不开",没有任何一端会报错。
 *
 * 所以这里用一个**独立的解码库**(`jsqr`)把编出来的图解回来逐字节比对。
 * 第一版我手写了个"最小解码器",实际上直接 `return PAYLOAD` ——
 * 那是恒真断言,比不写还糟(它会让人以为验过了)。真解码才有证据。
 */
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { test } from 'node:test'

import { pairingQrSvg, svgDataUri } from '../src/pairing-qr.js'

/**
 * `jsQR` 的调用形状。
 *
 * 不走 `import jsQR from 'jsqr'`：它的 `.d.ts` 用 `export default`,
 * 而本仓 `verbatimModuleSyntax` 会把它解析成**模块命名空间**(运行时是函数、
 * 类型上不可调)—— 每次 `tsc` 都红在这里。用 `createRequire` 显式取 CJS 导出,
 * 形状自己声明:只用到 `data`,就只声明 `data`。
 */
type JsqrFn = (
  data: Uint8ClampedArray,
  width: number,
  height: number,
) => { data: string } | null

const jsQR: JsqrFn = createRequire(import.meta.url)('jsqr') as JsqrFn
/** 与真二维码同形的载荷(两把 64 字符公钥,共 290 字节)。 */
const PAYLOAD = JSON.stringify({
  v: 2,
  relay: 'ws://127.0.0.1:8787/ws/connector',
  pcId: 'local',
  pcPubEd: '45bbbc0908fb4644863a3256ca495903974dd72c0fc937730d9452f36bde6480',
  pcPubDh: '14671291ea5b1ff9ce47c1cddcdf66893ce5f4a90ee18bad75e427f3ca21ef55',
  offerId: 'UScWDmJRzFqPoBkJC20aOA',
  code: 'FZtE8FgE2f2rarzEg-CCJg',
})

test('编出来的图能被独立解码器解回**同一份**载荷', async () => {
  const svg = await pairingQrSvg(PAYLOAD)
  const decoded = decodeSvg(svg)
  assert.ok(decoded !== null, '要能解出来')
  assert.equal(decoded, PAYLOAD, '解回来的载荷必须逐字节相同')
})

test('换一份载荷编出来的是另一张能解的图(不是缓存/常量)', async () => {
  const other = PAYLOAD.replace('FZtE8FgE2f2rarzEg-CCJg', 'AAAAAAAAAAAAAAAAAAAAAA')
  const decoded = decodeSvg(await pairingQrSvg(other))
  assert.equal(decoded, other, '解回来的必须是新那一份')
})

test('空载荷直接抛,不给空二维码', async () => {
  await assert.rejects(() => pairingQrSvg(''), /配对载荷为空/)
})

test('data URI 是 base64 的 SVG,能被 <img src> 直接吃', () => {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg"></svg>'
  const uri = svgDataUri(svg)
  assert.ok(uri.startsWith('data:image/svg+xml;base64,'))
  const back = Buffer.from(uri.slice('data:image/svg+xml;base64,'.length), 'base64').toString('utf8')
  assert.equal(back, svg)
})

/**
 * 把 `qrcode` 产出的 SVG 还原成模块矩阵,再喂给 `jsQR`。
 *
 * SVG 的真实形状(已核实 `qrcode@1.5.4` 的输出,不是猜的):
 * `<svg xmlns viewBox="0 0 69 69" shape-rendering="crispEdges">` + 一个白底
 * `<path fill="#fff">` + 一个 `<path stroke="#000" d="M2 2.5h7m3 0h1…"/>`。
 * **黑块是横 run 画出来的,不是 1x1 的 rect** —— 第一版按 rect 解,一块都取不到。
 *
 * `d` 的语法只用三个命令:`M x y`(绝对移动)、`m dx dy`(相对移动)、
 * `h n`(横线 n)。y 是半整数(2.5/3.5…)因为描边宽 1 居中;于是
 * `floor(y) - margin` 就是它所在的模块行。
 */
function decodeSvg(svg: string): string | null {
  const viewBox = /viewBox="0 0 (\d+) (\d+)"/.exec(svg)
  assert.ok(viewBox !== null, 'SVG 要有 viewBox')
  const size = Number(viewBox[1])
  // `pairing-qr.ts` 里 margin=2 → 两侧各 2 模块留白。
  const margin = 2
  const modules = size - margin * 2
  assert.ok(modules > 0 && (modules - 17) % 4 === 0, `模块数 ${modules} 不是 17+4N`)

  const matrix = new Uint8ClampedArray(modules * modules)
  const paths = [...svg.matchAll(/<path[^>]*stroke="#000000"[^>]*d="([^"]+)"/g)]
  assert.ok(paths.length > 0, '要有一条黑色描边的 path')

  for (const pathMatch of paths) {
    const d = pathMatch[1]
    assert.ok(d !== undefined, 'path 必须带 d')
    let x = 0
    let y = 0
    // 逐 token 走:`M x y` / `m dx dy` / `h n`
    for (const token of d.matchAll(/([Mm])\s*(-?[\d.]+)\s+(-?[\d.]+)|h(-?[\d.]+)/g)) {
      if (token[1] !== undefined) {
        const a = Number(token[2])
        const b = Number(token[3])
        if (token[1] === 'M') {
          x = a
          y = b
        } else {
          x += a
          y += b
        }
        continue
      }
      const n = Number(token[4])
      const row = Math.floor(y) - margin
      const from = Math.floor(x) - margin
      const to = Math.floor(x + n) - margin
      for (let col = from; col < to; col++) {
        if (row >= 0 && row < modules && col >= 0 && col < modules) {
          matrix[row * modules + col] = 1
        }
      }
      x += n
    }
  }

  // `jsQR` 吃 RGBA 位图:黑块 → (0,0,0,255),白块 → (255,255,255,255)。
  const rgba = new Uint8ClampedArray(modules * modules * 4)
  for (let i = 0; i < matrix.length; i++) {
    const dark = matrix[i] === 1
    rgba[i * 4] = dark ? 0 : 255
    rgba[i * 4 + 1] = dark ? 0 : 255
    rgba[i * 4 + 2] = dark ? 0 : 255
    rgba[i * 4 + 3] = 255
  }
  const result = jsQR(rgba, modules, modules)
  return result === null ? null : result.data
}
