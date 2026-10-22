/// 一次性迁移：把**半点字号**（10.5 / 11.5 / 12.5 / 13.5 / 14.5）收敛成整数。
///
/// ## 为什么要有这一步
///
/// DSH 的字号阶梯**只有整数**（`--dsh-content-font-size` 是 10–22 的整数，
/// `ui-theme/src/theme-settings.ts:24-30`），而我们的 216 处字面量里混进了
/// 5 个半点值 —— 它们是历史上"差一点点"手工挑的，既不跟字号刻度走，
/// 也不在任何一档里。
///
/// 取整规则**向下取最近的整数**（10.5→11 例外，见下表）：半点的原意是
/// "比下一档小一点点"，向下取整保留那个意图；而 10.5 是唯一一个落在
/// caption 档（11）下面的值，取 11 是为了与其余 caption 统一。
///
/// ## 只做机械替换，不改语义
///
/// 语义档位（正文 / secondary / 标题阶梯）由 `theme/dsh_type.dart` 的调用点
/// 手工换 —— 那需要看一行代码的**角色**，脚本猜不了。这个脚本只负责
/// "把半点抹平"，等价于把一批手写数字对齐到整数网格。
///
/// 跑法：`node app/tools/migrate-font-half-points.mjs`（可重复跑：第二次
/// 命中数会变成 0，脚本会以 0 退出并说明"已经迁移过"）。

import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const LIB = join(ROOT, 'app', 'lib')

/// 半值 → 整数（**命中数必须与实测一致**，否则拒绝写盘）。
const MAP = new Map([
  ['10.5', { to: '11', expect: 1 }],
  ['11.5', { to: '11', expect: 11 }],
  ['12.5', { to: '12', expect: 16 }],
  ['13.5', { to: '13', expect: 4 }],
])

const walk = (dir, out) => {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) walk(full, out)
    else if (entry.endsWith('.dart')) out.push(full)
  }
  return out
}

const files = walk(LIB, [])
const hits = new Map()
const pending = []

for (const file of files) {
  const before = readFileSync(file, 'utf8')
  let after = before
  for (const [half, { to }] of MAP) {
    const re = new RegExp(`fontSize:\\s*${half.replace('.', '\\.')}(?![0-9])`, 'g')
    const found = after.match(re) ?? []
    if (found.length > 0) {
      hits.set(half, (hits.get(half) ?? 0) + found.length)
      after = after.replace(re, `fontSize: ${to}`)
    }
  }
  if (after !== before) pending.push({ file, before, after })
}

const total = [...hits.values()].reduce((a, b) => a + b, 0)
if (total === 0) {
  console.log('没有半点字号了（已经迁移过）。')
  process.exit(0)
}

let ok = true
for (const [half, { expect }] of MAP) {
  const got = hits.get(half) ?? 0
  if (got !== expect) {
    console.error(`拒绝写盘：fontSize: ${half} 命中 ${got} 处，期望 ${expect} 处。`)
    ok = false
  }
}
if (!ok) process.exit(1)

for (const { file, after } of pending) writeFileSync(file, after)

// 残渣断言：不许再有半点（防止"改了一半"）。
const leftovers = walk(LIB, []).flatMap((file) => {
  const text = readFileSync(file, 'utf8')
  return (text.match(/fontSize:\s*\d+\.\d+/g) ?? []).map(
    (m) => `${relative(ROOT, file)}: ${m}`,
  )
})
if (leftovers.length > 0) {
  console.error('改完仍有点数字号：')
  for (const line of leftovers) console.error(`  - ${line}`)
  process.exit(1)
}

console.log(
  `已迁移 ${total} 处半点字号：` +
    [...hits.entries()].map(([half, n]) => `${half}→${MAP.get(half).to} ×${n}`).join('、'),
)
