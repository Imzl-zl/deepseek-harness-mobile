/**
 * Verification for mock/proto/icons.js — run: node mock/proto/tools/verify-icons.cjs
 * Loads the module exactly the way a browser <script> tag would (a global `window`).
 */
'use strict'

global.window = {}
require('../icons.js')

const I = global.window.DshIcons
const fails = []
const ok = (cond, label, extra) => {
  if (cond) console.log(`  PASS  ${label}`)
  else { fails.push(label); console.log(`  FAIL  ${label}${extra ? ' :: ' + extra : ''}`) }
}

if (!I || typeof I.svg !== 'function' || !Array.isArray(I.names)) {
  console.error('window.DshIcons missing or malformed')
  process.exit(1)
}

/* 1. every listed name renders a well-formed svg string */
let checked = 0
const bad = []
for (const name of I.names) {
  let out
  try { out = I.svg(name) } catch (err) { bad.push(`${name}: threw ${err.message}`); continue }
  if (typeof out !== 'string') { bad.push(`${name}: not a string`); continue }
  if (!out.startsWith('<svg')) bad.push(`${name}: does not start with <svg`)
  else if (!out.endsWith('</svg>')) bad.push(`${name}: does not end with </svg>`)
  else if (out.includes('undefined') || out.includes('NaN')) bad.push(`${name}: contains undefined/NaN`)
  else checked += 1
}
ok(I.names.length >= 40, `names.length >= 40 (actual ${I.names.length})`)
ok(bad.length === 0, `all ${I.names.length} names render <svg>..</svg> with no undefined/NaN (checked ${checked})`, bad.slice(0, 5).join(' | '))
ok(checked === I.names.length, `every name rendered (${checked}/${I.names.length})`)

/* 2. unknown names throw */
let threw = false
try { I.svg('definitelyNotAnIcon') } catch (err) { threw = err instanceof Error && err.message === 'unknown icon: definitelyNotAnIcon' }
ok(threw, "unknown name throws Error('unknown icon: ...')")

/* 3. sizes come from each artwork's own default, not a blanket 16 */
const widthOf = (s) => (s.match(/width="([0-9.]+)"/) || [])[1]
ok(widthOf(I.svg('send')) === '14', "send default size 14 (source: IconSendOutlineArtwork)")
ok(widthOf(I.svg('inspect')) === '12', "inspect default size 12 (source: CodeBracketsArtwork size ?? 12)")
ok(widthOf(I.svg('treeCorner')) === '8', "treeCorner default width 8 (size 10 * 8/10)")
ok(/\bheight="10"/.test(I.svg('treeCorner')), 'treeCorner default height 10')
ok(widthOf(I.svg('archive')) === '20', 'archive default size 20')
ok(widthOf(I.svg('panelLeft')) === '16', 'panelLeft default size 16')
ok(widthOf(I.svg('treeCorner', { size: 20 })) === '16', 'treeCorner size override 20 -> width 16')

/* 4. stroke width: default 1, overridable, medium 1.3 */
ok(/stroke-width="1"/.test(I.svg('search')), 'default stroke-width 1')
ok(/stroke-width="1.3"/.test(I.svg('search', { strokeWidth: I.ICON_MEDIUM_STROKE })), 'strokeWidth override 1.3')
ok(/stroke-width="2"/.test(I.svg('search', { strokeWidth: 2 })), 'strokeWidth override 2')
ok(I.ICON_REGULAR_STROKE === 1 && I.ICON_MEDIUM_STROKE === 1.3, 'stroke constants 1 / 1.3')

/* 5. className: absent by default, present when passed */
ok(!/class=/.test(I.svg('plus')), 'no class attribute when className is omitted')
ok(/class="my-icon"/.test(I.svg('plus', { className: 'my-icon' })), 'class attribute set when className is passed')

/* 6. strokeWidth-dependent geometry is preserved (microphone rect) */
const mic1 = I.svg('microphone')
const mic2 = I.svg('microphone', { strokeWidth: 2 })
ok(/<rect x="5" y="1.5" width="6" height="9" rx="3" \/>/.test(mic1), `microphone rect at sw=1 (${(mic1.match(/<rect[^>]*>/) || [])[0]})`)
ok(/<rect x="5.5" y="2" width="5" height="8" rx="2.5" \/>/.test(mic2), `microphone rect at sw=2 (${(mic2.match(/<rect[^>]*>/) || [])[0]})`)

/* 7. archiveOff mask gets a per-instance id */
const a1 = I.svg('archiveOff')
const a2 = I.svg('archiveOff')
const id1 = (a1.match(/<mask id="([^"]+)"/) || [])[1]
const id2 = (a2.match(/<mask id="([^"]+)"/) || [])[1]
ok(Boolean(id1) && Boolean(id2) && id1 !== id2, `archiveOff mask ids unique per call (${id1} / ${id2})`)
ok(a1.includes(`mask="url(#${id1})"`), 'archiveOff mask reference matches its own id')

/* 8. colours: currentColor only, except the archiveOff luminance mask */
const nonCurrent = []
for (const name of I.names) {
  const out = I.svg(name)
  for (const m of out.matchAll(/(?:fill|stroke)="([^"]+)"/g)) {
    if (m[1] !== 'currentColor' && m[1] !== 'none') nonCurrent.push(`${name}: ${m[1]}`)
  }
}
ok(
  nonCurrent.length === 2 && nonCurrent.every((v) => /archiveOff: (white|black)$/.test(v)),
  `only archiveOff's luminance mask carries literal colours (${nonCurrent.join(', ') || 'none'})`,
)
ok(!/var\(--/.test(I.names.map((n) => I.svg(n)).join('')), 'no CSS variables baked into the artwork')

/* 9. structural fidelity spot checks */
const panelLeft = I.svg('panelLeft')
ok(panelLeft.includes('viewBox="0 0 16 16"') && panelLeft.includes('fill="none"') && panelLeft.includes('aria-hidden="true"'), 'svg root keeps viewBox/fill=none/aria-hidden')
const info = I.svg('info')
ok(info.includes('viewBox="0 0 14 14"'), 'info keeps its 0 0 14 14 viewBox')
const flatList = I.svg('flatList')
ok(/stroke-linecap="round"/.test(flatList) && /<path d="M6 3.5h7.5M6 8h7.5M6 12.5h7.5" \/>/.test(flatList), 'flatList keeps root stroke + linecap and its paths')
const unarchive = I.svg('unarchive')
ok(/fill-rule="evenodd"/.test(unarchive) && /clip-rule="evenodd"/.test(unarchive), 'unarchive keeps fill-rule/clip-rule')
const folderOpen = I.svg('folderOpen')
ok(/opacity="0.16"/.test(folderOpen), 'folderOpen keeps opacity="0.16"')

/* 10. the names the prototype needs */
const required = ['panelLeft', 'newChat', 'search', 'settings', 'ellipsis', 'plus', 'close', 'closeFill', 'chevronLeft',
  'chevronRight', 'chevronDown', 'chevronUp', 'copy', 'refresh', 'branch', 'like', 'dislike', 'trash', 'archive',
  'unarchive', 'warning', 'warningTriangle', 'checkCircle', 'checkCircleFill', 'check', 'question', 'info', 'clock',
  'database', 'data', 'code', 'inspect', 'sparkle', 'send', 'paperPlane', 'stopFill', 'folderClose', 'folderOpen',
  'wrapLines', 'nowrap', 'compareSplit', 'fullscreen', 'share', 'link', 'rightUp', 'download', 'api', 'browse', 'plan',
  'queue', 'goal', 'skill', 'compact', 'pin', 'pinFill', 'treeCorner', 'loading', 'gauge', 'slidersTwo', 'alarmClock',
  'checklist', 'workspaceTree', 'flatList', 'projectAdd', 'user', 'users', 'edit', 'light', 'dark', 'followsystem',
  'fishLogo']
const absent = required.filter((n) => !I.names.includes(n))
ok(absent.length === 0, `all ${required.length} requested names exist`, absent.join(', '))

/* 11. the permission glyphs extracted from PermissionIcon.tsx */
const permissions = ['permissionReadOnly', 'permissionWorkspaceWrite', 'permissionFullAccess', 'permissionAutoReview']
const missingPermissions = permissions.filter((n) => !I.names.includes(n))
ok(missingPermissions.length === 0, `permission icons present (${permissions.join(', ')})`, missingPermissions.join(', '))
for (const name of permissions) {
  const out = I.svg(name)
  ok(
    out.startsWith('<svg') && out.endsWith('</svg>') && out.includes('viewBox="0 0 16 16"')
      && out.includes('stroke="currentColor"') && out.includes('stroke-width="1"') && widthOf(out) === '16',
    `${name} renders a 16px viewBox 0 0 16 16 currentColor glyph`,
  )
}
ok(permissions.every((n) => I.svg(n, { size: 22 }).includes('width="22"')), 'permission icons honour size override')
ok(
  /d="M6\.59624 2\.14853/.test(I.svg('permissionReadOnly')) && /d="M6\.4209 1\.68067/.test(I.svg('permissionWorkspaceWrite'))
    && /d="M6\.59624 2\.14853/.test(I.svg('permissionFullAccess')),
  'permission glyphs keep their own DSH paths',
)

/* 12. the brand mark (FishLogo.tsx) — the one artwork that is not stroke-drawn
 *
 * 它和另外 99 个的差别是**结构性**的，所以单列一节：整套图标是描边画的（根节点
 * `fill="none"` + 子元素 `stroke="currentColor"`），而鱼是一块**填充的剪影** ——
 * 根 `fill="none"` 但颜色挂在 `<path fill="currentColor">` 上，全图没有一根 stroke。
 * 这两点任一条被"顺手统一"掉，鱼就会静默变成一块黑或干脆不显示。
 * 高度是**按 23.16:17.04 算出来的表达式**（`%%E:`），不是正方形 —— 也不是常量。
 */
{
  const fish = I.svg('fishLogo')
  ok(I.names.includes('fishLogo'), 'fishLogo is in the set (FishLogo.tsx is a source of its own)')
  ok(
    fish.includes('viewBox="0 0 23.16 17.04"') && fish.includes('fill="none"'),
    'fishLogo keeps the native 0 0 23.16 17.04 viewBox and root fill=none',
  )
  ok(
    /<path d="M22\.9168 1\.43018/.test(fish) && fish.includes('fill="currentColor"'),
    'fishLogo keeps its DSH path and carries the colour on the <path>',
  )
  ok(!/\bstroke(-width)?=/.test(fish), 'fishLogo has no stroke attribute at all (pure filled silhouette)')
  ok((fish.match(/<path /g) || []).length === 1, `fishLogo is a single path (got ${(fish.match(/<path /g) || []).length})`)
  ok(widthOf(fish) === '24', `fishLogo default width 24 (got ${widthOf(fish)})`)
  // 24 * 17.04 / 23.16 —— 不是 24，所以"默认尺寸 = 正方形"这个假设在这里第一次不成立。
  const defaultHeight = (fish.match(/\bheight="([0-9.]+)"/) || [])[1]
  ok(
    defaultHeight !== undefined && Math.abs(Number(defaultHeight) - (24 * 17.04) / 23.16) < 1e-9,
    `fishLogo default height follows the 23.16:17.04 ratio (got ${defaultHeight})`,
  )
  const fish34 = I.svg('fishLogo', { size: 34 })
  const h34 = Number((fish34.match(/\bheight="([0-9.]+)"/) || [])[1])
  ok(
    widthOf(fish34) === '34' && Math.abs(h34 - (34 * 17.04) / 23.16) < 1e-9,
    `fishLogo size override 34 -> height ${(34 * 17.04) / 23.16} (got ${h34})`,
  )
}

/* 13. 落地端（app/lib）引用的图标名都必须存在
 *
 * 为什么单独一条：第 10 条只覆盖**原型**需要的名字，而 Flutter 落地端是另一批
 * 调用点。`DshIcon('<名字>')` 查不到键会**抛**，Flutter 把它渲染成一块巨大的
 * ErrorWidget —— 2026-10-15 真机上 `pairing_page.dart` 写了集合里没有的
 * `cameraScan`，于是整个配对页变成一块红，输入框与按钮被挤出屏幕，
 * 症状是"配对页坏了"而不是"少一个图标"。**原型与落地端不允许各自漂移**
 * （`mock/proto/AGENTS.md`），所以这条按同一份 `I.names` 卡两边。
 *
 * 正则允许 `(` 与名字之间有**空白和注释**：Dart 侧常写成
 * `const DshIcon(\n  'name',\n  size: 16,\n)`，而名字前面还可能有解释性注释
 * （`pairing_page.dart` 就有一段"为什么必须是集合里的名字"的注释）。
 * 假设：`DshIcon(` 之后第一个字符串字面量就是图标名 —— 现有调用点都满足
 * （`size` / `color` 是数字与常量，不是字符串）。
 */
{
  const fs = require('node:fs')
  const path = require('node:path')
  const APP_LIB = path.resolve(__dirname, '..', '..', '..', 'app', 'lib')
  if (!fs.existsSync(APP_LIB)) {
    ok(true, 'app/lib 不存在（跳过落地端引用检查）')
  } else {
    /** 去掉 Dart 注释：`//` 到行尾、`/* … *​/` 跨行。**必须先做** ——
     *  否则注释里的括号会打乱括号配对，注释里的字符串会被当成参数。 */
    const stripComments = (src) => src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ')

    /** 收集一份源码里所有 `DshIcon( … )` 自己那段中的第一个字符串字面量。
     *
     * 用**括号配对**而不是"向后看 N 字符"：后者会把同一文件里别的控件的
     * `fontFamily: 'monospace'` 算进来（实测误报），而 N 取大了误报、取小了
     * 漏掉带长注释的调用点（也实测过：第一版正则只允许空白，于是刚修的那个
     * bug 形状——名字前有注释——静默漏检，门禁看起来是通过的）。
     */
    const iconNamesIn = (src) => {
      const out = new Set()
      const clean = stripComments(src)
      const re = /DshIcon\(/g
      let m
      while ((m = re.exec(clean)) !== null) {
        let depth = 1
        let i = m.index + m[0].length
        while (i < clean.length && depth > 0) {
          const c = clean[i]
          if (c === '(') depth += 1
          else if (c === ')') depth -= 1
          i += 1
        }
        const inner = clean.slice(m.index + m[0].length, i - 1)
        const sm = inner.match(/'([a-zA-Z][a-zA-Z0-9]*)'/)
        if (sm !== null && sm[1] !== undefined) out.add(sm[1])
      }
      return out
    }

    /** 收集 `icon: '<名字>'` 这种**字符串传参**的图标名。
     *
     * 为什么还要这一条：图标名不只走 `DshIcon('…')`，也走控件参数
     * （`DshPickerRow(icon: '…')` 内部才构造 `DshIcon`）。只扫构造器会**漏检**——
     * 2026-10-18 实测：设置页写了 `icon: 'eye'`（集合里没有），
     * 门禁却报 ALL CHECKS PASSED，而运行时 sheet 整个渲染失败、
     * 点上去像"点了没反应"。
     *
     * 判据是"字符串字面量且形如标识符"，所以 `IconData` 变量之类不会误报。
     */
    const iconParamNamesIn = (src) => {
      const out = new Set()
      const clean = stripComments(src)
      for (const m of clean.matchAll(/\bicon:\s*'([a-zA-Z][a-zA-Z0-9]*)'/g)) {
        if (m[1] !== undefined) out.add(m[1])
      }
      return out
    }

    const referenced = new Set()
    const walk = (dir) => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name)
        if (entry.isDirectory()) walk(full)
        else if (entry.name.endsWith('.dart')) {
          const src = fs.readFileSync(full, 'utf8')
          for (const name of iconNamesIn(src)) referenced.add(name)
          for (const name of iconParamNamesIn(src)) referenced.add(name)
        }
      }
    }
    walk(APP_LIB)
    const missing = [...referenced].filter((n) => !I.names.includes(n)).sort()
    ok(
      missing.length === 0,
      `app/lib 引用的 ${referenced.size} 个图标名都在集合里`,
      missing.join(', '),
    )
  }
}

console.log(`\nnames (${I.names.length}): ${I.names.join(' ')}`)
console.log(fails.length ? `\n${fails.length} FAILED: ${fails.join(' | ')}` : '\nALL CHECKS PASSED')
process.exit(fails.length ? 1 : 0)
