/* 工具脚本路径门禁:本仓库内的路径必须从 import.meta.url 派生,不许写死盘符。
   用法: node mock/proto/tools/verify-tool-paths.mjs
   为什么有这条:环境从 C:\sudy 搬到 D:\sudy 之后,11 个脚本里写死的
   'file:///C:/.../index.html' 让整组浏览器门禁**静默全红** —— 脚本照常跑完、照常打印 JSON,
   红的原因是路径而不是代码。取舍见 .agents/notes/implemented/2026-10-02-paths-must-be-derived-not-hardcoded.md
   规则(可机械判定):
     1. 不许出现 'file:///' + 盘符的字面量(硬编码的工作路径必然长这样);
     2. 不许出现 'C:\sudy' / 'C:/sudy'(搬迁后失效的旧环境根)。 */
import { existsSync, readFileSync } from 'node:fs'
import { readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))

/**
 * 要扫的目录。**2026-10-16 起也扫 `app/tools/`**：Flutter / App 侧的工具脚本
 * （例如 `flutter-api.mjs`，它去找本机 SDK 根）同样不许把盘符写进字面量。
 */
const ROOT = resolve(HERE, '..', '..', '..')
const DIRS = [HERE, join(ROOT, 'app', 'tools')]

/** 每个检查项:名字 + 正则 + 说明。 */
const RULES = [
  {
    name: 'no-hardcoded-file-url',
    // file:///C:/... 或 file:///D:/... —— 任何把盘符写进字面量的工作路径
    re: /file:\/\/\/[A-Za-z]:/g,
    why: '本仓库内的页面路径必须写成 new URL(\'../index.html\', import.meta.url).href',
  },
  {
    name: 'no-stale-env-root',
    re: /C:(\\|\/)sudy/g,
    why: '开发环境已从 C:\\sudy 迁到 D:\\sudy,旧路径指向不存在的目录',
  },
  {
    // 2026-10-16 补:前两条只拦 `file:///X:` 与 `C:\sudy`,拦不住新写的工具里
    // 直接写 `'D:\soft\flutter'` 这种盘符字面量 —— 而"不许硬编码盘符"才是这条门禁的本意。
    //
    // **例外必须显式**:该行带上 `allow-hardcoded-path:` 注释即豁免(带原因)。
    // 这样"确实需要"的那两处会在 diff 里被看见并留档,而不是让门禁悄悄失效。
    name: 'no-hardcoded-drive-letter',
    re: /\b[A-Za-z]:[\\/]/g,
    why: '工作路径必须从 import.meta.url / 环境变量 / 命令探测派生;确实需要写死的,在该行标注 allow-hardcoded-path: <原因>',
    allow: /allow-hardcoded-path:/,
  },
]

const files = DIRS.filter((dir) => existsSync(dir)).flatMap((dir) =>
  readdirSync(dir)
    .filter((f) => f.endsWith('.mjs') || f.endsWith('.cjs'))
    .map((f) => ({ name: f, path: join(dir, f), dir })),
)
const violations = []

for (const entry of files) {
  const text = readFileSync(entry.path, 'utf8')
  const lines = text.split(/\r?\n/)
  lines.forEach((line, i) => {
    // 本文件自己会写出这些字面量(规则与说明),跳过自身
    if (entry.name === 'verify-tool-paths.mjs') return
    /**
 * 该行是否被显式豁免：本行，或**紧挨着的上方注释块**里带 `allow-hardcoded-path:`。
 * 只认"连续注释块"而不是固定窗口 —— 窗口太宽会让离得远的标记也生效，判据就糊了。
 */
function exempted(rule, lines, index, line) {
  if (rule.allow === undefined) return false
  if (rule.allow.test(line)) return true
  for (let i = index - 1; i >= 0; i -= 1) {
    const above = lines[i].trim()
    if (!above.startsWith('//')) break
    if (rule.allow.test(above)) return true
  }
  return false
}

for (const rule of RULES) {
      if (exempted(rule, lines, i, line)) continue
      rule.re.lastIndex = 0
      const hit = rule.re.exec(line)
      if (hit) {
        // 报告里写相对于仓库根的位置,跨两个目录时也能一眼看出是哪一个
        const where = entry.path.slice(ROOT.length + 1).replace(/\\/g, '/')
        violations.push({ file: where, line: i + 1, rule: rule.name, found: hit[0], why: rule.why })
      }
    }
  })
}

if (violations.length > 0) {
  console.error(`FAIL — ${violations.length} 处硬编码路径:`)
  for (const v of violations) {
    console.error(`  ${v.file}:${v.line}  [${v.rule}] ${v.found}`)
    console.error(`      → ${v.why}`)
  }
  process.exit(1)
}

console.log(`ALL CHECKS PASSED — 扫描 ${files.length} 个工具脚本（${DIRS.map((d) => d.slice(ROOT.length + 1).replace(/\\/g, '/')).join(' + ')}）,${RULES.length} 条规则,0 处硬编码路径`)
