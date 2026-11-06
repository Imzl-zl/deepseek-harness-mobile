/**
 * **两台设备同时看见同一个待办**（撤掉独占准入之后才可能的形状）。
 *
 * ## 它钉的是哪一件事
 *
 * 在途 claim 表是**挂载级一份**（`interaction-claims.ts`），不是每设备一份。所以：
 *
 * - A 答了 → 这一项收束、表里删掉，A 的连接拿到 `ok:true`；
 * - B 再答同一项 → 表里已经没有它，`settleClaim` 回 `false`，落进 `interaction/not-pending`
 *   （契约 §3.1 的客户端动作是"刷新待处理列表"）。**不许出现"B 也答成功了"**，
 *   也不许把答复写给一个已经结算的交互。
 *
 * 顺带钉住两条容易退化的：
 *
 * 1. B 的迟到答复**不许**走到 DSH 的 `answer()`（appoval 没有"按 id 作答"的方法，
 *    调用它就是发明第二条路径）；
 * 2. 提问侧同一形状：`answer()` 回 `false` 也归 `not-pending`，不是错误也不是成功。
 *
 * 这条链路的两端都是真件：`createInteractionPort` + `createInteractionFace`，
 * 只有一个 `answer` 是替身（它代表 DSH）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { APPROVAL_ALLOW_LABEL, createInteractionPort } from '../src/interaction-claims.js'
import {
  createInteractionFace,
  type QuestionAgent,
  type QuestionProjection,
} from '../src/interaction-face.js'
import { ProtocolError } from '../src/protocol/errors.js'

/** 一个活的 root agent 标记：内核只拿它做品牌类型，运行期就是个对象。 */
const AGENT = { __dshLiveRootAgent: 'branded' } as unknown as QuestionAgent

/** 提问的投影：B 迟到时本地校验要先过，才走得到 `answer()` 那一支。 */
const OPEN_QUESTION: QuestionProjection = {
  active: [
    {
      callId: 'q1',
      state: 'open',
      questions: [{ id: 'scope', question: '改哪几个文件？' }],
    },
  ],
  settled: [],
}

/** 拿 `interaction/not-pending` 的错误码；不是这个错就让它抛出去。 */
async function errorCodeOf(run: () => unknown): Promise<string> {
  try {
    await run()
  } catch (error) {
    if (error instanceof ProtocolError) return error.code
    throw error
  }
  assert.fail('应当抛 protocol 错误（这一项已经不在待处理集合里）')
}

test('审批：A 答完之后 B 再答 → interaction/not-pending，且不碰 DSH 的 answer()', { timeout: 60_000 }, async () => {
  const claims = createInteractionPort()
  let answers = 0
  const face = createInteractionFace({
    answer: () => {
      answers += 1
      return false
    },
    agentOf: () => AGENT,
    projectionOf: () => undefined,
    settleClaim: (sid, itemId, batch) => claims.settleClaim(sid, itemId, batch),
  })

  const params = {
    sid: 'sid_1',
    itemId: 'i:approval-1',
    answers: [{ id: 'i:approval-1', selected: [APPROVAL_ALLOW_LABEL] }],
  }

  // ---- A：这一项在途，答了就此收束 ----
  const inFlight = claims.askApproval({ sid: 'sid_1', itemId: 'i:approval-1' })
  assert.deepEqual(face.respond(params), { itemId: 'i:approval-1' })
  assert.deepEqual(await inFlight, { kind: 'answered', value: 'allowed-once' })
  assert.equal(claims.pending, 0, '结算之后表里没有它了 —— claim 是挂载级一份，不是每设备一份')

  // ---- B：同样的请求晚到一步 ----
  const code = await errorCodeOf(() => face.respond(params))
  assert.equal(code, 'interaction/not-pending')
  assert.equal(answers, 0, '审批不在表里就是"已经答过"，绝不能退到 DSH 的 answer()')
})

test('提问：A 答完之后 B 再答 → interaction/not-pending（answer 回 false 同一条路）', { timeout: 60_000 }, async () => {
  const claims = createInteractionPort()
  const asked: string[] = []
  const face = createInteractionFace({
    // DSH：这个提问已经结束（不在 continued 集合里）→ false，**不是错误**。
    answer: (_agent, callId) => {
      asked.push(callId)
      return false
    },
    agentOf: () => AGENT,
    projectionOf: () => OPEN_QUESTION,
    settleClaim: (sid, itemId, batch) => claims.settleClaim(sid, itemId, batch),
  })

  const params = {
    sid: 'sid_1',
    itemId: 't:q1',
    answers: [{ id: 'scope', selected: ['core/'] }],
  }

  const inFlight = claims.askQuestion({ sid: 'sid_1', itemId: 't:q1' })
  assert.deepEqual(face.respond(params), { itemId: 't:q1' })
  assert.deepEqual(await inFlight, {
    kind: 'answered',
    value: { answers: [{ id: 'scope', selected: ['core/'] }] },
  })
  assert.equal(claims.pending, 0)

  const code = await errorCodeOf(() => face.respond(params))
  assert.equal(code, 'interaction/not-pending')
  assert.deepEqual(asked, ['q1'], 'B 的迟到答复走到 answer() 一次，被 DSH 判"已结束"')
})
