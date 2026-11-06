/**
 * 错误码表的**跨端一致性**门禁。
 *
 * ## 为什么值得一条门禁
 *
 * 错误码有两个真值源：电脑侧的 `ERROR_TABLE`（TS）与手机侧的 `ErrorCode`（Dart）。
 * 它们**必须逐字相等**——漏一个的后果不是"走 default"，而是被归一化降级成
 * `internal` → `log-and-retry` → 用户对着一个永远重试也不好的操作反复点。
 * 本仓已经栽过一次（`not-paired` 被报成 `bad-frame`，用户卡在重试上）。
 *
 * 2026-10-09 就真的漏了：DSH 的 `session/agent-busy`、`session/model-unavailable`、
 * `gateway/bad-request` 等 15 个码两边都没有，全被降级成 `internal`。
 *
 * ## 门禁口径
 *
 * 从 Dart 侧机械抽出 `(wire, clientAction)` 对，与 TS 的 `ERROR_TABLE` 比对：
 * **码集合与每个码的动作都要相等**（多一个少一个、动作不一致，都红）。
 * 故意不依赖 DSH 源码路径：DSH 在仓库外，测试不该因为它在别的机器上而红。
 * "我们方法面可达的 DSH 码是否收全"由 `protocol/tools/dsh-error-codes.mjs` 单独负责
 * （它读 DSH 源码、产出快照，这里只断言两边一致）。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

import { ERROR_TABLE, type ClientAction } from '../src/protocol/errors.js'

const DART = new URL('../../app/lib/core/errors.dart', import.meta.url)

/** TS 侧自己的源码：联合类型在运行时不存在，只能读文本核对（见 `tsDeclaredActions`）。 */
const ERRORS_TS = new URL('../src/protocol/errors.ts', import.meta.url)

/** 从 Dart 枚举里抽出 `wire -> clientAction`。
 *
 * 口径要容忍 `dart format` 的排版：短条目是 `  name('wire', ClientAction.x),` 一行，
 * 长条目被排成三行，且动作后面多一个逗号。所以按整体形状匹配、并容许那个逗号 ——
 * 按行匹配会在 format 之后静默少抽几条（那比没有门禁更坏）。 */
function dartTable(source: string): Map<string, string> {
  const table = new Map<string, string>()
  const pattern = /\b(\w+)\(\s*'([^']+)'\s*,\s*ClientAction\.(\w+)\s*,?\s*\)/g
  for (const match of source.matchAll(pattern)) {
    const wire = match[2]
    const action = match[3]
    if (wire === undefined || action === undefined) continue
    table.set(wire, action)
  }
  return table
}

/** Dart 的 `ClientAction` 枚举里声明的取值（不是"被引用的"——未引用的也要算）。 */
function dartActions(source: string): Set<string> {
  const start = source.indexOf('enum ClientAction {')
  assert.equal(start >= 0, true, '没找到 Dart 的 ClientAction 枚举')
  const end = source.indexOf('\n}', start)
  assert.equal(end > start, true, '没找到 ClientAction 枚举的结尾')
  const body = source.slice(start, end)
  const names = new Set<string>()
  for (const match of body.matchAll(/^\s{2}(\w+),?\s*$/gm)) {
    const name = match[1]
    if (name !== undefined) names.add(name)
  }
  return names
}

/** Dart 的 camelCase 动作名 → TS 的 kebab 名。 */
const ACTION_OF: Record<string, ClientAction> = {
  upgradeRequired: 'upgrade-required',
  rePair: 're-pair',
  reconnectOnce: 'reconnect-once',
  backoffRetry: 'backoff-retry',
  snapshot: 'snapshot',
  dropFromList: 'drop-from-list',
  refreshPending: 'refresh-pending',
  refreshJobs: 'refresh-jobs',
  disableAndAnnotate: 'disable-and-annotate',
  refreshSettings: 'refresh-settings',
  showOffline: 'show-offline',
  disable: 'disable',
  reportDefect: 'report-defect',
  logAndRetry: 'log-and-retry',
}

test('错误码表两边逐字一致（码集合 + 每个码的客户端动作）', () => {
  const dart = dartTable(readFileSync(DART, 'utf8'))
  assert.equal(dart.size > 0, true, '没从 Dart 侧抽出任何错误码 —— 先检查解析口径，别当成通过')

  const missing: string[] = []
  const extra: string[] = []
  const mismatched: string[] = []
  for (const [wire, action] of dart) {
    const expected = ACTION_OF[action]
    assert.equal(expected !== undefined, true, `Dart 侧出现不认识的动作名 ${action}（${wire}）`)
    const actual = (ERROR_TABLE as Record<string, string | undefined>)[wire]
    if (actual === undefined) {
      missing.push(wire)
    } else if (actual !== expected) {
      mismatched.push(`${wire}: TS=${actual} Dart=${expected}`)
    }
  }
  for (const wire of Object.keys(ERROR_TABLE)) {
    if (!dart.has(wire)) extra.push(wire)
  }

  assert.deepEqual(
    { missing, extra, mismatched },
    { missing: [], extra: [], mismatched: [] },
    '错误码表漂移了：改一侧必须同步另一侧。漏一个码的后果是被归一化降级成 internal,'
      + '于是用户对着一个永远重试也不好的操作反复点',
  )
})

test('Dart 的 ClientAction 与 TS 的取值集合一致（没有只存在于一侧的动作）', () => {
  const source = readFileSync(DART, 'utf8')
  const dartNames = dartActions(source)
  assert.equal(dartNames.size > 0, true, '没从 Dart 侧抽出任何 ClientAction —— 先检查解析口径')
  const tsActions = new Set(Object.values(ERROR_TABLE))
  assert.deepEqual(
    [...dartNames].map((name) => ACTION_OF[name] ?? `未知动作:${name}`).sort(),
    [...tsActions].sort(),
    'ClientAction 的取值集合两边不一致',
  )
})

/** 从 TS 的 `export type ClientAction =` 联合类型里抽出声明的取值。
 *
 * **必须读源码而不是读类型**：类型在运行时不存在，而"声明了却没用到"正是这里要抓的
 * 那种漏洞 —— `tsc` 不会因为它没被用而报错（联合类型的成员本来就可以不出现）。 */
function tsDeclaredActions(source: string): Set<string> {
  const start = source.indexOf('export type ClientAction =')
  assert.equal(start >= 0, true, '没找到 TS 的 ClientAction 联合类型')
  const names = new Set<string>()
  for (const line of source.slice(start).split('\n').slice(1)) {
    const match = /^\s*\|\s*'([^']+)'\s*$/.exec(line)
    // 联合类型结束：第一行不是 `| '...'` 就停（`dart format` 那类排版容忍在这里不需要，
    // 因为 TS 这份是手写的、格式由本仓固定）。
    if (match === null) break
    const value = match[1]
    if (value !== undefined) names.add(value)
  }
  return names
}

test('TS 声明的 ClientAction 与表里实际用到的相等（没有死配置的处置）', () => {
  const source = readFileSync(ERRORS_TS, 'utf8')
  const declared = tsDeclaredActions(source)
  assert.equal(declared.size > 0, true, '没从 TS 侧抽出任何 ClientAction —— 先检查解析口径')
  const used = new Set<string>(Object.values(ERROR_TABLE))

  const unused = [...declared].filter((action) => !used.has(action)).sort()
  const undeclared = [...used].filter((action) => !declared.has(action)).sort()
  assert.deepEqual(
    { unused, undeclared },
    { unused: [], undeclared: [] },
    '有一侧是空的：`unused` 是"声明了但没有任何错误码使用"的死动作'
      + '（2026-11-05 撤独占时 `busy-wait` 就这样留了下来）；'
      + '`undeclared` 是表里用了但联合类型没声明',
  )

  // 顺带钉住"表的每一行都落在声明集合里"（`ERROR_TABLE` 的 `satisfies` 已由 tsc 保证，
  // 这条是给读测试的人的第二个证据：35 行、14 种动作，一个不多一个不少）。
  assert.equal(
    declared.size,
    used.size,
    `声明 ${declared.size} 种动作、表里用 ${used.size} 种 —— 两边必须相等`,
  )
})

