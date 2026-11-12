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
  { rule: 'service-key-registered', path: 'dsh/models.ts', content: "ctx.get('sessionController')", shouldFail: false },
  // `ctx.effect` / `ctx.on` 是 cordis 成员，不该被当成未登记的服务键
  { rule: 'service-key-registered', path: 'dsh/jobs.ts', content: 'ctx.effect(() => {})', shouldFail: false },
]

/**
 * 跨层共用：`dsh/` 引 `transport/` 时，目标必须是**纯叶子**（自己不再 import 任何东西）。
 *
 * `docs/subsystems/connector-and-relay.md` §1.2 原话是「`dsh/` 不 import `transport/`」——
 * 那句话从来没被机械执行过，而 `dsh/interaction-client.ts` 引 `transport/backoff.js`
 * 已经与它矛盾（退避计时：零 I/O、零依赖，而且 `transport/connection.ts` 用的是同一个
 * 事实）。规则的目的是**挡住耦合** —— 适配层不该间接认识"socket 怎么开"；
 * 纯叶子不产生这种耦合。所以判据是"目标模块自己有没有依赖"，不是"目录名对不对"。
 * 2026-11-12 定案，理由与被否方案见 `.agents/notes/implemented/2026-11-12-doc-drift-three.md`。
 */
const TRANSPORT_FROM_DSH = /from\s+['"]\.\.\/transport\/([\w.-]+)\.js['"]/g
/** 任何 `import … from '<x>'` / `export … from '<x>'`（先剥注释再量）。 */
const HAS_IMPORT = /\bfrom\s+['"]/

/** 与 `app/tools/verify-platform-boundary.mjs` 同一条手法：注释不算代码。 */
function stripComments(text: string): string {
  return text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|\n)\s*\/\/[^\n]*/g, '$1')
}

/** 返回违规行（空 = 全绿）；`read` 注入是为了能自检。 */
function crossLayerViolations(
  files: readonly string[],
  read: (path: string) => string,
): string[] {
  const out: string[] = []
  for (const file of files) {
    if (!file.startsWith('dsh/')) continue
    for (const found of read(file).matchAll(TRANSPORT_FROM_DSH)) {
      const target = `transport/${found[1]}.ts`
      let body: string
      try {
        body = read(target)
      } catch {
        out.push(`${file} 引了不存在的 ${target}`)
        continue
      }
      if (HAS_IMPORT.test(stripComments(body))) {
        out.push(`${file} 引了 ${target}（它自己有依赖，不是纯叶子）`)
      }
    }
  }
  return out
}

interface CrossLayerSample {
  name: string
  files: string[]
  contents: Record<string, string>
  /** 期望被判违规的 dsh 文件数。 */
  violations: number
}

const CROSS_LAYER_SELF_TEST: CrossLayerSample[] = [
  {
    name: '纯叶子（目标文件零依赖）⇒ 放过',
    files: ['dsh/client.ts'],
    contents: {
      'dsh/client.ts': "import { createBackoff } from '../transport/backoff.js'",
      'transport/backoff.ts': 'export function createBackoff() { return 1 }',
    },
    violations: 0,
  },
  {
    name: '目标带依赖（它会间接把 socket 装配拖进来）⇒ 拦下',
    files: ['dsh/client.ts'],
    contents: {
      'dsh/client.ts': "import { connect } from '../transport/connection.js'",
      'transport/connection.ts': "import { open } from 'ws'",
    },
    violations: 1,
  },
  {
    name: '注释里写着 from \'…\' 不算依赖 ⇒ 放过',
    files: ['dsh/client.ts'],
    contents: {
      'dsh/client.ts': "import { b } from '../transport/backoff.js'",
      'transport/backoff.ts': "// 旧写法：import { x } from './state.js'\nexport const a = 1",
    },
    violations: 0,
  },
  {
    name: '路径写错（目标不存在）⇒ 拦下',
    files: ['dsh/client.ts'],
    contents: { 'dsh/client.ts': "import { b } from '../transport/backof.js'" },
    violations: 1,
  },
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

  // ---- 跨层共用：`dsh/` 只能引 `transport/` 的纯叶子 ----
  for (const sample of CROSS_LAYER_SELF_TEST) {
    const found = crossLayerViolations(sample.files, (path) => {
      const body = sample.contents[path]
      if (body === undefined) throw new Error(`样本里没有 ${path}`)
      return body
    })
    check(found.length === sample.violations, `自检：${sample.name}`)
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

  // 跨层共用的真实扫描（读完的是**相对 src/** 的路径）。
  for (const violation of crossLayerViolations(files, (path) =>
    readFileSync(join(SRC, path), 'utf8'),
  )) {
    check(false, violation)
  }

  if (failures.length > 0) {
    assert.fail(`${failures.length}/${checks} 项不通过（扫描 ${files.length} 个 .ts）\n  - ${failures.join('\n  - ')}`)
  }
})
