/**
 * 子代理适配器的回归（契约 §7）。
 *
 * 两处收窄必须钉住，它们都是"手机侧会拿到一屏 undefined"的来源：
 *
 * 1. `listDescendants` 是**可辨识联合**：`kind:'child'` 带 `activity`/`mode`/`label`/`hasChildren`，
 *    而 `kind:'diagnostic'` **只有** `reason`。拍平之后两类行不能混字段。
 * 2. `listChildren` 的行**根本没有** `activity` —— 活动态只能来自 `listDescendants`。
 *
 * 还有一条语义纪律：`activity` 只表示**驻留**，`inactive` **不得**被翻译成任何像"已结束"的措辞
 * （正常收工的子代理同样是 `inactive`，与崩溃不可区分）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import type { SubagentRuntime } from '@deepseek-ai/dsh-subagent'

import { createSubagentsPort } from '../src/dsh/subagents.js'

function fakeRuntime(overrides: Record<string, unknown>): SubagentRuntime {
  return overrides as unknown as SubagentRuntime
}

test('children：只映射该映射的字段，且不冒充活动态', async () => {
  let signal: AbortSignal | undefined
  const port = createSubagentsPort(
    fakeRuntime({
      listChildren: (parent: string, received?: AbortSignal) => {
        signal = received
        return Promise.resolve([
          { id: 'c1', createdAt: 10, mode: 'continuable', label: '子代理 A' },
          { id: 'c2', createdAt: 20, mode: 'one-shot' },
        ])
      },
    }),
  )

  const abort = new AbortController()
  const rows = await port.children('sess-1', abort.signal)

  assert.deepEqual(rows, [
    { id: 'c1', createdAt: 10, mode: 'continuable', label: '子代理 A' },
    { id: 'c2', createdAt: 20, mode: 'one-shot' },
  ])
  assert.equal(signal, abort.signal, '信号要透传（DSH 侧靠它取消）')
  for (const row of rows) {
    assert.equal('activity' in row, false, 'listChildren 的行没有活动态，不能凭空补一个')
  }
})

test('descendants：联合拍平 —— 诊断行不带 child 的字段，child 行带全', async () => {
  const port = createSubagentsPort(
    fakeRuntime({
      listDescendants: () =>
        Promise.resolve([
          {
            kind: 'child',
            id: 'c1',
            parentId: 'sess-1',
            depth: 1,
            mode: 'continuable',
            label: 'A',
            activity: 'running',
            hasChildren: true,
          },
          // 诊断行：**只有** reason。
          { kind: 'diagnostic', id: 'c2', parentId: 'sess-1', depth: 1, reason: 'corrupt' },
          {
            kind: 'child',
            id: 'c3',
            parentId: 'c1',
            depth: 2,
            mode: 'unknown',
            activity: 'inactive',
            hasChildren: false,
          },
        ]),
    }),
  )

  const rows = await port.descendants('sess-1')
  assert.deepEqual(rows[0], {
    kind: 'child',
    id: 'c1',
    parentId: 'sess-1',
    depth: 1,
    mode: 'continuable',
    label: 'A',
    activity: 'running',
    hasChildren: true,
  })
  assert.deepEqual(rows[1], {
    kind: 'diagnostic',
    id: 'c2',
    parentId: 'sess-1',
    depth: 1,
    reason: 'corrupt',
  })
  // 诊断行不该出现 child 的字段 —— 手机侧按 child 渲染它就会拿到一屏 undefined。
  const diagnostic = rows[1]
  assert.ok(diagnostic !== undefined && diagnostic.kind === 'diagnostic')
  for (const key of ['activity', 'mode', 'label', 'hasChildren']) {
    assert.equal(key in diagnostic, false, `诊断行不该有 ${key}`)
  }
  // `inactive` 原样传达：**不翻译**成任何像"已结束"的说法（正常收工也是 inactive）。
  assert.equal(rows[2]?.kind === 'child' ? rows[2].activity : undefined, 'inactive')
})
