/**
 * **真实 DSH 清单**（归一化）→ 适配器 → handler 的回归。
 *
 * 夹具 `fixtures/real-dsh-sessions.json` 由 `connector/tools/import-real-sessions.mjs`
 * 从一次真实网关的 `session/list` 应答生成：358 条真实会话，按**形状签名**去重成
 * 20 条（同一形状只留第一条），值归一化成占位、键/类型/嵌套/枚举原样保留。
 *
 * ## 为什么这条用例值得单独存在
 *
 * 金样机器过去喂给 handler 的 `sessions` 端口是**手写的端口行**（`dshSessionId` /
 * `subagent`…），等于绕过了 `createSessionsAdapter` —— "DSH 字段 → 行"这一步
 * 在金样链路上从未被真实数据走过（2026-10-26 评审的第 2 条）。
 *
 * 这里同时钉两件事：
 * 1. 适配器吃的是 **DSH 自己的 `SessionSummary`**（类型来自 DSH 包），逐字段映射、
 *    不把 `agentAvailable` / `formatStatus` / `sessionId` / `origin` 带过线；
 * 2. handler 过线后只剩 `sid`（别名），且真实 id 一个都不出现。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

import type { SessionSummary } from '@deepseek-ai/dsh-api-session-controller/types'

import { createSessionsAdapter } from '../src/dsh/sessions.js'
import { sessionListHandlerFor } from './support/fixture-handlers.js'

const REAL = new URL('./fixtures/real-dsh-sessions.json', import.meta.url)
const items = JSON.parse(readFileSync(REAL, 'utf8')) as SessionSummary[]

test('真实清单：每种形状一条，适配器逐字段映射（DSH 字段不过线）', async () => {
  assert.equal(items.length, 20, '形状签名去重后应当正好 20 条，变了就重新生成夹具')

  const controller = {
    list: async () => ({ items }),
  }
  const rows = await createSessionsAdapter(controller as never).list()

  assert.equal(rows.length, items.length)
  for (const [index, row] of rows.entries()) {
    const item = items[index]
    assert.ok(item !== undefined)
    assert.equal(row.dshSessionId, item.sessionId)
    assert.equal(row.updatedAt, item.updatedAt)
    assert.equal(row.running, item.running)
    assert.equal(row.blank, item.blank)
    assert.equal(row.subagent, item.origin === 'subagent')
    // 父级**只对子会话**给：普通会话多一个 parentSessionId 会让手机以为它也是子级。
    if (item.origin === 'subagent') {
      assert.equal(row.parentSessionId, item.parentSessionId)
    } else {
      assert.equal('parentSessionId' in row, false)
    }
    // DSH 侧字段与"行"无关的，一个都不许出现。
    for (const key of ['sessionId', 'agentAvailable', 'formatStatus', 'origin']) {
      assert.equal(key in row, false, `适配器把 ${key} 带过线了`)
    }
  }
})

test('真实清单过 handler：只剩 sid（别名），真实 id 一个都不出现', async () => {
  const handler = sessionListHandlerFor(items)
  const result = (await handler({}, undefined as never)) as {
    sessions: Record<string, unknown>[]
  }

  assert.equal(result.sessions.length, items.length)
  const wire = JSON.stringify(result)

  // 归一化里的 id 是 `sid_0000`…；别名是 `sid_r0000`…（不透明、与 DSH id 不同）。
  for (const item of items) {
    assert.equal(
      wire.includes(item.sessionId),
      false,
      `DSH 会话 id 泄漏到线上：${item.sessionId}`,
    )
  }
  for (const leaked of ['"sessionId"', '"agentAvailable"', '"formatStatus"', '"origin"']) {
    assert.equal(wire.includes(leaked), false, `字段泄漏：${leaked}`)
  }

  const sids = new Set<string>()
  for (const [index, row] of result.sessions.entries()) {
    const sid = row['sid']
    assert.equal(typeof sid, 'string', `第 ${index + 1} 行的 sid 不是字符串`)
    assert.match(String(sid), /^sid_r\d{4}$/, '手机只见不透明别名')
    sids.add(String(sid))
    // 手机侧当成必填的五个恒发键（`handlers.ts:739-769`）。
    for (const key of ['sid', 'updatedAt', 'running', 'blank', 'subagent']) {
      assert.equal(key in row, true, `第 ${index + 1} 行缺 ${key}`)
    }
  }
  assert.equal(sids.size, items.length, '20 行应当各有一个不同的别名')
})
