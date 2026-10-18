/**
 * `client.js` 的 i18n 键完整性。
 *
 * ## 为什么需要它
 *
 * 面板的文案全走 `t('key')`。缺键时**原始 key 会被直接渲染出来**，
 * 而那种半截界面在真机上看起来像"面板坏了"，不是"少了一句文案"。
 * 而 `client.js` 是**纯 JS、没有类型**，`tsc` 抓不到任何一处。
 *
 * 四条判据：
 *
 * 1. 中文表与英文表**键集完全相同**（漏一边就在另一种语言下露出 key）；
 * 2. 用到的每个 `t('key')` 都在表里；
 * 3. 表里没有"零调用点"的废弃键（挂着会让人以为还有个入口）；
 * 4. 带 `{占位符}` 的文案，调用处要把参数传齐（否则原样露出 `{n}`）。
 *
 * 纯静态解析，不需要 DSH 运行时 —— 所以 DSH 升级导致插件挂不上时**照样能跑**。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const source = readFileSync(path.resolve(here, '..', 'client.js'), 'utf8')

/** 切出 `const <language> = { … }` 那段（括号配对；字符串里出现 `}` 也不会截断）。 */
function tableBody(language: 'zh' | 'en'): string {
  const start = source.indexOf(`const ${language} = {`)
  assert.ok(start >= 0, `找不到 const ${language} = {`)
  const open = source.indexOf('{', start)
  let depth = 0
  let i = open
  for (; i < source.length; i += 1) {
    const c = source[i]
    if (c === '{') depth += 1
    else if (c === '}') {
      depth -= 1
      if (depth === 0) break
    }
  }
  return source.slice(open + 1, i)
}

/**
 * 一级键的缩进。
 *
 * **不写死空格数**：整段 i18n 表嵌在 client 模块的闭包里，实际缩进是 6 格。
 * 写死会在有人调整嵌套层级时静默解析出 0 个键，而"0 个键"恰好会被
 * 键集比较判成"两边一样"（都是空）—— 门禁看起来通过。所以从首行推。
 */
function keyIndent(body: string): number {
  for (const line of body.split('\n')) {
    if (line.trim() === '') continue
    return line.length - line.trimStart().length
  }
  return 0
}

/** 表里的一级键 → 文案值（只收单行字符串，占位符检查够用）。 */
function tableEntries(language: 'zh' | 'en'): Map<string, string> {
  const body = tableBody(language)
  const indent = keyIndent(body)
  const out = new Map<string, string>()
  for (const line of body.split('\n')) {
    if (line.trim() === '') continue
    if (line.length - line.trimStart().length !== indent) continue
    const m = /^([A-Za-z_$][\w$]*):\s*'([^']*)'/.exec(line.trimStart())
    if (m?.[1] !== undefined) out.set(m[1], m[2] ?? '')
  }
  return out
}

/**
 * 源码里所有 `t(…)` 调用点用到的一级键。
 *
 * **整段参数里找字面量，不只是紧跟 `t(` 的那个**：有调用点写成
 * `t(enabled ? 'failedEnable' : 'failedDisable', { reason })` —— 只看紧跟的
 * 那个会漏掉两个键，于是它们被当成"零调用点的废弃键"。
 * 所以这里按括号配对取出参数段，再收段内全部形如标识符的字符串字面量。
 */
function usedKeys(): Map<string, number> {
  const out = new Map<string, number>()
  for (const m of source.matchAll(/\bt\(/g)) {
    const open = m.index + m[0].length - 1
    let depth = 0
    let i = open
    for (; i < source.length; i += 1) {
      const c = source[i]
      if (c === '(') depth += 1
      else if (c === ')') {
        depth -= 1
        if (depth === 0) break
      }
    }
    const args = source.slice(open + 1, i)
    for (const lit of args.matchAll(/'([A-Za-z_$][\w$]*)'/g)) {
      const key = lit[1]
      if (key === undefined) continue
      out.set(key, (out.get(key) ?? 0) + 1)
    }
  }
  return out
}

test('i18n：中文表与英文表的键集完全相同', () => {
  const zh = tableEntries('zh')
  const en = tableEntries('en')
  assert.ok(zh.size > 10, `中文表只解析出 ${zh.size} 个键 —— 缩进猜错了？`)
  const onlyZh = [...zh.keys()].filter((key) => !en.has(key)).sort()
  const onlyEn = [...en.keys()].filter((key) => !zh.has(key)).sort()
  assert.deepEqual(onlyZh, [], `英文表缺这些键：${onlyZh.join(', ')}`)
  assert.deepEqual(onlyEn, [], `中文表缺这些键：${onlyEn.join(', ')}`)
})

test('i18n：用到的每个 t(…) 键都在表里', () => {
  const zh = tableEntries('zh')
  const missing = [...usedKeys().keys()].filter((key) => !zh.has(key)).sort()
  assert.deepEqual(missing, [], `这些键用了但没有文案：${missing.join(', ')}`)
})

test('i18n：没有零调用点的废弃键', () => {
  const used = usedKeys()
  // `title` / `entry` 由 DSH 侧按 `settings.dshMobile.<key>` 取，不以 `t('…')` 出现。
  const unused = [...tableEntries('zh').keys()]
    .filter((key) => !used.has(key))
    .filter((key) => !['title', 'entry'].includes(key))
    .sort()
  assert.deepEqual(unused, [], `这些键没有任何调用点：${unused.join(', ')}`)
})

test('i18n：带 {占位符} 的文案，调用处要把参数传齐', () => {
  const zh = tableEntries('zh')
  let checkedCalls = 0
  for (const [key, text] of zh) {
    const needed = [...text.matchAll(/\{(\w+)\}/g)]
      .map((m) => m[1])
      .filter((name): name is string => name !== undefined)
      .sort()
    if (needed.length === 0) continue
    for (const call of source.matchAll(new RegExp(`\\bt\\('${key}',\\s*\\{([\\s\\S]*?)\\}\\)`, 'g'))) {
      const args = call[1] ?? ''
      checkedCalls += 1
      for (const name of needed) {
        assert.match(
          args,
          new RegExp(`\\b${name}\\b`),
          `t('${key}') 的调用没传 {${name}}，真机上会原样露出占位符`,
        )
      }
    }
  }
  // 别让这条在"一个占位符键都没匹配上"时静默通过。
  assert.ok(checkedCalls > 0, '一条带占位符的调用都没匹配到 —— 正则坏了')
})
