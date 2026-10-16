#!/usr/bin/env node
/**
 * 查 Flutter 框架源码 —— "别猜 Flutter 行为"的机械入口。
 *
 * ## 为什么要有这个脚本
 *
 * 2026-10-16 那轮做手机端抽屉/手势时，我（agent）在 Flutter 行为上犯的几次错，
 * 全都是"先动手、后验证"造成的：例如以为 `endDrawer` 不支持边缘拖动、
 * 以为 `drawerEdgeDragWidth` 能只作用在上半屏、以为系统返回手势能靠"把手内缩"避开。
 * 这些问题的答案**就在本机 SDK 源码里**，只需要先查一眼。
 *
 * 本仓对 DSH 的既有纪律是"引用一律 `packages/...:行号`，查不到就写未找到，禁止猜"
 * （根 `AGENTS.md` §6）。这个脚本就是把同一条纪律搬到 Flutter 上：
 * **Flutter 的行为以本机 SDK 源码为准**（版本与实现都是确定的），
 * 引用写成 `packages/flutter/lib/src/...:行号`。
 *
 * ## 用法
 *
 * ```powershell
 * node app/tools/flutter-api.mjs DrawerController      # 找符号（类/方法/字段）
 * node app/tools/flutter-api.mjs edgeDragWidth         # 找字段/参数
 * node app/tools/flutter-api.mjs "getSystemGestureExclusionRects" --ctx 4
 * node app/tools/flutter-api.mjs --version             # 本机 Flutter 版本
 * node app/tools/flutter-api.mjs --root                # SDK 根目录
 * ```
 *
 * 参数：
 * - `--ctx N`  每个命中多带 N 行上下文（默认 0，只打命中行 + 上方最近的文档注释行）
 * - `--limit N` 最多打多少条命中（默认 20）
 * - `--all`    连 `packages/flutter/lib/*.dart` 的顶层导出一起搜（默认只搜 `lib/src`）
 *
 * **不硬编码盘符**：SDK 根目录从 `FLUTTER_ROOT` 环境变量或 `where/which flutter` 推出来
 * （本仓有"工具脚本不许硬编码盘符"的门禁：`mock/proto/tools/verify-tool-paths.mjs`）。
 *
 * ## 查完还查不到怎么办
 *
 * 按这个顺序：① 这个脚本（本机实现）→ ② `api.flutter.dev` 的类文档
 * （`firecrawl_scrape` 能抓，页面里有 "View source code" 直链到同一份源码）→
 * ③ `docs.flutter.dev` 的专题（约束/布局/性能）→ ④ flutter/flutter 的 issue / PR
 * （已知坑）→ ⑤ **真机实测**（ROM 手势、输入法、权限这类"框架外"的行为，
 * 文档不保证，只有量了才算数；实测数据要写进决策笔记）。
 */
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'

/** 解析本机 Flutter SDK 根目录（不硬编码盘符）。 */
function flutterRoot() {
  const fromEnv = process.env.FLUTTER_ROOT
  if (fromEnv && existsSync(fromEnv)) return resolve(fromEnv)
  const which = process.platform === 'win32' ? 'where' : 'which'
  try {
    const out = execFileSync(which, ['flutter'], { encoding: 'utf8' }).split(/\r?\n/)[0].trim()
    // `<root>/bin/flutter(.bat)` → `<root>`
    return resolve(dirname(dirname(out)))
  } catch {
    return undefined
  }
}

/** 版本：SDK 里那份 `bin/cache/flutter.version.json`（Flutter 工具自己写的）。 */
function flutterVersion(root) {
  const json = join(root, 'bin', 'cache', 'flutter.version.json')
  if (existsSync(json)) {
    try {
      const parsed = JSON.parse(readFileSync(json, 'utf8'))
      return `${parsed.frameworkVersion} ${parsed.channel}（Dart ${parsed.dartSdkVersion}）`
    } catch {
      /* 落到下面的兜底 */
    }
  }
  const plain = join(root, 'version')
  return existsSync(plain) ? readFileSync(plain, 'utf8').trim() : '未知'
}

/** 递归收集 .dart 文件。 */
function dartFiles(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    const info = statSync(full)
    if (info.isDirectory()) dartFiles(full, out)
    else if (entry.endsWith('.dart')) out.push(full)
  }
  return out
}

/** 命中行的上一段文档注释（`///` 连续块的最后几行）—— 让输出自带"这是什么"。 */
function docAbove(lines, index, keep = 2) {
  const out = []
  for (let i = index - 1; i >= 0 && out.length < keep; i -= 1) {
    const line = lines[i].trim()
    if (!line.startsWith('///')) break
    out.unshift(line.replace(/^\/\/\/\s?/, ''))
  }
  return out
}

const args = process.argv.slice(2)
if (args.length === 0 || args[0] === '--help' || args[0] === '-h') {
  console.log(readFileSync(new URL(import.meta.url), 'utf8').split('*/')[0].split('/**')[1])
  process.exit(0)
}

const root = flutterRoot()
if (root === undefined) {
  console.error('找不到 Flutter SDK：设 FLUTTER_ROOT，或让 `flutter` 在 PATH 里。')
  process.exit(2)
}

if (args[0] === '--version') {
  console.log(`Flutter ${flutterVersion(root)}（SDK: ${root}）`)
  process.exit(0)
}
if (args[0] === '--root') {
  console.log(root)
  process.exit(0)
}

function numberFlag(name, fallback) {
  const i = args.indexOf(name)
  if (i === -1) return fallback
  const value = Number(args[i + 1])
  return Number.isFinite(value) ? value : fallback
}

const ctx = numberFlag('--ctx', 0)
const limit = numberFlag('--limit', 20)
const includeTopLevel = args.includes('--all')
const query = args.find(a => !a.startsWith('--') && a !== String(ctx) && a !== String(limit))
if (query === undefined) {
  console.error('用法：node app/tools/flutter-api.mjs <符号或正则> [--ctx N] [--limit N] [--all]')
  process.exit(2)
}

const isRegex = /[\\^$.*+?()[\]{}|]/.test(query)
const pattern = isRegex ? new RegExp(query) : undefined
const needle = isRegex ? undefined : query

const srcDir = join(root, 'packages', 'flutter', 'lib')
const files = [
  ...dartFiles(join(srcDir, 'src')),
  ...(includeTopLevel ? dartFiles(srcDir).filter(f => !f.includes(`${'src'}`)) : []),
]

const hits = []
for (const file of files) {
  const text = readFileSync(file, 'utf8')
  if (needle !== undefined && !text.includes(needle)) continue
  const lines = text.split(/\r?\n/)
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i]
    const matched = pattern !== undefined ? pattern.test(line) : line.includes(needle)
    if (!matched) continue
    hits.push({ file, line: i + 1, text: line.trim(), doc: docAbove(lines, i), index: i, lines })
    if (hits.length >= limit) break
  }
  if (hits.length >= limit) break
}

console.log(`Flutter ${flutterVersion(root)}  framework 源码：${files.length} 个 .dart`)
console.log(`查询：${query}${isRegex ? '（按正则）' : ''}  命中 ${hits.length}${hits.length >= limit ? '+' : ''}\n`)
for (const hit of hits) {
  const rel = hit.file.slice(root.length + 1).replace(/\\/g, '/')
  for (const doc of hit.doc) console.log(`  /// ${doc}`)
  console.log(`  ${rel}:${hit.line}`)
  console.log(`    ${hit.text}`)
  if (ctx > 0) {
    for (let k = 1; k <= ctx; k += 1) {
      const line = hit.lines[hit.index + k]
      if (line !== undefined) console.log(`      ${line.trim()}`)
    }
  }
  console.log()
}
if (hits.length === 0) {
  console.log('未找到 —— 按脚本头部的顺序继续查：api.flutter.dev → docs.flutter.dev → issue/PR → 真机实测。')
}