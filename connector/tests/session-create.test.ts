/**
 * `session.create` 的回归（新建会话）。
 *
 * ## 为什么单独一组
 *
 * 这个方法**早在 METHODS 封闭集里**（契约 §5.7 有这一行），但 handler 一直没有 ——
 * 于是手机上点"新建会话"只会回 `connector/unsupported`，然后弹一句
 * "新建会话（...）"。这是"看着接了其实没接"的又一例：契约说了、App 侧写了
 * `AppModel.createSession()`、唯独中间那层是空的。
 *
 * 钉三件事：
 * 1. **请求体只带给了的字段**：`workspaceId` / `cwd` / `agentPreset` 全可选，
 *    而 DSH 对缺省字段有自己的默认（当前工作区 / 默认预设）。塞空串会被当成
 *    "显式选空"。
 * 2. **`workspaceId` / `cwd` 不透传手机不知道的值**：手机侧不知道电脑有哪些
 *    工作区（那要另接 `workspace-controller`），硬传一个猜的比不传更糟。
 * 3. **带幂等键**：点了两次不该建出两个会话。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { Caps } from '../src/dsh/caps.js'

const CAPS: Caps = {
  sessions: true,
  storage: true,
  approval: false,
  questions: false,
  jobs: false,
  subagents: false,
  settings: false,
  credentials: true,
  direct: false,
}

/** 记下每次 `create` 收到的请求体。 */
function build(seen: unknown[][], opts: { createShouldThrow?: boolean } = {}) {
  return createHandlers({
    caps: () => CAPS,
    aliasVersion: () => 0,
    sessions: {
      list: async () => [],
      prompt: async () => ({ accepted: true as const }),
      selectModel: async () => ({ selected: { provider: 'test', model: 'test' } }),
      updateQueue: async () => ({ accepted: true as const }),
      cancel: () => ({ accepted: true as const }),
      create: async (request) => {
        seen.push([request])
        if (opts.createShouldThrow) throw new Error('DSH 拒绝新建')
        return { sessionId: 'dsh-new-1' }
      },
    },
    aliases: {
      ensure: async (id: string) => `sid_${id}`,
      sessionOf: () => undefined,
    },
    devices: () => [],
  })
}

test('空参数：请求体是 {}，DSH 用它自己的当前工作区', async () => {
  const seen: unknown[][] = []
  const handlers = build(seen)

  const result = await handlers['session.create']!({}, {})

  assert.equal((result as { sessionId: string }).sessionId, 'dsh-new-1')
  // **一个字段都不该塞**：手机不知道电脑的工作区与预设，
  // 而 DSH 对缺省字段有自己的默认（与 Web 点"新建会话"一致）。
  assert.deepEqual(seen[0]![0], {}, '不该替电脑猜 workspaceId / cwd / agentPreset')
})

test('给了的参数原样过线，没给的一个都不补', async () => {
  const seen: unknown[][] = []
  const handlers = build(seen)

  // hero 上选工作区 / 模式之后"开一个新任务"走的就是这两个字段
  // （`.agents/notes/implemented/2026-10-17-blank-session-hero.md`）：
  // 选预设**不走** `agentPresets.select`，因为那条路对跑过一轮的会话会拒
  // （`agent-preset/locked`），而这里带上去根本不会碰到那条限制。
  await handlers['session.create']!(
    { workspaceId: 'ws-1', agentPreset: 'standard' },
    {},
  )

  assert.deepEqual(seen[0]![0], { workspaceId: 'ws-1', agentPreset: 'standard' })
})

test('非字符串字段：protocol/bad-frame，不去问 DSH', async () => {
  const seen: unknown[][] = []
  const handlers = build(seen)

  let caught: { code?: string } | undefined
  try {
    await handlers['session.create']!({ workspaceId: 42 as never }, {})
  } catch (error) {
    caught = error as { code?: string }
  }
  assert.equal(caught?.code, 'protocol/bad-frame')
  assert.equal(seen.length, 0, '参数就不对，不该去问 DSH')
})

test('DSH 侧失败：照旧抛给上层（手机弹错误，不假装建成了）', async () => {
  const handlers = build([], { createShouldThrow: true })

  // 用 try/catch 而不是 `assert.rejects`：handler 的静态返回类型是
  // `Promise<unknown> | unknown`（`MethodHandler`），`assert.rejects` 只收 Promise。
  let caught: Error | undefined
  try {
    await handlers['session.create']!({}, {})
  } catch (error) {
    caught = error as Error
  }
  assert.match(caught?.message ?? '', /DSH 拒绝新建/)
})

test('session.create 在封闭集里，且要幂等键', async () => {
  const seen: unknown[][] = []
  const handlers = build(seen)
  // 手机侧 `AppModel.createSession()` 用 `new-<时间戳>` 当 requestId；
  // 这里只验"这个方法确实接上了"——幂等键本身由 `idempotency.ts` 管。
  assert.equal(typeof handlers['session.create'], 'function')
  await handlers['session.create']!({}, {})
  assert.equal(seen.length, 1)
})
