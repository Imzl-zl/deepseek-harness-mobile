/**
 * 分层校验：把「第 4 步」的判据从手工 grep 变成可机械执行的断言。
 *
 * 判据原话（`docs/cookbook/channel-bootstrap.md` 第 4 步）：
 * 「`grep -r "packages/" src/dsh/` 里的每条 DSH 行为都带 `packages/...:行号` 注释；
 *   `src/protocol/` 不 import 任何 DSH 类型（依赖方向单向）」。
 *
 * 自带**规则自检**：用合成样本证明每条规则真的会拦。否则规则写错了也会"全绿" ——
 * 这与 `app/tools/verify-platform-boundary.mjs` 同一个套路。
 */
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join, relative, sep } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

import { OPTIONAL_SERVICES, REQUIRED_SERVICES } from '../src/dsh/caps.js'

const HERE = dirname(fileURLToPath(import.meta.url))
const SRC = join(HERE, '..', 'src')

interface Sample {
  rule: string
  path: string
  content: string
  shouldFail: boolean
}

interface Rule {
  id: string
  why: string
  appliesTo: (path: string) => boolean
  match: (content: string) => string | null
}

const DSH_IMPORT = /from\s+['"]@deepseek-ai\//
/**
 * DSH checkout 内的真实文件行号：`packages/<组>/<包>/src/<文件>.ts:行号`，
 * 也接受 `vendor/...`（cordis 在 DSH 仓库里就放在 `vendor/`）与 `docs/`。
 *
 * **刻意不带 `g` 标志**：带 `g` 的正则上 `test()` 是有状态的（`lastIndex` 会累积），
 * 同一个文件会被前后判成不同结果。只需要"有没有"，就不要用全局正则。
 *
 * 注意这是个**下限**检查，不是证明：它只保证「这个文件对着源码写过」，
 * 不保证每条 DSH 行为都各自带引用。后者需要 review，机械规则做不到。
 */
const EVIDENCE = /(?:packages|vendor|docs)\/[\w.-]+(?:\/[\w.-]+)*\.ts:\d+/
/** `ctx.get('key')` 或 `ctx.key`（服务访问）。 */
const SERVICE_ACCESS = /ctx\.get\(\s*'([a-zA-Z]+)'|ctx\.([a-z][a-zA-Z]*)/g

const RULES: Rule[] = [
  {
    id: 'protocol-no-dsh-import',
    why: '协议层必须能在纯 Node 下跑 fixtures；一旦它 import DSH，协议就被钉死在 Host 运行时上，'
      + '而且依赖方向会变成双向（设计文档 §1.2 的分层规则）',
    appliesTo: (path) => path.startsWith('protocol/'),
    match: (content) => (DSH_IMPORT.test(content) ? '协议层出现了 @deepseek-ai/* 的 import' : null),
  },
  {
    id: 'dsh-cites-evidence',
    why: '凡是用到 DSH / cordis 宿主接口的地方都要能回指源码行号；没有行号的适配等于按印象写的，'
      + '宿主一升级就没人能核对（根 AGENTS.md 常驻军规）。覆盖适配层**与入口文件** —— '
      + '入口同样直接用宿主接口（effect / provide / logger），不管它就会成为规则的盲区',
    appliesTo: (path) => path.startsWith('dsh/') || path === 'index.ts',
    match: (content) =>
      EVIDENCE.test(content) ? null : '文件里没有任何 packages/... 或 vendor/... 的 <文件>:<行号> 引用',
  },
  {
    id: 'service-key-registered',
    why: "ctx.get('拼错的键') 永远静默返回 undefined，裸读 ctx.x 又会抛；"
      + '服务键散落各处时，一个拼错就是一个永远 flase 的能力位，且没有任何报错',
    appliesTo: (path) => path.startsWith('dsh/'),
    match: (content) => {
      const registered = new Set<string>([...REQUIRED_SERVICES, ...OPTIONAL_SERVICES])
      const known = new Set([
        // cordis 自带的 ctx 成员，不是 DSH 服务键
        'effect', 'on', 'get', 'inject', 'plugin', 'logger', 'fiber', 'scope', 'set', 'emit', 'waterfall',
      ])
      const unknown: string[] = []
      for (const found of content.matchAll(SERVICE_ACCESS)) {
        const key = found[1] ?? found[2]
        if (key === undefined || known.has(key) || registered.has(key)) continue
        unknown.push(key)
      }
      return unknown.length > 0 ? `未登记的服务键：${[...new Set(unknown)].join(', ')}` : null
    },
  },
]

/** 合成样本：每条规则都要有一个"该拦"和一个"该放"的用例。 */
const SELF_TEST: Sample[] = [
  { rule: 'protocol-no-dsh-import', path: 'protocol/frame.ts', content: "import type { X } from '@deepseek-ai/cordis'", shouldFail: true },
  { rule: 'protocol-no-dsh-import', path: 'protocol/frame.ts', content: 'export const FRAME_TYPES = []', shouldFail: false },
  { rule: 'dsh-cites-evidence', path: 'dsh/jobs.ts', content: '// packages/jobs/jobs/src/index.ts:117\nconst x = 1', shouldFail: false },
  { rule: 'dsh-cites-evidence', path: 'dsh/jobs.ts', content: 'const x = 1 // 按印象写的', shouldFail: true },
  { rule: 'service-key-registered', path: 'dsh/jobs.ts', content: "ctx.get('jobs')", shouldFail: false },
  { rule: 'service-key-registered', path: 'dsh/jobs.ts', content: "ctx.get('jobb')", shouldFail: true },
  // `ctx.effect` / `ctx.on` 是 cordis 成员，不该被当成未登记的服务键
  { rule: 'service-key-registered', path: 'dsh/jobs.ts', content: 'ctx.effect(() => {})', shouldFail: false },
]

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) walk(full, out)
    else if (entry.name.endsWith('.ts')) out.push(relative(SRC, full).split(sep).join('/'))
  }
  return out
}

test('分层校验：协议层零 DSH 依赖、适配层带源码引用、服务键集中登记', () => {
  const failures: string[] = []
  let checks = 0
  const check = (ok: boolean, label: string): void => {
    checks += 1
    if (!ok) failures.push(label)
  }

  // ---- 自检：先证明规则本身有效 ----
  for (const sample of SELF_TEST) {
    const rule = RULES.find((r) => r.id === sample.rule)
    if (rule === undefined) {
      failures.push(`自检：规则 ${sample.rule} 不存在`)
      checks += 1
      continue
    }
    const fires = rule.appliesTo(sample.path) && rule.match(sample.content) !== null
    check(fires === sample.shouldFail, `自检：${sample.rule} 对样本应${sample.shouldFail ? '拦下' : '放过'}却相反`)
  }

  // ---- 真实扫描 ----
  const files = walk(SRC)
  assert.ok(files.length > 0, 'src 下没有 .ts 文件')

  for (const file of files) {
    const content = readFileSync(join(SRC, file), 'utf8')
    for (const rule of RULES) {
      if (!rule.appliesTo(file)) continue
      check(rule.match(content) === null, `${file}: [${rule.id}] ${rule.why}`)
    }
  }

  if (failures.length > 0) {
    assert.fail(`${failures.length}/${checks} 项不通过（扫描 ${files.length} 个 .ts）\n  - ${failures.join('\n  - ')}`)
  }
})
