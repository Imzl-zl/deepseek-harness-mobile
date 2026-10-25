/**
 * **线上形状的金样门禁**（`connector/tests/fixtures/wire-shapes.json`）。
 *
 * ## 它守的是什么
 *
 * 手机侧的 RPC 应答解码（`app/lib/wire/rpc/*.dart`）只能引用"连接器写出的形状"。
 * 引用是**人核的**，所以必须有一个机械的东西在形状变化时响 —— 那就是这份金样：
 * 由**真实 handler** 产出、**深比较**守住，App 的用例读**同一份文件**。
 *
 * 为什么不是"真机抓一份样本"：真样本是一次性快照，连接器改了应答它**不会变**，
 * 用例永远绿 —— 与 `memory.md` 教训第九条逐字同形，只是把"手捏的形状"换成了"过期的真形状"。
 * 这里的第一推动者是**连接器的实现**，所以实现一变，这个测试当天就红。
 *
 * ## 三条口径
 *
 * 1. **比"线上那一层"**：`JSON.parse(JSON.stringify(x))`，不比 JS 对象 ——
 *    `{a: undefined}` 与 `{}` 在 JS 里不相等、在线上是同一件事。
 * 2. **金样按"方法名 → 样本数组"**：数组是必须的 —— 同一种方法可能有多种形态
 *    （`session.projections` 的**扁平 `values`** 与 `session.list` 行里的**信封**就是
 *    同一个名字的两种形状，那正是这套机器要防的坑，见下面的 `SAMPLES`）。
 * 3. **只有 `UPDATE_WIRE_SHAPES=1` 时才写盘**（快照测试的老做法），平时只比较。
 *    改金样的唯一正当理由就是"连接器的实现变了，这是有意的"。
 *
 * ## 本轮只收两个方法
 *
 * `session.list` / `session.projections`。其余方法在第 2 批及以后逐批加进 `SAMPLES`
 * —— **金样的键集合不许缩水**（缩水那条用例会红）。
 */
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync } from 'node:fs'
import { test } from 'node:test'

import { fixtureHandlers, sidOf } from './support/fixture-handlers.js'

const GOLDEN = new URL('./fixtures/wire-shapes.json', import.meta.url)

/** `UPDATE_WIRE_SHAPES=1` 时重写金样；平时只比较。 */
const UPDATE = process.env['UPDATE_WIRE_SHAPES'] === '1'

/**
 * 一条样本：`params` 是手机真正会发的参数；`context` 是方法面在分发时注入的那几样
 * （写操作的 `requestId` 就在那里，见 `src/handlers.ts:581`）。
 *
 * **`session.list` 与 `session.projections` 是同一个名字的两种形状**：
 * - `session.list` 行里的 `.projections` 是**信封** `{kind, asOfSeq, values}`
 *   （`src/dsh/sessions.ts:333-341` 逐键重建、`src/handlers.ts:766-768` 过线）；
 * - `session.projections` 的**应答是扁平 `values`**（无信封、永不 `null`）
 *   （`src/dsh/projections.ts:68-72` 取 `values`、`:94` 返回）。
 *
 * 读错的表现是**静默空值**，所以两条金样都必须收 —— 只收一条就判不出"谁读错了层"。
 */
interface WireSample {
  readonly params?: Record<string, unknown>
  /** 写操作要求顶层 `requestId`（`handlers.ts:581-584`）。 */
  readonly context?: { readonly requestId: string }
  /**
   * **采集前归一**（只用于"会随无关变化而变"的字段）。
   *
   * 今天只有一处：`repo.info.methods` —— 它是 handler 表的键，加任何一个方法都会变。
   * 归一必须**写在采样处**并留理由，不能在比较时放过（那是恒真的另一种写法）。
   */
  readonly normalize?: (value: unknown) => unknown
}

const SAMPLED_METHODS = [
  'session.list',
  'session.projections',
  'session.create',
  'session.select-model',
  'session.modelCatalog',
  'session.cancel',
  'session.updateQueue',
  'session.prompt',
  'subagent.prompt',
  'workspace.list',
  'workspace.pin',
  'workspace.unpin',
  'workspace.archive',
  'workspace.unarchive',
  'workspace.insertSessionBefore',
  'workspace.insertBefore',
  'permission.catalog',
  'permission.switch',
  'settings.describe',
  'settings.update',
  'agentPresets.list',
  'repo.info',
  'endpoint.describe',
] as const

type SampledMethod = (typeof SAMPLED_METHODS)[number]

const SAMPLES: Record<SampledMethod, readonly WireSample[]> = {
  'session.list': [{}],
  'session.projections': [{ params: { sid: sidOf('dsh-4') } }],
  // 写操作：三个可选键各有"给"与"不给"两种，先收"给"的那一种。
  'session.create': [{ params: { agentPreset: 'standard' } }],
  'session.select-model': [
    {
      params: {
        sid: sidOf('dsh-1'),
        provider: 'deepseek',
        model: 'deepseek-reasoner',
        reasoningEffort: 'high',
      },
    },
  ],
  'session.modelCatalog': [{}],
  'session.cancel': [{ params: { sid: sidOf('dsh-1') } }],
  'session.updateQueue': [
    {
      params: { sid: sidOf('dsh-1'), itemId: 'q-1', action: { kind: 'remove' } },
      context: { requestId: 'q-1' },
    },
  ],
  'session.prompt': [
    {
      params: { sid: sidOf('dsh-1'), content: [{ type: 'text', text: '你好' }], mode: 'queue' },
      context: { requestId: 'p-1' },
    },
  ],
  // 子会话唯一的写入口：目标必须是**清单里的子会话**（`handlers.ts:809-817` 会拒根会话）。
  'subagent.prompt': [
    {
      params: { sid: sidOf('dsh-2'), content: [{ type: 'text', text: '继续' }], mode: 'steer' },
      context: { requestId: 'p-2' },
    },
  ],
  // 工作区面：七种应答全是"分组 + 两列 id"或"整份顺序/集合"，且 sid 都过了别名表。
  'workspace.list': [{}],
  'workspace.pin': [{ params: { sid: sidOf('dsh-1') } }],
  'workspace.unpin': [{ params: { sid: sidOf('dsh-1') } }],
  'workspace.archive': [{ params: { sid: sidOf('dsh-1') } }],
  'workspace.unarchive': [{ params: { sid: sidOf('dsh-1') } }],
  'workspace.insertSessionBefore': [
    { params: { workspaceId: 'ws-1', sid: sidOf('dsh-1'), beforeSid: sidOf('dsh-2') } },
  ],
  'workspace.insertBefore': [{ params: { workspaceId: 'ws-1' } }],
  // 权限 / 设置 / 预设三个目录面：`available` 是"明说"字段，值本体各有自己的解析器。
  'permission.catalog': [{}],
  'permission.switch': [{ params: { sid: sidOf('dsh-1'), preset: 'workspace-write' } }],
  'settings.describe': [{ params: { namespaces: ['general'] } }],
  'settings.update': [
    { params: { ns: 'general', path: ['defaultMode'], value: 'read-only' } },
  ],
  'agentPresets.list': [{}],
  // `repo.info` 的 `methods` 会随**任何**方法增减而变（`Object.keys(handlers).sort()`），
  // 逐字收进金样会为"与形状无关的原因"常年红 —— 采样时**归一掉**这个键
  // （`normalize`），另有一条连接器用例单独钉"它是排好序的字符串数组、含 repo.info 自己"。
  'repo.info': [
    {
      normalize: (value) => {
        const reply = value as Record<string, unknown>
        const { methods: _methods, ...rest } = reply
        return rest
      },
    },
  ],
  'endpoint.describe': [{}],
}

/** **线上那一层**：丢掉 `undefined`、规整成 JSON 标量，再比较。 */
function onWire(value: unknown): unknown {
  return JSON.parse(JSON.stringify(value)) as unknown
}

/**
 * 按 `SAMPLES` 的声明顺序采一遍（顺序固定，金样的 diff 才不会跳来跳去）。
 *
 * **一个 handlers 实例采全部方法**：别名表是这个实例自己的状态，而 `session.projections`
 * 要先有别名才反解得出 DSH 会话 id（`src/handlers.ts:401` 的 `requireSession`）。
 * 真实流程也是同一条：手机拿到 `session.list` 的 `sid` 之后才会拿它问投影。
 * 所以先列一次会话**给别名表播种**，那一次的返回值不参与金样。
 */
async function collect(): Promise<Record<string, unknown[]>> {
  const handlers = fixtureHandlers()
  const seed = handlers['session.list']
  assert.ok(seed !== undefined, 'session.list 没挂上 —— 金样没有播种别名的手段')
  await seed({}, undefined as never)

  const out: Record<string, unknown[]> = {}
  for (const method of SAMPLED_METHODS) {
    const handler = handlers[method]
    assert.ok(
      handler !== undefined,
      `${method} 没挂上 —— 没有它就没有样本（检查 fixtureHandlers 的依赖给了没有）`,
    )
    const collected: unknown[] = []
    for (const sample of SAMPLES[method]) {
      const result = await handler(
        sample.params ?? {},
        (sample.context ?? undefined) as never,
      )
      const wire = onWire(result)
      collected.push(sample.normalize === undefined ? wire : onWire(sample.normalize(wire)))
    }
    out[method] = collected
  }
  return out
}

test('金样的键集合 = 已收的方法集合（不许缩水，也不许悄悄多出来）', () => {
  if (UPDATE) return
  const golden = JSON.parse(readFileSync(GOLDEN, 'utf8')) as Record<string, unknown>
  const actual: string[] = [...SAMPLED_METHODS].sort()
  const stored = Object.keys(golden).sort()
  assert.deepEqual(
    {
      missing: actual.filter((key) => !stored.includes(key)),
      extra: stored.filter((key) => !actual.includes(key)),
    },
    { missing: [], extra: [] },
    '金样与 SAMPLES 对不上：缩水会让 App 侧的断言在空集上全绿，多出来是有人绕过了 SAMPLES',
  )
  // 每个方法至少一条样本 —— 否则"逐条都解得出"是空话。
  for (const [method, samples] of Object.entries(golden)) {
    assert.equal(Array.isArray(samples), true, `${method} 的样本必须是数组（多形态方法要放多条）`)
    assert.equal((samples as unknown[]).length > 0, true, `${method} 一条样本都没有`)
  }
})

test('线上形状与金样逐字一致（改一个字段就红，红时打 diff）', async () => {
  const actual = await collect()
  if (UPDATE) {
    writeFileSync(GOLDEN, `${JSON.stringify(actual, null, 2)}\n`, 'utf8')
    return
  }
  const golden = JSON.parse(readFileSync(GOLDEN, 'utf8')) as Record<string, unknown>
  // 整体深比较：node 的 assert 会把差异按结构打出来（哪个键、原值、新值）。
  assert.deepEqual(
    actual,
    golden,
    '线上形状漂了：这是连接器的应答变了。确认是有意的，就 UPDATE_WIRE_SHAPES=1 重生成，'
      + '并同步 App 侧的解码（app/lib/wire/rpc/）——不要只改金样让它变绿',
  )
})

test('金样是确定性的：采两遍必须一模一样', async () => {
  // 一次性快照最阴的失败形态是"里面有时间戳/随机 id"，那样金样每月都会红一次、
  // 而红的原因与本轮改动无关。这条用例把它按在同一处。
  assert.deepEqual(await collect(), await collect(), '采样不确定：金样里混进了时间戳或随机值')
})

test('repo.info.methods 的约定单独钉住（它被金样归一掉了，不能因此没人看着）', async () => {
  // 为什么单独钉：这个键会随**任何**方法增减而变，收进金样会常年红；
  // 但它仍然必须"是排好序的字符串数组、并且含 repo.info 自己"（它最后挂，看得见全部兄弟）。
  const handlers = fixtureHandlers()
  const info = handlers['repo.info']
  assert.ok(info !== undefined, 'repo.info 没挂上')
  const reply = (await info({}, undefined as never)) as { methods: unknown }
  assert.equal(Array.isArray(reply.methods), true, 'methods 必须是数组')
  const methods = reply.methods as string[]
  assert.equal(methods.every((name) => typeof name === 'string' && name !== ''), true)
  assert.deepEqual(methods, [...methods].sort(), 'methods 必须排好序（手机侧靠这个比"同一张表"）')
  assert.equal(methods.includes('repo.info'), true, 'methods 里必须有 repo.info 自己')
  assert.equal(methods.includes('session.list'), true)
})
