/**
 * Extractor: DSH product icon set -> mock/proto/icons.js
 *
 * Reads (read-only, never modifies DSH sources):
 *   packages/client/ui-primitives/src/icons/index.tsx
 *   packages/client/ui-primitives/src/icons/shared-artwork.tsx
 *   packages/client/ui-primitives/src/PermissionIcon.tsx
 * Emits a build-free browser module exposing window.DshIcons.
 *
 * Run:  node mock/proto/tools/extract-dsh-icons.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const OUT_FILE = resolve(HERE, '..', 'icons.js')

const DSH = process.env.DSH_SOURCE || 'D:/sudy/github/deepseek-harness'
const ICONS_TSX = `${DSH}/packages/client/ui-primitives/src/icons/index.tsx`
const SHARED_TSX = `${DSH}/packages/client/ui-primitives/src/icons/shared-artwork.tsx`
const PERMISSION_TSX = `${DSH}/packages/client/ui-primitives/src/PermissionIcon.tsx`

/** Exports whose source name does not follow the icon-naming rule. */
const EXPLICIT_NAMES = {
  PermissionIconReadOnly: 'permissionReadOnly',
  PermissionIconWorkspaceWrite: 'permissionWorkspaceWrite',
  PermissionIconFullAccess: 'permissionFullAccess',
}

const STROKE_CONSTS = { ICON_REGULAR_STROKE: 1, ICON_MEDIUM_STROKE: 1.3 }

/* ---------------------------------------------------------------- scanning */

function skipString(src, i) {
  const q = src[i]
  i += 1
  while (i < src.length) {
    const c = src[i]
    if (c === '\\') { i += 2; continue }
    if (c === q) return i + 1
    i += 1
  }
  throw new Error(`unterminated string literal at offset ${i}`)
}

/** Index of the bracket that closes the one starting at `start`. */
function matchBalanced(src, start) {
  const close = { '(': ')', '{': '}', '[': ']' }[src[start]]
  if (!close) throw new Error(`not a bracket at offset ${start}`)
  const open = src[start]
  let depth = 0
  let i = start
  while (i < src.length) {
    const c = src[i]
    if (c === '"' || c === "'" || c === '`') { i = skipString(src, i); continue }
    if (c === '/' && src[i + 1] === '/') { const n = src.indexOf('\n', i); i = n < 0 ? src.length : n + 1; continue }
    if (c === '/' && src[i + 1] === '*') { const n = src.indexOf('*/', i); i = n < 0 ? src.length : n + 2; continue }
    if (c === open) depth += 1
    else if (c === close) { depth -= 1; if (depth === 0) return i }
    i += 1
  }
  throw new Error(`unbalanced ${open} starting at offset ${start}`)
}

function lineOf(src, offset) {
  let line = 1
  for (let i = 0; i < offset; i += 1) if (src[i] === '\n') line += 1
  return line
}

/** JSX returned from a function/method block body. */
function returnedJsx(block) {
  const r = block.indexOf('return')
  if (r < 0) throw new Error('block body without return')
  let p = r + 'return'.length
  while (/\s/.test(block[p])) p += 1
  if (block[p] === '(') return block.slice(p + 1, matchBalanced(block, p))
  let end = block.indexOf('\n', p)
  if (end < 0) end = block.length
  const semi = block.indexOf(';', p)
  if (semi >= 0 && semi < end) end = semi
  return block.slice(p, end)
}

/**
 * Body of an arrow function that starts at `p` (after `=> `).
 * Handles the three shapes used by the icon sources:
 *   `=> ( <jsx> )`, `=> { ... return ( <jsx> ) }`, `=> <jsx />` (single line).
 */
function arrowBody(src, p) {
  while (/\s/.test(src[p])) p += 1
  const first = src[p]
  if (first === '(') return src.slice(p + 1, matchBalanced(src, p))
  if (first === '{') return returnedJsx(src.slice(p + 1, matchBalanced(src, p)))
  const nl = src.indexOf('\n', p)
  return src.slice(p, nl < 0 ? src.length : nl)
}

/**
 * Every icon factory in a source file, in either of the two shapes DSH uses:
 *   `const XArtwork = (params) => body`
 *   `function XArtwork(params): ReactNode { ... return body }`
 */
function parseDefs(src, file) {
  const defs = new Map()
  const record = (name, params, body, offset) => {
    const sizeDefault = /size\s*=\s*([0-9.]+)/.exec(params)
    defs.set(name, {
      name,
      file,
      line: lineOf(src, offset),
      params,
      sizeDefault: sizeDefault ? Number(sizeDefault[1]) : null,
      body,
    })
  }
  const reArrow = /^(?:export )?const ([A-Za-z0-9_]+)(?::[^=]*)? = \(([^)]*)\) => /gm
  let m
  while ((m = reArrow.exec(src))) record(m[1], m[2], arrowBody(src, m.index + m[0].length), m.index)
  const reFn = /^(?:export )?function ([A-Za-z0-9_]+)\(([^)]*)\)(?::[^{]*)?\{\s*/gm
  while ((m = reFn.exec(src))) {
    const brace = m.index + m[0].lastIndexOf('{')
    const block = src.slice(brace + 1, matchBalanced(src, brace))
    record(m[1], m[2], returnedJsx(block), m.index)
  }
  return defs
}

/** Single self-closing JSX element: tag, attributes, spread flag. */
function parseElement(body) {
  const m = /<([A-Za-z0-9_]+)([\s\S]*?)\/>/.exec(body)
  if (!m) return null
  const attrs = {}
  const are = /([A-Za-z][A-Za-z0-9]*)=\{([^{}]*)\}/g
  let a
  while ((a = are.exec(m[2]))) attrs[a[1]] = a[2].trim()
  return { tag: m[1], attrs, spread: /\{\.\.\.[A-Za-z0-9_]+\}/.test(m[2]) }
}

/* ------------------------------------------------------------- jsx -> svg */

const ATTR_ALIASES = [
  ['className', 'class'],
  ['strokeWidth', 'stroke-width'],
  ['strokeLinecap', 'stroke-linecap'],
  ['strokeLinejoin', 'stroke-linejoin'],
  ['strokeMiterlimit', 'stroke-miterlimit'],
  ['strokeDasharray', 'stroke-dasharray'],
  ['strokeDashoffset', 'stroke-dashoffset'],
  ['strokeOpacity', 'stroke-opacity'],
  ['fillRule', 'fill-rule'],
  ['fillOpacity', 'fill-opacity'],
  ['clipRule', 'clip-rule'],
  ['clipPath', 'clip-path'],
  ['stopColor', 'stop-color'],
  ['stopOpacity', 'stop-opacity'],
  ['xlinkHref', 'xlink:href'],
]

const EXPR_VARS = ['size', 'strokeWidth']

function validateExpr(expr, where) {
  const ids = expr.match(/[A-Za-z_$][A-Za-z0-9_$]*/g) ?? []
  for (const id of ids) {
    if (!EXPR_VARS.includes(id)) throw new Error(`unsupported identifier "${id}" in ${where}`)
  }
  if (!/^[\s0-9A-Za-z_$+\-*/().]+$/.test(expr)) throw new Error(`unsupported characters in ${where}`)
  // Compile-time syntax check only; the emitted module uses its own tiny evaluator.
  // eslint-disable-next-line no-new-func
  new Function('size', 'strokeWidth', `return (${expr})`)(1, 1)
}

/**
 * Convert an artwork's JSX into an SVG string with runtime placeholders:
 *   %%SIZE%% fixed width/height, %%SW%% stroke width, %%CLASS%% class attribute,
 *   %%UID%% per-instance id, %%E:<expr>%% arithmetic in size/strokeWidth.
 */
function jsxToSvg(jsx, ctx) {
  let s = jsx

  s = s.replace(/d=\{SHIELD_OUTLINE_PATH\}/g, `d="${SHIELD_PATH}"`)
  s = s.replace(/mask=\{`url\(#\$\{maskId\}\)`\}/g, 'mask="url(#%%UID%%)"')

  // attribute names first, so expression bodies stay untouched
  s = s.replace(/([A-Za-z][A-Za-z0-9]*)=/g, (mm, name) => {
    const hit = ATTR_ALIASES.find(([from]) => from === name)
    return hit ? `${hit[1]}=` : mm
  })

  s = s.replace(/class=\{className\}/g, 'class="%%CLASS%%"')
  s = s.replace(/width=\{size\}/g, 'width="%%SIZE%%"')
  s = s.replace(/height=\{size\}/g, 'height="%%SIZE%%"')

  s = s.replace(/([A-Za-z][A-Za-z0-9-]*)=\{([^{}]*)\}/g, (mm, name, raw) => {
    const e = raw.trim()
    if (e === 'strokeWidth') return `${name}="%%SW%%"`
    if (e === 'maskId') return `${name}="%%UID%%"`
    validateExpr(e, `${ctx} ${name}={${e}}`)
    return `${name}="%%E:${e}%%"`
  })

  s = s.replace(/>\s+</g, '><').replace(/\s+/g, ' ').trim()

  if (/[{}]/.test(s)) throw new Error(`unhandled JSX expression left in ${ctx}: ${s.slice(0, 160)}`)
  if (/\.\.\./.test(s)) throw new Error(`unhandled spread left in ${ctx}`)

  const vb = /viewBox="([^"]+)"/.exec(s)
  if (!vb) throw new Error(`no viewBox in ${ctx}`)
  if (!/width="(%%SIZE%%|%%E:[^"]+%%)"/.test(s)) throw new Error(`no size-driven width in ${ctx}`)
  if (!/height="%%SIZE%%"/.test(s)) throw new Error(`no size-driven height in ${ctx}`)
  return { svg: s, viewBox: vb[1] }
}

/* ------------------------------------------------------------------- main */

const iconsSrc = readFileSync(ICONS_TSX, 'utf8')
const sharedSrc = readFileSync(SHARED_TSX, 'utf8')
const permissionSrc = readFileSync(PERMISSION_TSX, 'utf8')

const SHIELD_PATH = (() => {
  const m = /export const SHIELD_OUTLINE_PATH = '([^']+)'/.exec(iconsSrc)
  if (!m) throw new Error('SHIELD_OUTLINE_PATH not found')
  return m[1]
})()

const defs = new Map([
  ...parseDefs(sharedSrc, 'shared-artwork.tsx'),
  ...parseDefs(iconsSrc, 'index.tsx'),
  ...parseDefs(permissionSrc, 'PermissionIcon.tsx'),
])

const cache = new Map()
/** Resolve an artwork (following aliases) to { svg, viewBox, sizeDefault }. */
function resolveArt(name, sizeOverride, seen = []) {
  if (seen.includes(name)) throw new Error(`alias cycle: ${[...seen, name].join(' -> ')}`)
  const key = `${name}@${sizeOverride ?? ''}`
  if (cache.has(key)) return cache.get(key)
  const def = defs.get(name)
  if (!def) throw new Error(`unknown artwork component: ${name}`)
  const rootTag = /^\s*<([A-Za-z0-9_]+)/.exec(def.body)
  if (!rootTag) throw new Error(`artwork ${name} has no root element`)
  let out
  if (rootTag[1] === 'svg') {
    const { svg, viewBox } = jsxToSvg(def.body, `${name} (${def.file}:${def.line})`)
    out = { svg, viewBox, sizeDefault: sizeOverride ?? def.sizeDefault, source: `${def.file}:${def.line}` }
  } else {
    const el = parseElement(def.body)
    if (!el) throw new Error(`cannot parse alias element in ${name}`)
    let next = sizeOverride
    const sizeAttr = el.attrs.size
    if (sizeAttr) {
      const fallback = /\?\?\s*([0-9.]+)\s*$/.exec(sizeAttr)
      if (fallback) next = sizeOverride ?? Number(fallback[1])
      else if (/^(props\.)?size$/.test(sizeAttr)) next = sizeOverride ?? def.sizeDefault
      else throw new Error(`unsupported size expression "${sizeAttr}" in ${name}`)
    }
    if (el.attrs.strokeWidth !== undefined) {
      const sw = el.attrs.strokeWidth
      if (!(sw in STROKE_CONSTS)) throw new Error(`unsupported stroke width "${sw}" in ${name}`)
    }
    out = resolveArt(el.tag, next, [...seen, name])
  }
  cache.set(key, out)
  return out
}

/* exported wrappers -> canonical (camelCase) names.
 * Both wrapper shapes DSH uses are scanned:
 *   export const IconXxxRegular = (props: IconProps) => <IconXxxArtwork ... />
 *   export function PermissionIconXxxRegular(props: IconProps): ReactNode { return <XxxArtwork ... /> }
 */
const WRAPPER_SOURCES = [
  { src: iconsSrc, file: 'index.tsx', re: /^export const ([A-Za-z0-9_]+?)(Regular|Medium) = \(props: IconProps\) => /gm },
  { src: permissionSrc, file: 'PermissionIcon.tsx', re: /^export function ([A-Za-z0-9_]+?)(Regular|Medium)\(props: IconProps\)(?::[^{]*)?\{\s*return /gm },
]
const records = []
for (const { src, file, re } of WRAPPER_SOURCES) {
  let rm
  while ((rm = re.exec(src))) {
    const exportName = rm[1] + rm[2]
    if (!/^(?:Icon|PermissionIcon)/.test(exportName)) continue
    const body = arrowBody(src, rm.index + rm[0].length)
    const el = parseElement(body)
    if (!el) throw new Error(`wrapper ${exportName} (${file}) does not render an element`)
    if (el.attrs.strokeWidth !== undefined && !(el.attrs.strokeWidth in STROKE_CONSTS)) {
      throw new Error(`wrapper ${exportName}: unsupported stroke width ${el.attrs.strokeWidth}`)
    }
    const sizeOverride = el.attrs.size ? /\?\?\s*([0-9.]+)\s*$/.exec(el.attrs.size) : null
    const art = resolveArt(el.tag, sizeOverride ? Number(sizeOverride[1]) : undefined)
    const raw = exportName.replace(/^Icon/, '').replace(/(Regular|Medium)$/, '')
    records.push({
      exportName,
      weight: rm[2],
      raw,
      base: raw.endsWith('Outline') && raw.length > 'Outline'.length ? raw.slice(0, -'Outline'.length) : raw,
      explicit: EXPLICIT_NAMES[raw],
      art,
      line: lineOf(src, rm.index),
      file,
    })
  }
}

const lowerFirst = (s) => s[0].toLowerCase() + s.slice(1)

/* name assignment, with explicit handling of the two collisions in the set */
const byName = new Map()
const collisions = []
for (const rec of records.filter((r) => r.weight === 'Regular')) {
  let name = rec.explicit ?? lowerFirst(rec.base)
  if (byName.has(name)) {
    const prev = byName.get(name)
    if (prev.art.svg !== rec.art.svg || prev.art.sizeDefault !== rec.art.sizeDefault) {
      const keepPlain = rec.raw === rec.base // this one carries no 'Outline' suffix
      const displaced = keepPlain ? prev : rec
      const survivor = keepPlain ? rec : prev
      const alias = `${lowerFirst(displaced.base)}Outline`
      byName.set(name, survivor)
      byName.set(alias, displaced)
      collisions.push({ name, kept: survivor.exportName, keptAs: name, displaced: displaced.exportName, displacedAs: alias })
    }
  } else {
    byName.set(name, rec)
  }
}

/* user-facing aliases (name used by the prototype that differs from the rule) */
const ALIASES = { nowrap: 'nowrapFill' }
for (const [alias, target] of Object.entries(ALIASES)) {
  if (byName.has(alias)) throw new Error(`alias ${alias} collides with a real icon`)
  const rec = byName.get(target)
  if (!rec) throw new Error(`alias target ${target} missing`)
  byName.set(alias, rec)
}

/* ------------------------------------------------------------------ emit */

const REQUIRED = [
  'panelLeft', 'newChat', 'search', 'settings', 'ellipsis', 'plus', 'close', 'closeFill', 'chevronLeft',
  'chevronRight', 'chevronDown', 'chevronUp', 'copy', 'refresh', 'branch', 'like', 'dislike', 'trash',
  'archive', 'unarchive', 'warning', 'warningTriangle', 'checkCircle', 'checkCircleFill', 'check',
  'question', 'info', 'clock', 'database', 'data', 'code', 'inspect', 'sparkle', 'send', 'paperPlane',
  'stopFill', 'folderClose', 'folderOpen', 'wrapLines', 'nowrap', 'compareSplit', 'fullscreen', 'share',
  'link', 'rightUp', 'download', 'api', 'browse', 'plan', 'queue', 'goal', 'skill', 'compact', 'pin',
  'pinFill', 'treeCorner', 'loading', 'gauge', 'slidersTwo', 'alarmClock', 'checklist', 'workspaceTree',
  'flatList', 'projectAdd', 'user', 'users', 'edit', 'light', 'dark', 'followsystem',
]
const missing = REQUIRED.filter((n) => !byName.has(n))
if (missing.length) throw new Error(`required icon names missing from extract: ${missing.join(', ')}`)

/* permission glyphs live in PermissionIcon.tsx, not in icons/index.tsx */
const PERMISSIONS = ['permissionReadOnly', 'permissionWorkspaceWrite', 'permissionFullAccess']
const missingPermissions = PERMISSIONS.filter((n) => !byName.has(n))
if (missingPermissions.length) throw new Error(`permission icons missing from extract: ${missingPermissions.join(', ')}`)

const GOLDEN = {
  panelLeft: [16, '0 0 16 16'], treeCorner: [10, '0 0 9 11'], send: [14, '0 0 16 16'],
  archive: [20, '0 0 16 16'], unarchive: [20, '0 0 20 20'], inspect: [12, '0 0 16 16'],
  plan: [14, '0 0 16 16'], queue: [14, '0 0 16 16'], newChat: [16, '0 0 16 16'],
  globe: [14, '0 0 16 16'], warning: [16, '0 0 16 16'], checkCircleFill: [16, '0 0 36 36'], skill: [16, '0 0 17 17'],
  pluginPinwheel: [16, '0 0 16 16'], alarmClock: [16, '0 0 17 17'], question: [14, '0 0 16 16'], info: [14, '0 0 14 14'], checkCircle: [16, '0 0 16 16'],
  closeFill: [14, '0 0 16 16'], api: [14, '0 0 16 16'], browse: [16, '0 0 16 16'],
  folderClose: [16, '0 0 16 16'], nowrap: [16, '0 0 16 16'],
  permissionReadOnly: [16, '0 0 16 16'], permissionWorkspaceWrite: [16, '0 0 16 16'],
  permissionFullAccess: [16, '0 0 16 16'],
}
for (const [name, [size, vb]] of Object.entries(GOLDEN)) {
  const rec = byName.get(name)
  if (!rec) throw new Error(`golden icon missing: ${name}`)
  if (rec.art.sizeDefault !== size || rec.art.viewBox !== vb) {
    throw new Error(`golden mismatch for ${name}: got size=${rec.art.sizeDefault} viewBox=${rec.art.viewBox}, expected size=${size} viewBox=${vb}`)
  }
}

const names = [...byName.keys()].sort()
const entries = names.map((name) => {
  const { art } = byName.get(name)
  return `    ${JSON.stringify(name)}: { s: ${art.sizeDefault}, v: ${JSON.stringify(art.viewBox)}, b: ${JSON.stringify(art.svg)} },`
})

const today = new Date().toISOString().slice(0, 10)
const countLines = (text) => text.trimEnd().split('\n').length
const header = `/*!
 * DSH icon set - mechanical extraction, no build step.
 *
 * Source (read-only; DSH sources were not modified):
 *   packages/client/ui-primitives/src/icons/index.tsx          (${countLines(iconsSrc)} lines)
 *   packages/client/ui-primitives/src/icons/shared-artwork.tsx (${countLines(sharedSrc)} lines)
 *   packages/client/ui-primitives/src/PermissionIcon.tsx       (${countLines(permissionSrc)} lines; permissionReadOnly / permissionWorkspaceWrite / permissionFullAccess)
 *   packages/client/ui-primitives/src/icons/props.ts           (IconProps: size?, className?)
 * Extracted: ${today}
 * Regenerate: node mock/proto/tools/extract-dsh-icons.mjs
 *
 * HEADS-UP: this file is a copy of DSH artwork. After any DSH upgrade, re-run the
 * extractor and diff the result; do not hand-edit the SVG payloads below.
 *
 * API:
 *   window.DshIcons.names                 -> string[] of every icon name (camelCase, sorted)
 *   window.DshIcons.svg(name, opts)       -> '<svg ...>...</svg>'
 *        opts.size        square edge in px; defaults to the icon's own drawn size
 *                         from the DSH artwork (16 for most, 14/12/10/20 for some)
 *        opts.className   class attribute; omitted entirely when not passed
 *        opts.strokeWidth defaults to ICON_REGULAR_STROKE (1); pass 1.3 for the
 *                         'Medium' weight variants of the DSH components
 *   window.DshIcons.ICON_REGULAR_STROKE   1
 *   window.DshIcons.ICON_MEDIUM_STROKE    1.3
 * Unknown names throw Error('unknown icon: <name>').
 *
 * Notes on fidelity:
 *   - Colours are currentColor only, exactly as in the DSH sources; no CSS vars.
 *   - One intentional exception: archiveOff's <mask> uses fill="white" +
 *     stroke="black" (source values). SVG masks are luminance masks, so those two
 *     literals are part of the glyph geometry, not theme colours. Do not
 *     "fix" them to currentColor or the slash cut-out disappears.
 *   - Every element attribute from the source (fill / stroke / stroke-width /
 *     stroke-linecap / stroke-linejoin / fill-rule / clip-rule / opacity / mask)
 *     is preserved. Attributes that the source computes from strokeWidth keep
 *     doing so (see the tiny arithmetic evaluator below).
 *
 * Icon-name collisions in the DSH set (both are exported here):
${collisions.map((c) => ` *   ${c.kept} -> "${c.keptAs}" | ${c.displaced} -> "${c.displacedAs}"`).join('\n')}
 *
 * Aliases added for the prototype (same artwork, second name):
${Object.entries(ALIASES).map(([a, t]) => ` *   "${a}" -> same artwork as "${t}"`).join('\n')}
 */`

const module = `${header}
(function (global) {
  'use strict'

  var ICON_REGULAR_STROKE = ${STROKE_CONSTS.ICON_REGULAR_STROKE}
  var ICON_MEDIUM_STROKE = ${STROKE_CONSTS.ICON_MEDIUM_STROKE}

  /* s: default size from the DSH artwork, v: viewBox, b: svg template */
  var ART = {
${entries.join('\n')}
  }

  var NAMES = Object.keys(ART).sort()
  var uidSeq = 0

  function evalArithmetic(expr, size, strokeWidth) {
    var s = expr
    var i = 0
    function ws() { while (s[i] === ' ') i += 1 }
    function num() {
      ws()
      var start = i
      while (s[i] >= '0' && s[i] <= '9' || s[i] === '.') i += 1
      if (start === i) throw new Error('bad number in icon expression: ' + expr)
      return parseFloat(s.slice(start, i))
    }
    function ident() {
      ws()
      var start = i
      while (/[A-Za-z_$]/.test(s[i] || '')) i += 1
      var name = s.slice(start, i)
      if (name === 'size') return size
      if (name === 'strokeWidth') return strokeWidth
      throw new Error('unknown identifier "' + name + '" in icon expression: ' + expr)
    }
    function primary() {
      ws()
      if (s[i] === '(') { i += 1; var v = sum(); ws(); if (s[i] !== ')') throw new Error('missing ) in ' + expr); i += 1; return v }
      if ((s[i] >= '0' && s[i] <= '9') || s[i] === '.') return num()
      return ident()
    }
    function unary() { ws(); if (s[i] === '-') { i += 1; return -primary() } return primary() }
    function product() {
      var v = unary()
      for (;;) {
        ws()
        var c = s[i]
        if (c !== '*' && c !== '/') return v
        i += 1
        var r = unary()
        v = c === '*' ? v * r : v / r
      }
    }
    function sum() {
      var v = product()
      for (;;) {
        ws()
        var c = s[i]
        if (c !== '+' && c !== '-') return v
        i += 1
        var r = product()
        v = c === '+' ? v + r : v - r
      }
    }
    var out = sum()
    ws()
    if (i !== s.length) throw new Error('trailing input in icon expression: ' + expr)
    return out
  }

  function escapeAttr(value) {
    return String(value).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;')
  }

  function svg(name, opts) {
    var art = ART[name]
    if (!art) throw new Error('unknown icon: ' + name)
    var o = opts || {}
    var size = o.size === undefined || o.size === null ? art.s : o.size
    var strokeWidth = o.strokeWidth === undefined || o.strokeWidth === null ? ICON_REGULAR_STROKE : o.strokeWidth
    var className = o.className === undefined || o.className === null ? '' : String(o.className)
    var out = art.b
    if (out.indexOf('%%E:') !== -1) {
      out = out.replace(/%%E:([^%]+)%%/g, function (_m, expr) { return String(evalArithmetic(expr, size, strokeWidth)) })
    }
    out = out.replace(/%%SIZE%%/g, String(size)).replace(/%%SW%%/g, String(strokeWidth))
    if (out.indexOf('%%UID%%') !== -1) {
      uidSeq += 1
      out = out.replace(/%%UID%%/g, 'dsh-icon-' + name + '-' + uidSeq)
    }
    if (className) out = out.replace(/%%CLASS%%/g, escapeAttr(className))
    else out = out.replace(/\\s*class="%%CLASS%%"/g, '')
    return out
  }

  global.DshIcons = {
    names: NAMES,
    svg: svg,
    ICON_REGULAR_STROKE: ICON_REGULAR_STROKE,
    ICON_MEDIUM_STROKE: ICON_MEDIUM_STROKE,
  }
})(typeof window !== 'undefined' ? window : this)
`

mkdirSync(dirname(OUT_FILE), { recursive: true })
writeFileSync(OUT_FILE, module, 'utf8')

const mediumOnly = records.filter((r) => r.weight === 'Medium').length
console.log(`icons.js written: ${OUT_FILE}`)
console.log(`  artwork components parsed : ${defs.size}`)
console.log(`  DSH exported components   : ${records.length} (${records.length - mediumOnly} Regular + ${mediumOnly} Medium)`)
console.log(`  distinct icon names       : ${names.length}`)
console.log(`  collisions disambiguated  : ${collisions.length ? collisions.map((c) => `${c.keptAs}/${c.displacedAs}`).join(', ') : 'none'}`)
console.log(`  required names present    : ${REQUIRED.length}/${REQUIRED.length}`)
console.log(`  permission names present  : ${PERMISSIONS.join(', ')}`)
console.log(`  golden defaults verified  : ${Object.keys(GOLDEN).length}`)
console.log(`  sizes seen                : ${[...new Set(names.map((n) => byName.get(n).art.sizeDefault))].sort((a, b) => a - b).join(', ')}`)
console.log(`  viewBoxes seen            : ${[...new Set(names.map((n) => byName.get(n).art.viewBox))].sort().join(' | ')}`)
