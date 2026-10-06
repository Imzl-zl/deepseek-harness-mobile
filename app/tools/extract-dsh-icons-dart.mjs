/**
 * Extractor: mock/proto/icons.js -> app/lib/theme/dsh_icons.dart
 *
 * ## 为什么要有这一步（而不是在 Dart 里手抄一遍）
 *
 * 项目硬规则是**图标只有一个来源**（DSH 的图标集，`mock/proto/icons.js` 是机生成的），
 * 而 `AGENTS.md` 的"改基线要同步改落地端，不允许两边各自漂移"说的是同一件事。
 * 手抄一份 Dart 表就等于开了第二个来源，而两边的偏差**不会报错** ——
 * 只会让原型与 App 显示不同的图标。
 *
 * 所以：**读同一份 `icons.js`，产出 Dart**。原型与 App 的图标因此定义上就一致。
 *
 * 跑法：`node app/tools/extract-dsh-icons-dart.mjs`
 * （`mock/proto/icons.js` 本身由 `node mock/proto/tools/extract-dsh-icons.mjs` 从 DSH 源抽）
 *
 * 实现放在 `app/tools/dsh_icons.template.dart`（一个普通的 Dart 文件，
 * 带 `@@…@@` 占位符）。**不把 Dart 源码写成 JS 模板字符串**：
 * Dart 的文档注释里全是反引号，塞进模板字符串会直接语法错误（踩过）。
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const require = createRequire(import.meta.url)
const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(HERE, '..', '..')
const ICONS_JS = join(REPO_ROOT, 'mock', 'proto', 'icons.js')
const TEMPLATE = join(HERE, 'dsh_icons.template.dart')
const OUT_FILE = join(REPO_ROOT, 'app', 'lib', 'theme', 'dsh_icons.dart')

// 像浏览器那样加载（它挂在 global 上）。
global.window = {}
require(ICONS_JS)
const I = global.window.DshIcons
if (!I || typeof I.svg !== 'function' || !Array.isArray(I.names)) {
  throw new Error('mock/proto/icons.js 没有导出 window.DshIcons，先跑 mock/proto/tools/extract-dsh-icons.mjs')
}

/**
 * 占位哨兵：**不可能与真实内容相撞**的字符串。
 *
 * 尺寸用一个字母串而不是数字：产出里那处于是成为唯一的位置，
 * Dart 替换时不必做算术，也不会误伤别的数字（比如坐标里的 `16` 很多）。
 */
const SIZE_TOKEN = '__DSH_SIZE__'
const SW_TOKEN = '__DSH_SW__'
const COLOR_TOKEN = '__DSH_COLOR__'

/**
 * 取某图标**按它自己的默认尺寸烘焙好**的 SVG 串，并把尺寸/描边/颜色换成 token。
 *
 * ## 为什么按默认尺寸烘焙，而不是把尺寸留成占位符让 Dart 填
 *
 * `icons.js` 的模板里有 `%%E:strokeWidth + 3%%` 这类**算术表达式**
 * （`archiveOff` / `microphone` / `treeCorner` 用到），它们在 `size` 变化时
 * **会算出不同的几何**（实测：`treeCorner` 的 `x="8"` 在 size=20 时变成 `x="16"`）。
 * 直接塞一个字符串 token 进去会让表达式算成 `NaN`，而 `NaN` 会嵌进属性
 * （`width="NaN"` / `x="NaN"`）—— 渲染器**静默忽略**那个属性，图标画歪且无报错。
 *
 * 而"在 Dart 里重写那个表达式求值器"是不必要的：**SVG 自己会缩放**。
 * 根节点有 `viewBox`，只把 `width`/`height` 换掉、`viewBox` 留着，
 * 渲染器就会把整幅图形等比缩放。这正是 SVG 的本意。
 *
 * 于是：**用默认尺寸渲染一次**（让 JS 把表达式算准），只把根节点的
 * `width` / `height` / `stroke-width` 换成占位符。
 *
 * ## 为什么**只**换根节点的那三个属性
 *
 * 实测踩到：`archiveOff` 的默认尺寸是 16，而它的坐标里有 **6 处** `="16"`
 * （根节点两个 + `<mask>` 与 `<rect>` 的几何值）。全换会让 mask 的尺寸变成
 * 占位符 → SVG 非法 → 图标画不出。只有根节点那三个该换。
 */
function bakeIcon(name) {
  const rendered = I.svg(name)
  const head = /^<svg\b[^>]*>/.exec(rendered)
  if (!head) throw new Error(`icon ${name} 的产物不以 <svg 开头`)
  const width = /width="([^"]+)"/.exec(head[0])
  const height = /height="([^"]+)"/.exec(head[0])
  if (!width || !height) throw new Error(`icon ${name} 的根节点缺 width/height`)
  if (!/viewBox="/.test(head[0])) {
    // 没有 viewBox 就没法缩放 —— 那就不能把 width/height 换成占位符。
    throw new Error(`icon ${name} 的根节点没有 viewBox，无法交给渲染器缩放`)
  }

  const root = head[0]
    .replace(/width="[^"]+"/, `width="${SIZE_TOKEN}"`)
    .replace(/height="[^"]+"/, `height="${SIZE_TOKEN}"`)
    .replace(/stroke-width="[^"]+"/, `stroke-width="${SW_TOKEN}"`)

  return {
    body: rendered.replace(head[0], root),
    naturalWidth: Number(width[1]),
    naturalHeight: Number(height[1]),
  }
}

const entries = []
for (const name of I.names) {
  // **按默认尺寸烘焙**（让 JS 把 `%%E:` 表达式算准），只把根节点的尺寸换成占位符。
  // 详见 `bakeIcon` 的说明。
  const baked = bakeIcon(name)
  const defaultSize = baked.naturalWidth
  if (!Number.isFinite(defaultSize) || defaultSize <= 0) {
    throw new Error(`icon ${name} 的默认尺寸读不出来（得到 ${defaultSize}）`)
  }

  let body = baked.body

  // `currentColor` -> 占位色。**全部 98 个都只用 currentColor**（已核实：
  // 没有任何一个用非主题色的 fill/stroke）。但 `<mask>` 里面的 white/black
  // 是**亮度掩码的几何值**（不是主题色），所以先摘出来、替换完再放回去。
  const masks = []
  body = body.replace(/<mask[\s\S]*?<\/mask>/g, (m) => {
    masks.push(m)
    return `\u0000MASK${masks.length - 1}\u0000`
  })
  body = body.split('currentColor').join(COLOR_TOKEN)
  body = body.replace(/\u0000MASK(\d+)\u0000/g, (_, i) => masks[Number(i)])

  // 抽取器残留的占位符（`%%…%%`）一个都不该剩下：它们会进 SVG 属性并被静默忽略。
  const leftover = /%%[^%]*%%/.exec(body)
  if (leftover) throw new Error(`icon ${name} 里还有没求值的模板占位符：${leftover[0]}`)
  if (body.includes('NaN') || body.includes('undefined')) {
    throw new Error(`icon ${name} 的 SVG 含 NaN/undefined（表达式没算出来）`)
  }
  // Dart 的三引号原始字符串里不能出现 `'''`；也没有 `\` 转义问题（r''' 是原始串）。
  if (body.includes("'''")) {
    throw new Error(`icon ${name} 的 SVG 里含三个连续单引号，会截断 Dart 原始字符串`)
  }
  entries.push({
    name,
    defaultSize,
    // 非正方形图标（`treeCorner` 是 8×10）要保住比例 —— 全按正方形画会拉变形。
    aspect: baked.naturalHeight / baked.naturalWidth,
    body,
  })
}

const art = entries
  .map((e) => `  '${e.name}': _IconArt(${e.defaultSize}, ${e.aspect}, r'''${e.body}'''),`)
  .join('\n')
const names = entries.map((e) => `    '${e.name}',`).join('\n')

const template = readFileSync(TEMPLATE, 'utf8')
const replacements = [
  ['@@DATE@@', new Date().toISOString().slice(0, 10)],
  ['@@COUNT@@', String(entries.length)],
  ['@@SIZETOKEN@@', SIZE_TOKEN],
  ['@@SWTOKEN@@', SW_TOKEN],
  ['@@COLORTOKEN@@', COLOR_TOKEN],
  ['@@ART@@', art],
  ['@@NAMES@@', names],
]
let out = template
for (const [key, value] of replacements) {
  if (!out.includes(key)) throw new Error(`模板缺少占位符 ${key}`)
  out = out.split(key).join(value)
}
// 剩下的 `@@…@@` 一律是漏填的占位符 —— 让它当场失败，别产出一个半成品。
const leftover = /@@[A-Z]+@@/.exec(out)
if (leftover) throw new Error(`模板里还有没填的占位符：${leftover[0]}`)

mkdirSync(dirname(OUT_FILE), { recursive: true })
writeFileSync(OUT_FILE, out, 'utf8')

console.log(`dsh_icons.dart written: ${OUT_FILE}`)
console.log(`  icons             : ${entries.length}`)
console.log(`  sizes             : ${[...new Set(entries.map((e) => e.defaultSize))].sort((a, b) => a - b).join(', ')}`)
console.log(`  currentColor 替换  : ${entries.length} 个图标全部替换为占位色`)
console.log(`  来源              : mock/proto/icons.js（与原型同一份）`)
