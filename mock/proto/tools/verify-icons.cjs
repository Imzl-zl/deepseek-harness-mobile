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
  'checklist', 'workspaceTree', 'flatList', 'projectAdd', 'user', 'users', 'edit', 'light', 'dark', 'followsystem']
const absent = required.filter((n) => !I.names.includes(n))
ok(absent.length === 0, `all ${required.length} requested names exist`, absent.join(', '))

/* 11. the permission glyphs extracted from PermissionIcon.tsx */
const permissions = ['permissionReadOnly', 'permissionWorkspaceWrite', 'permissionFullAccess']
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

console.log(`\nnames (${I.names.length}): ${I.names.join(' ')}`)
console.log(fails.length ? `\n${fails.length} FAILED: ${fails.join(' | ')}` : '\nALL CHECKS PASSED')
process.exit(fails.length ? 1 : 0)
