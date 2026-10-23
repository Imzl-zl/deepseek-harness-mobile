/**
 * `dsh/question-call.ts`：从会话日志里认出「这一次提问是哪一次 tool call」。
 *
 * **用真 `Session` 造事件，不手搓数组** —— 理由见 `support/session-log.ts` 的文件头。
 * 顺序也照 DSH 的循环：`tool/call` 在 execute 之前、`tool/result` 在之后，
 * 所以"应答者被调用时"这一格 = 只有 call、还没有 result。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { emptySession, openCall, settleCall } from './support/session-log.js'
import { ASK_USER_QUESTION_TOOL, resolveQuestionCall } from '../src/dsh/question-call.js'

test('唯一一条未结算的提问调用 → 就是它（应答者被调用时的真实形态）', () => {
  const session = emptySession()
  openCall(session, 'call-a')
  assert.deepEqual(resolveQuestionCall(session.snapshotEvents()), { kind: 'found', callId: 'call-a' })
})

test('有 tool/result 的调用被排除（结算过的不是这一次）', () => {
  const session = emptySession()
  settleCall(session, 'call-a', openCall(session, 'call-a'))
  assert.deepEqual(resolveQuestionCall(session.snapshotEvents()), { kind: 'none' })
})

test('两条未结算 → ambiguous，且两个 id 都留证（不猜）', () => {
  const session = emptySession()
  openCall(session, 'call-a')
  openCall(session, 'call-b')
  const resolution = resolveQuestionCall(session.snapshotEvents())
  assert.equal(resolution.kind, 'ambiguous')
  assert.deepEqual(
    resolution.kind === 'ambiguous' ? [...resolution.callIds].sort() : [],
    ['call-a', 'call-b'],
  )
})

test('已结算的不挡住未结算的：一老一新只剩新的', () => {
  const session = emptySession()
  settleCall(session, 'call-old', openCall(session, 'call-old'))
  openCall(session, 'call-new')
  assert.deepEqual(resolveQuestionCall(session.snapshotEvents()), { kind: 'found', callId: 'call-new' })
})

test('别的工具的调用不算提问（`bash` / `read` 都在日志里也一样）', () => {
  const session = emptySession()
  openCall(session, 'call-bash', 'bash')
  openCall(session, 'call-read', 'read')
  assert.deepEqual(resolveQuestionCall(session.snapshotEvents()), { kind: 'none' })
})

test('空日志 → none（程序化提问也落这一支：它不产生 tool/call）', () => {
  assert.deepEqual(resolveQuestionCall(emptySession().snapshotEvents()), { kind: 'none' })
})

test('同一条调用被记两次（重放/恢复）仍算一次，不因此变成 ambiguous', () => {
  const session = emptySession()
  openCall(session, 'call-a')
  openCall(session, 'call-a')
  assert.deepEqual(resolveQuestionCall(session.snapshotEvents()), { kind: 'found', callId: 'call-a' })
})

test('工具名是 `ask_user_question`（DSH 注册的那个，改名字这条会红）', () => {
  assert.equal(ASK_USER_QUESTION_TOOL, 'ask_user_question')
})
