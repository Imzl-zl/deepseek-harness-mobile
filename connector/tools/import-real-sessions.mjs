// 把一份**真实网关的 `session/list` 应答**归一化成 DSH 形状的夹具。
//
// 输入：`POST /api/session/list` 的完整应答（`{type, rpcId, result:{ok, value:{items}}}`），
// 也就是 `dsh web` 的已认证页面里 fetch 到的那份。采集配方见 `tools.md`。
// 输出：`tests/fixtures/real-dsh-sessions.json`（`SessionSummary[]`）。
//
// ## 为什么归一化
//
// 夹具要进 git，而真实清单里有会话标题、目录、会话 id —— 那些是用户的私有数据。
// 归一化**只换值，不换形状**：键、类型、嵌套、数组长度（媒体类型除外）、
// 以及解码会分支的枚举（`projections.kind` / `origin` / `mode` / `formatStatus` /
// `currentValue`）原样保留；`sessionId` / `parentSessionId` / `subagentCatalog[].id`
// 换成按原下标编号的稳定别名，父子关系保留。
//
// ## 为什么按"形状签名"去重
//
// 一次真实清单可能有几百行，但**形状**只有二十来种。每种形状留第一条真实行，
// 既覆盖全部解码分支，又不把几百 KB 私有数据塞进夹具。签名包含：
// `blank` / `running` / 有没有父级 / `origin` / 投影键集合 / 每个投影值的类型。
//
// 用法：
//   node connector/tools/import-real-sessions.mjs <raw.json> [out.json]
//
// Note: 取舍见 `.agents/notes/implemented/2026-10-26-wire-review-fixes.md`（真实数据一节）。
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const defaultOut = join(here, '..', 'tests', 'fixtures', 'real-dsh-sessions.json')

/** 这些键的值是枚举，解码器会按值分支 —— 不能替换成占位。 */
const KEEP_VALUE = new Set([
  'kind',
  'origin',
  'mode',
  'formatStatus',
  'currentValue',
  'mediaTypes',
])

const normalizeValue = (value, key) => {
  if (typeof value === 'string') return KEEP_VALUE.has(key) ? value : 's'
  if (typeof value === 'number') return 1
  if (typeof value === 'boolean') return value
  if (value === null) return null
  if (Array.isArray(value)) {
    // 媒体类型列表本身是协议值（少一种就是另一个部署），保留整份。
    if (key === 'mediaTypes') return value
    return value.length === 0 ? [] : [normalizeValue(value[0], key)]
  }
  if (typeof value === 'object') {
    const out = {}
    for (const [childKey, childValue] of Object.entries(value)) {
      out[childKey] = normalizeValue(childValue, childKey)
    }
    return out
  }
  return value
}

/** 形状签名：只描述"解码会看到什么"，不含具体值。 */
const signatureOf = (item) => {
  const values = item.projections?.values ?? {}
  const keys = Object.keys(values).sort().join(',')
  const kinds = Object.entries(values)
    .map(([key, value]) => `${key}:${Array.isArray(value) ? 'a' : value === null ? 'n' : typeof value}`)
    .sort()
    .join(',')
  return [
    item.blank,
    item.running,
    item.parentSessionId === undefined ? '-' : 'p',
    item.origin ?? '-',
    keys,
    kinds,
  ].join('#')
}

const rawPath = process.argv[2]
if (rawPath === undefined) {
  console.error('usage: node connector/tools/import-real-sessions.mjs <raw.json> [out.json]')
  process.exit(2)
}
const outPath = resolve(process.argv[3] ?? defaultOut)

const raw = JSON.parse(readFileSync(rawPath, 'utf8'))
const items = raw?.result?.value?.items
if (!Array.isArray(items) || items.length === 0) {
  console.error('输入里没有 result.value.items（需要网关 session/list 的完整应答）')
  process.exit(1)
}

const idOf = new Map()
items.forEach((item, index) => {
  idOf.set(item.sessionId, `sid_${String(index).padStart(4, '0')}`)
})

const normalized = items.map((item, index) => {
  const out = {
    agentAvailable: Boolean(item.agentAvailable),
    sessionId: idOf.get(item.sessionId),
    updatedAt: 1,
    running: Boolean(item.running),
    blank: Boolean(item.blank),
  }
  if (item.formatStatus !== undefined) out.formatStatus = item.formatStatus
  if (item.parentSessionId !== undefined) {
    out.parentSessionId = idOf.get(item.parentSessionId) ?? 'sid_orphan'
  }
  if (item.origin !== undefined) out.origin = item.origin
  if (item.cwd !== undefined) out.cwd = '/repo/s'
  if (item.projections !== undefined) {
    const values = {}
    for (const [key, value] of Object.entries(item.projections.values ?? {})) {
      if (key === 'subagentCatalog' && Array.isArray(value)) {
        values[key] = value.map((entry) => ({
          ...normalizeValue(entry, ''),
          id: idOf.get(entry.id) ?? 'sid_unknown',
        }))
      } else {
        values[key] = normalizeValue(value, key)
      }
    }
    out.projections = { kind: item.projections.kind, asOfSeq: 1, values }
  }
  return { out, index }
})

const bySignature = new Map()
for (const { out, index } of normalized) {
  const signature = signatureOf(out)
  if (!bySignature.has(signature)) bySignature.set(signature, { out, index })
}
const sample = [...bySignature.values()]
  .sort((left, right) => left.index - right.index)
  .map((entry) => entry.out)

writeFileSync(outPath, `${JSON.stringify(sample, null, 2)}\n`, 'utf8')
console.log(
  `items=${items.length} signatures=${sample.length} bytes=${Buffer.byteLength(JSON.stringify(sample))} -> ${outPath}`,
)
