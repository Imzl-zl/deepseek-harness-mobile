/// `usage.summary` 的聚合规则回归。
///
/// ## 这一组守什么
///
/// DSH 没有跨会话用量汇总（`tokenUsage` 投影是单会话的，
/// `token-meter/src/usage-projection.ts:56-63` 的 state 是
/// `{totals, last:{turn, step, buckets}}`），所以连接器自己聚合。
/// 聚合规则是**这一层的发明**，因而必须有测试钉住 ——
/// 特别是三条容易写歪的：
///
/// 1. **子智能体会话不计入**（双计）：子智能体的用量已含在父会话账里；
/// 2. **全零的会话不进榜**（"用了 0" vs "没数据"两件事都要说对）；
/// 3. **`dshSessionId` 绝不过线**（契约 §5.1：手机与中继只见 `sid`）。
///
/// 测试替身必须复现真值形状：`projections.of` 返回的是**已拆信封的 values 映射**
/// （`dsh/projections.ts` 的 `valuesOf`），不是 DSH 的 `{kind, asOfSeq, values}`。
import assert from 'node:assert'
import { describe, it } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'

/** 一行会话清单（收窄成这一层用到的字段）。 */
function row(dshSessionId: string, extra: Record<string, unknown> = {}) {
  return {
    dshSessionId,
    updatedAt: 1,
    running: false,
    blank: false,
    subagent: false,
    ...extra,
  }
}

/** 一份 `tokenUsage` 投影（形状照 DSH 的 `{totals, last}`）。 */
function tokenUsage(totals: Record<string, number>) {
  return { totals, last: null }
}

/** 别名表：测试里用**固定映射**，值里不含 DSH id 本身。
 *
 * 这一点是"`dshSessionId` 不过线"那条断言能成立的前提：若替身返回
 * `sid:<id>`（把 id 原样塞进别名），那断言永远红，而红的原因是我的替身
 * 而不是实现。真实别名是 16 字节 base64url（`alias.ts`），与 id 无字面关系。
 */
const ALIAS: Record<string, string> = {
  a: 'AAAAAAAAAAAAAAAAAAAAAA',
  b: 'BBBBBBBBBBBBBBBBBBBBBB',
  parent: 'CCCCCCCCCCCCCCCCCCCCCC',
  child: 'DDDDDDDDDDDDDDDDDDDDDD',
  used: 'EEEEEEEEEEEEEEEEEEEEEE',
  blank: 'FFFFFFFFFFFFFFFFFFFFFF',
  'secret-dsh-id': 'GGGGGGGGGGGGGGGGGGGGGG',
}

/** 建一套最小 deps：`sessions.list` 给 [rows]，`projections.of` 按会话给 [usageOf]。 */
function deps({
  rows,
  usageOf,
}: {
  rows: ReturnType<typeof row>[]
  usageOf: (dshSessionId: string) => unknown
}): HandlerDeps {
  return {
    caps: () => ({}) as never,
    aliasVersion: () => 1,
    devices: () => [],
    sessions: {
      list: async () => rows,
      prompt: async () => ({ accepted: true as const }),
      selectModel: async () => ({ selected: { provider: 'p', model: 'm' } }),
      create: async () => ({ sessionId: 'new' }),
      updateQueue: async () => ({ accepted: true as const }),
      cancel: () => ({ accepted: true as const }),
    },
    aliases: {
      ensure: async (id: string) => ALIAS[id] ?? `sid-for-${id}`,
      sessionOf: (sid: string) =>
        Object.keys(ALIAS).find((key) => ALIAS[key] === sid),
    },
    projections: {
      of: async (dshSessionId: string) => ({ tokenUsage: usageOf(dshSessionId) }),
    },
  } as unknown as HandlerDeps
}

void describe('usage.summary 聚合规则', () => {
  void it('求和全部 visible 会话的 totals', async () => {
    const handlers = createHandlers(
      deps({
        rows: [row('a'), row('b')],
        usageOf: (id) =>
          tokenUsage(id === 'a' ? { inputTokens: 100, outputTokens: 50 } : { inputTokens: 30 }),
      }),
    )
    const result = (await handlers['usage.summary']!({}, {} as never)) as {
      sessions: number
      grandTotalTokens: number
    }
    assert.equal(result.sessions, 2)
    // 100 + 50 + 30 = 180（**totals 的全部数值字段都算**，不预设键名）
    assert.equal(result.grandTotalTokens, 180)
  })

  void it('子智能体会话不计入（它的用量已含在父会话账里）', async () => {
    const handlers = createHandlers(
      deps({
        rows: [row('parent'), row('child', { subagent: true })],
        usageOf: (id) =>
          tokenUsage(id === 'parent' ? { inputTokens: 100 } : { inputTokens: 999 }),
      }),
    )
    const result = (await handlers['usage.summary']!({}, {} as never)) as {
      sessions: number
      grandTotalTokens: number
    }
    assert.equal(result.sessions, 1, '子智能体会话被过滤')
    assert.equal(result.grandTotalTokens, 100, '不含子智能体的 999')
  })

  void it('全零的会话不进榜，但不是"消失了"', async () => {
    const handlers = createHandlers(
      deps({
        rows: [row('used'), row('blank')],
        usageOf: (id) =>
          tokenUsage(id === 'used' ? { inputTokens: 42 } : { inputTokens: 0 }),
      }),
    )
    const result = (await handlers['usage.summary']!({}, {} as never)) as {
      sessions: number
      grandTotalTokens: number
      bySession: { sid: string; tokens: number }[]
    }
    assert.equal(result.sessions, 2, '会话数仍数它 —— 全零不是"不存在"')
    assert.equal(result.grandTotalTokens, 42)
    assert.equal(result.bySession.length, 1, '全零不进榜')
    assert.equal(result.bySession[0]!.sid, ALIAS['used'])
  })

  void it('榜按用量降序，且不再截断（独立页面要放得下）', async () => {
    // **2026-10-19 起不截断**：用量从"设置页里的一组"变成**独立页面**
    // （`ui/usage_page.dart`），一页能放很多行；截到 5 条会让"更多会话"看不见。
    const rows = Array.from({ length: 8 }, (_, i) => row(`s${i}`))
    const handlers = createHandlers(
      deps({
        rows,
        // s0 用 800、s1 用 700 … s7 用 100。逆序赋权，验证排序真的生效
        // （顺序会让"没排序也恰好对"这种假绿混过去）。
        usageOf: (id) => tokenUsage({ inputTokens: (8 - Number(id.slice(1))) * 100 }),
      }),
    )
    const result = (await handlers['usage.summary']!({}, {} as never)) as {
      bySession: { sid: string; tokens: number }[]
    }
    assert.equal(result.bySession.length, 8, '8 个有数据的会话全给')
    assert.deepEqual(
      result.bySession.map((e) => e.tokens),
      [800, 700, 600, 500, 400, 300, 200, 100],
    )
  })

  void it('按项目（cwd）聚合，空目录单独一档', async () => {
    // 用户 2026-10-19 原话：「用量你最好也是做成一个页面的……总量，单个项目
    // 使用量是吧」。DSH 没有跨会话汇总接口，所以这一层聚合；`cwd` 就是
    // `session.list` 已经在发的那个字段。
    const rows = [row('a', { cwd: 'D:\\p1' }), row('b', { cwd: 'D:\\p1' }), row('c')]
    const handlers = createHandlers(
      deps({
        rows,
        // p1 两个会话共 500，另一个 200。
        usageOf: (id) =>
          tokenUsage({ inputTokens: id === 'c' ? 200 : 250 }),
      }),
    )
    const result = (await handlers['usage.summary']!({}, {} as never)) as {
      byProject: { path: string; tokens: number; sessions: number }[]
    }
    assert.deepEqual(result.byProject, [
      { path: 'D:\\p1', tokens: 500, sessions: 2 },
      // **空目录单独一档**：不猜一个项目归属。
      { path: '', tokens: 200, sessions: 1 },
    ])
    // 会话行也带 cwd（手机按它归组）。
    const bySession = (await handlers['usage.summary']!({}, {} as never)) as {
      bySession: { sid: string; cwd: string }[]
    }
    assert.deepEqual(
      bySession.bySession.map((e) => e.cwd).sort(),
      ['', 'D:\\p1', 'D:\\p1'],
    )
  })

  void it('dshSessionId 绝不过线（契约 §5.1）', async () => {
    const handlers = createHandlers(
      deps({
        rows: [row('secret-dsh-id')],
        usageOf: () => tokenUsage({ inputTokens: 10 }),
      }),
    )
    const result = (await handlers['usage.summary']!({}, {} as never)) as {
      bySession: Record<string, unknown>[]
    }
    const serialized = JSON.stringify(result)
    assert.equal(serialized.includes('secret-dsh-id'), false, '手机与中继只见 sid')
    assert.equal(result.bySession[0]!['sid'], ALIAS['secret-dsh-id'])
  })

  void it('tokenUsage 的 wire 值是 totals 本身，不是 {totals,last}', async () => {
    // **这条钉的是真形状**：`llm/token-meter/src/usage-projection.ts:149` 的
    // `wire: { viewSchema: projectionSchema, view: state => state.totals }` ——
    // 上线的就是那个 4 字段对象，外面没有 `{totals,last}` 信封。
    // 2026-10-19 第一版按 `{totals,…}` 读，真机上 128 个会话汇总出 `0 tok`
    // （单测全绿 —— 替手复述了实现的假设，与 memory.md 教训 1 同一类错）。
    const handlers = createHandlers(
      deps({
        rows: [row('a')],
        usageOf: () => ({
          uncachedInputTokens: 3011324,
          outputTokens: 530015,
          cacheReadTokens: 78982528,
          cacheWriteTokens: 0,
        }),
      }),
    )
    const result = (await handlers['usage.summary']!({}, {} as never)) as {
      grandTotalTokens: number
    }
    assert.equal(result.grandTotalTokens, 3011324 + 530015 + 78982528)
  })

  void it('带 {totals,last} 信封的形状也认（万一线上线改回去）', async () => {
    const handlers = createHandlers(
      deps({
        rows: [row('a')],
        usageOf: () => ({
          totals: { uncachedInputTokens: 100, outputTokens: 50 },
          last: { turn: 1, step: 1, buckets: {} },
        }),
      }),
    )
    const result = (await handlers['usage.summary']!({}, {} as never)) as {
      grandTotalTokens: number
    }
    assert.equal(result.grandTotalTokens, 150)
  })

  void it('投影里没有 tokenUsage（老连接器 / 服务缺）时按 0 计，不炸', async () => {
    const handlers = createHandlers(
      deps({
        rows: [row('a')],
        usageOf: () => undefined,
      }),
    )
    const result = (await handlers['usage.summary']!({}, {} as never)) as {
      sessions: number
      grandTotalTokens: number
      bySession: unknown[]
    }
    assert.equal(result.sessions, 1)
    assert.equal(result.grandTotalTokens, 0)
    assert.equal(result.bySession.length, 0)
  })

  void it('totals 里混进非数值字段时只求数值', async () => {
    const handlers = createHandlers(
      deps({
        rows: [row('a')],
        usageOf: () => ({ totals: { inputTokens: 10, note: 'x', nested: { a: 1 } } }),
      }),
    )
    const result = (await handlers['usage.summary']!({}, {} as never)) as {
      grandTotalTokens: number
    }
    assert.equal(result.grandTotalTokens, 10)
  })

  void it('空会话表：0 个会话、0 token、空榜', async () => {
    const handlers = createHandlers(deps({ rows: [], usageOf: () => tokenUsage({}) }))
    const result = (await handlers['usage.summary']!({}, {} as never)) as {
      sessions: number
      grandTotalTokens: number
      bySession: unknown[]
    }
    assert.equal(result.sessions, 0)
    assert.equal(result.grandTotalTokens, 0)
    assert.deepEqual(result.bySession, [])
  })
})
