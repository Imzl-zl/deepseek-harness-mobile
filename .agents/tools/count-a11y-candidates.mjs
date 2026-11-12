// a11y 候选清单：找出「附近没有 Semantics 的 InkWell / GestureDetector」。
//
// **这是报告，不是门禁**（判据是"这一下点了会发生什么"，做不成机械规则；
// 见 `.agents/notes/implemented/2026-11-12-a11y-sheet-and-trajectory.md`）。
// 输出必须**逐个人读**：脚本从 `InkWell(` 那行往上找 5 行，`Tooltip` 在它上面、
// `Semantics` 在更外层、或者这个手势**故意**不进语义树（如时间轴轨道的
// `excludeFromSemantics: true`）都会算命中 —— 上一轮实测假阳性约 1/3。
//
// 用法（仓库根）：node .agents/tools/count-a11y-candidates.mjs [--all]
//   --all  连 `Semantics(` 在更外层的也算命中（默认只往前看 5 行）
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = fileURLToPath(new URL('../..', import.meta.url))
const uiDir = join(repoRoot, 'app', 'lib', 'ui')
const all = process.argv.includes('--all')

function walk(dir, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) walk(full, out)
    else if (entry.name.endsWith('.dart')) out.push(full)
  }
  return out
}

const rows = []
let total = 0
for (const file of walk(uiDir)) {
  const lines = readFileSync(file, 'utf8').split('\n')
  const hits = []
  lines.forEach((line, i) => {
    if (!/\b(InkWell|GestureDetector)\(/.test(line)) return
    const from = all ? 0 : Math.max(0, i - 5)
    const context = lines.slice(from, i + 3).join('\n')
    if (!/Semantics\(/.test(context)) hits.push(i + 1)
  })
  if (hits.length > 0) {
    rows.push([file.slice(uiDir.length + 1).split('\\').join('/'), hits])
    total += hits.length
  }
}
rows.sort((a, b) => b[1].length - a[1].length)
console.log(`候选 ${total} 处（上界，需逐个读）：`)
for (const [file, hits] of rows) {
  console.log(String(hits.length).padStart(3), file.padEnd(28), '行', hits.slice(0, 10).join(','))
}
