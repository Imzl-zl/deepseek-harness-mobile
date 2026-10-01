/**
 * 推送摘要与合并的回归（契约 §9）。
 *
 * 这里钉的两件事都是**安全/隐私相关**的，不是功能细节：
 * 通知对象上没有可以承载正文的位置，以及 `doorbell` 档真的把工具名也剥掉。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { PUSH_COALESCE_MS, PUSH_TRIGGERS, createPushMerger } from '../src/push/index.js'

test('折叠：首条立即推，窗口内同类折进它，出窗后重新开一条', () => {
  const merger = createPushMerger()

  const first = merger.note('approval-pending', 'sid-1', {}, 0)
  assert.deepEqual(first, { trigger: 'approval-pending', sid: 'sid-1', count: 1 })

  // 窗口内同类：不推，只累加计数 —— 用户看到的是一张通知而不是一串。
  assert.equal(merger.note('approval-pending', 'sid-1', {}, 1_000), null)
  assert.equal(merger.note('approval-pending', 'sid-1', {}, PUSH_COALESCE_MS - 1), null)

  // 出窗：重新开一条，计数从头开始。
  const again = merger.note('approval-pending', 'sid-1', {}, PUSH_COALESCE_MS)
  assert.deepEqual(again, { trigger: 'approval-pending', sid: 'sid-1', count: 1 })
})

test('折叠键是「同会话 + 同类型」，两个都相同才算同类', () => {
  const merger = createPushMerger()
  merger.note('approval-pending', 'sid-1', {}, 0)
  // 不同会话：各自成桶。
  assert.notEqual(merger.note('approval-pending', 'sid-2', {}, 0), null)
  // 同会话不同类型：也各自成桶。
  assert.notEqual(merger.note('question-pending', 'sid-1', {}, 0), null)
  assert.equal(merger.activeBuckets, 3)
})

test('隐私档位：doorbell 连工具名都不带，rich 带', () => {
  const rich = createPushMerger('rich')
  const richNotice = rich.note('approval-pending', 'sid-1', { toolName: 'bash' }, 0)
  assert.equal(richNotice?.toolName, 'bash')

  const doorbell = createPushMerger('doorbell')
  const bellNotice = doorbell.note('approval-pending', 'sid-1', { toolName: 'bash' }, 0)
  assert.deepEqual(bellNotice, { trigger: 'approval-pending', sid: 'sid-1', count: 1 })
  assert.equal('toolName' in (bellNotice ?? {}), false, 'doorbell 不该出现工具名键')
})

test('切换档位只影响之后生成的通知', () => {
  const merger = createPushMerger('doorbell')
  const before = merger.note('approval-pending', 'sid-1', { toolName: 'bash' }, 0)
  assert.equal(before?.toolName, undefined)

  merger.setLevel('rich')
  assert.equal(merger.level, 'rich')
  const after = merger.note('question-pending', 'sid-1', { toolName: 'ask_user' }, 0)
  assert.equal(after?.toolName, 'ask_user')
})

test('通知对象是白名单字段，没有可以承载正文的位置', () => {
  const merger = createPushMerger('rich')
  const notice = merger.note('turn-failed', 'sid-1', { toolName: 'bash' }, 0)
  assert.ok(notice !== null)
  // 一旦有人给 PushNotice 加了 content / body / text 之类的字段，这条会红 ——
  // 推送通道（厂商推送服务）不在端到端加密范围内，正文绝不能进去。
  assert.deepEqual(Object.keys(notice).sort(), ['count', 'sid', 'toolName', 'trigger'])
})

test('四类触发都在契约的词表里', () => {
  assert.deepEqual([...PUSH_TRIGGERS].sort(), [
    'approval-pending',
    'job-settled',
    'question-pending',
    'turn-failed',
  ])
})
