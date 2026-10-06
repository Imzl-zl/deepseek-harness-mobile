/* 工具脚本路径门禁:本仓库内的路径必须从 import.meta.url 派生,不许写死盘符。
   用法: node mock/proto/tools/verify-tool-paths.mjs
   为什么有这条:环境从 C:\sudy 搬到 D:\sudy 之后,11 个脚本里写死的
   'file:///C:/.../index.html' 让整组浏览器门禁**静默全红** —— 脚本照常跑完、照常打印 JSON,
   红的原因是路径而不是代码。取舍见 .agents/notes/implemented/2026-10-02-paths-must-be-derived-not-hardcoded.md
   规则(可机械判定):
     1. 不许出现 'file:///' + 盘符的字面量(硬编码的工作路径必然长这样);
     2. 不许出现 'C:\sudy' / 'C:/sudy'(搬迁后失效的旧环境根)。 */
import { readFileSync } from 'node:fs'
import { readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))

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
]

const files = readdirSync(HERE).filter((f) => f.endsWith('.mjs') || f.endsWith('.cjs'))
const violations = []

for (const file of files) {
  const text = readFileSync(join(HERE, file), 'utf8')
  const lines = text.split(/\r?\n/)
  lines.forEach((line, i) => {
    // 本文件自己会写出这些字面量(规则与说明),跳过自身
    if (file === 'verify-tool-paths.mjs') return
    for (const rule of RULES) {
      rule.re.lastIndex = 0
      const hit = rule.re.exec(line)
      if (hit) {
        violations.push({ file, line: i + 1, rule: rule.name, found: hit[0], why: rule.why })
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

console.log(`ALL CHECKS PASSED — 扫描 ${files.length} 个工具脚本,${RULES.length} 条规则,0 处硬编码路径`)
