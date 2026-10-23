/**
 * `interaction-claims.ts`：把手机的答复配给在途的那一次交互。
 *
 * 这一层**只交结算单**（`answered` / `withdrawn`），回话由 gateway client 决定：
 * `answered` → `{kind:'result'}`；`withdrawn` → **什么都不回**。
 *
 * **键是 `itemId`**（手机那张卡的 id）：审批 `i:<approval/asked.id>`、提问 `t:<callId>`。
 * 端口不认识这两种交互的差别（那是 `interaction-face.ts` 的事），它只认"这一个键"。
 *
 * **没有计时器**：DSH 的审批没有"等多久"这个概念，端口也就不接受 `guardMs` / `schedule`
 * 这类参数（`createInteractionPort()` 不接任何依赖）—— 这条约束在签名上，不靠测试。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  APPROVAL_ALLOW_LABEL,
  createInteractionPort,
  type ClaimRequest,
} from '../src/interaction-claims.js'

const approval = (patch: Partial<ClaimRequest> = {}): ClaimRequest => ({
  sid: 'sid_1',
  itemId: 'i:a1',
  ...patch,
})

const question = (patch: Partial<ClaimRequest> = {}): ClaimRequest => ({
  sid: 'sid_1',
  itemId: 't:q1',
  ...patch,
})

/** 让出事件循环，让 `new Promise` 里的 resolve 真正挂上。 */
const tick = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))

test('审批：手机答"允许一次"→ answered+allowed-once；答别的 → answered+rejected', { timeout: 60_000 }, async () => {
  const port = createInteractionPort()
  const pending = port.askApproval(approval())
  await tick()
  assert.equal(port.pending, 1, 'claim 必须在途，否则答复回来时无处可去')

  assert.equal(
    // **字面值，不 import 常量**：这条钉的是跨端契约的那个字符串。用常量来断等于恒真
    // （改常量两边一起改，红不了 —— 实测过）。
    port.settleClaim('sid_1', 'i:a1', [{ id: 'i:a1', selected: ['allowed-once'] }]),
    true,
  )
  assert.deepEqual(await pending, { kind: 'answered', value: 'allowed-once' })
  assert.equal(port.pending, 0, '收束后要撤：否则在途表只涨不消')

  // 词汇表之外的标签一律读成拒绝 —— 与 DSH 把野值归一成 unavailable 同向。
  const rejected = port.askApproval(approval({ itemId: 'i:a2' }))
  await tick()
  assert.equal(port.settleClaim('sid_1', 'i:a2', [{ id: 'i:a2', selected: ['whatever'] }]), true)
  assert.deepEqual(await rejected, { kind: 'answered', value: 'rejected' })
})

test('审批：空 selected 且无 custom = 显式跳过，读成拒绝而不是崩溃', { timeout: 60_000 }, async () => {
  const port = createInteractionPort()
  const pending = port.askApproval(approval())
  await tick()
  // DSH 把"空 selected 且无 custom"定义为合法跳过（`tool-ask-user/src/timed.ts:172,179`），
  // 连接器不得拦截。审批侧它天然落在"没有 allowed-once 标签"上。
  assert.equal(port.settleClaim('sid_1', 'i:a1', [{ id: 'i:a1', selected: [] }]), true)
  assert.deepEqual(await pending, { kind: 'answered', value: 'rejected' })
})

test('cancelClaim：gateway 说这条已经结算 → withdrawn、摘表、不再重投', { timeout: 60_000 }, async () => {
  const port = createInteractionPort()
  const pending = port.askApproval(approval({ redeliver: { seq: 7, body: '{}' } }))
  await tick()
  assert.equal(port.cancelClaim('i:a1'), true, '撤掉在途 claim 必须报"撤到了"')
  assert.deepEqual(await pending, { kind: 'withdrawn' })
  assert.equal(port.pending, 0)
  assert.deepEqual(port.pendingAsks('sid_1'), [], '撤掉的 claim 不再重投')
  assert.equal(port.cancelClaim('i:a1'), false, '第二次是 no-op（已经不在表里）')
  assert.equal(port.cancelClaim('nope'), false, '不认识的 itemId 也是 no-op')
})

test('settleClaim 与 cancelClaim 谁先到谁赢：先结算的收口，后到的是 no-op', { timeout: 60_000 }, async () => {
  const answered = createInteractionPort()
  const answeredPending = answered.askApproval(approval())
  await tick()
  assert.equal(
    answered.settleClaim('sid_1', 'i:a1', [{ id: 'i:a1', selected: [APPROVAL_ALLOW_LABEL] }]),
    true,
  )
  assert.equal(answered.cancelClaim('i:a1'), false, '已经结算的 claim 不该还能被撤')
  assert.deepEqual(await answeredPending, { kind: 'answered', value: 'allowed-once' })

  const cancelled = createInteractionPort()
  const cancelledPending = cancelled.askApproval(approval())
  await tick()
  assert.equal(cancelled.cancelClaim('i:a1'), true)
  assert.equal(
    cancelled.settleClaim('sid_1', 'i:a1', [{ id: 'i:a1', selected: [APPROVAL_ALLOW_LABEL] }]),
    false,
    '撤掉之后手机上再点也答不进来（gateway 那边已经结算了）',
  )
  assert.deepEqual(await cancelledPending, { kind: 'withdrawn' })
})

test('审批：会话被替换（答复的 sid 与在途 claim 不一致）→ 丢弃，claim 继续等', { timeout: 60_000 }, async () => {
  const port = createInteractionPort()
  port.askApproval(approval())
  await tick()
  assert.equal(
    port.settleClaim('sid_2', 'i:a1', [{ id: 'i:a1', selected: ['allowed-once'] }]),
    false,
    '认下它就是把一次批准写进一个已经不持有这个提问的会话',
  )
  assert.equal(
    port.pending,
    1,
    'claim 还在，也**不会**自己超时 —— 只有手机答、gateway 撤、或插件卸载才收束（原生没有超时）',
  )
})

test('提问：答案批次**原样转发**（一个字段都不翻译）', { timeout: 60_000 }, async () => {
  const port = createInteractionPort()
  const pending = port.askQuestion(question())
  await tick()
  assert.equal(
    port.settleClaim('sid_1', 't:q1', [
      { id: 'q1', selected: ['第二个'], custom: '补充一句' },
      { id: 'q2', selected: [] },
    ]),
    true,
  )
  assert.deepEqual(await pending, {
    kind: 'answered',
    value: {
      answers: [
        { id: 'q1', selected: ['第二个'], custom: '补充一句' },
        { id: 'q2', selected: [] },
      ],
    },
  })
})

test('审批与提问并存：两条 claim 互不干扰，各按自己的 itemId 收束', { timeout: 60_000 }, async () => {
  const port = createInteractionPort()
  const ap = port.askApproval(approval())
  const q = port.askQuestion(question())
  await tick()
  assert.equal(port.pending, 2)

  assert.equal(port.cancelClaim('t:q1'), true, '撤提问不该碰到审批')
  assert.deepEqual(await q, { kind: 'withdrawn' })
  assert.equal(port.pending, 1)

  assert.equal(port.settleClaim('sid_1', 'i:a1', [{ id: 'i:a1', selected: [] }]), true)
  assert.deepEqual(await ap, { kind: 'answered', value: 'rejected' })
  assert.equal(port.pending, 0)
})

test('pendingAsks：只给仍在途的 ask（原 seq + body），结算后清空', { timeout: 60_000 }, async () => {
  const port = createInteractionPort()
  const redelivery = { seq: 7, body: '{"type":"approval/asked"}' }
  const pending = port.askApproval(approval({ redeliver: redelivery }))
  await tick()
  assert.deepEqual(port.pendingAsks('sid_1'), [redelivery], '重连重投的来源就是这张表')
  assert.deepEqual(port.pendingAsks('sid_2'), [], '别的会话拿不到这一条')
  assert.equal(
    port.settleClaim('sid_1', 'i:a1', [{ id: 'i:a1', selected: ['allowed-once'] }]),
    true,
  )
  await pending
  assert.deepEqual(port.pendingAsks('sid_1'), [], '已结算的不再重投')
})

test('审批：`allowed-once` 标签与 DSH 的 outcome 词汇表逐字一致（跨端契约）', () => {
  // 这个字符串是**跨端契约**：`app/lib/model/interaction.dart` 有同名同值的一个，
  // 手机发回来的 `selected` 必须含它。用字面值断常量本身 ——
  // 用常量断常量的行为用例是恒真的（实测：改常量值，两条行为用例全绿）。
  assert.equal(APPROVAL_ALLOW_LABEL, 'allowed-once')
})

test('端口不接受任何依赖：没有 guardMs / schedule 的位置 = 没有计时器（原生没有超时）', () => {
  // 这条是**签名上的约束**，不是行为断言：一旦有人给 `createInteractionPort` 加回
  // "看护超时"的参数，`length` 就变了 —— 那是设计变更，该连同契约 §6.2 一起改。
  assert.equal(createInteractionPort.length, 0)
})

test('settleClaim 对没有在途 claim 的 itemId 返回 false（提问路由继续走 DSH）', { timeout: 60_000 }, async () => {
  const port = createInteractionPort()
  assert.equal(port.settleClaim('sid_1', 'nope', [{ id: 'x', selected: [] }]), false)
  assert.equal(port.pending, 0)
})
