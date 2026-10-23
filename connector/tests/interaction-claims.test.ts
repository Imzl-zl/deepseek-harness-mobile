/**
 * `interaction-claims.ts`：把 prompt 送到哪条连接、看护到人类回答或 fail-closed。
 *
 * 这个文件替换掉的是 `index.ts` 里那个**永远跑不到**的 fail-closed 桩。下面几条用例
 * 钉住的是它接上之后必须成立的行为，其中三条是"绝不放行"的硬规则：
 *
 * 1. 看护超时 / 断开 / 取消 / 没有活连接 → 审批 `reject`、提问**抛错**；
 * 2. 提问侧**绝不返回空答案**（`{answers: []}` 会被 DSH 读成"用户跳过了每一题"）；
 * 3. 会话被替换时丢弃答复（与 DSH"迟到即丢弃"同构）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  APPROVAL_ALLOW_LABEL,
  createInteractionPort,
  type InteractionPortDeps,
  type UnhandledInteraction,
} from '../src/interaction-claims.js'
import { createDevicePresence } from '../src/presence.js'
import type { ApprovalPrompt, QuestionPrompt } from '../src/dsh/interactions.js'

interface Harness {
  port: ReturnType<typeof createInteractionPort>
  presence: ReturnType<typeof createDevicePresence>
  unhandled: UnhandledInteraction[]
}

function build(patch: Partial<InteractionPortDeps> = {}, paired = true): Harness {
  const presence = createDevicePresence({
    pairedAtOf: (devId) => (paired && devId === 'dev-1' ? 1 : undefined),
  })
  presence.online('dev-1')
  const unhandled: UnhandledInteraction[] = []
  const port = createInteractionPort({
    presence,
    onUnhandled: (record) => unhandled.push(record),
    ...patch,
  })
  return { port, presence, unhandled }
}

const approval = (patch: Partial<ApprovalPrompt> = {}): ApprovalPrompt => ({
  sid: 'sid_1',
  callId: 'call-1',
  toolName: 'bash',
  ...patch,
})

const question = (patch: Partial<QuestionPrompt> = {}): QuestionPrompt => ({
  sid: 'sid_1',
  callId: 'call-q',
  questions: [{ id: 'q1', question: '继续吗' }],
  ...patch,
})

/** 让出事件循环，让 `awaitAnswer` 里的 promise 真正挂上。 */
const tick = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))

test('审批：手机答"允许一次"→ allow-once；答别的 → reject', { timeout: 60_000 }, async () => {
  const { port } = build()
  const pending = port.askApproval(approval(), 'dev-1')
  await tick()
  assert.equal(port.pending, 1, 'claim 必须在途，否则答复回来时无处可去')

  assert.equal(
    // **字面值，不 import 常量**：这条钉的是跨端契约的那个字符串。用常量来断等于恒真
    // （改常量两边一起改，红不了 —— 实测过）。
    port.settleClaim('sid_1', 'call-1', [{ id: 'call-1', selected: ['allowed-once'] }]),
    true,
  )
  assert.equal(await pending, 'allow-once')
  assert.equal(port.pending, 0, '收束后要撤：否则在途表只涨不消')

  // 词汇表之外的标签一律读成拒绝 —— 与 DSH 把野值归一成 unavailable 同向。
  const rejected = port.askApproval(approval({ callId: 'call-2' }), 'dev-1')
  await tick()
  assert.equal(port.settleClaim('sid_1', 'call-2', [{ id: 'call-2', selected: ['whatever'] }]), true)
  assert.equal(await rejected, 'reject')
})

test('审批：空 selected 且无 custom = 显式跳过，读成拒绝而不是崩溃', { timeout: 60_000 }, async () => {
  const { port } = build()
  const pending = port.askApproval(approval(), 'dev-1')
  await tick()
  // DSH 把"空 selected 且无 custom"定义为合法跳过（`tool-ask-user/src/timed.ts:172,179`），
  // 连接器不得拦截。审批侧它天然落在"没有 allowed-once 标签"上。
  assert.equal(port.settleClaim('sid_1', 'call-1', [{ id: 'call-1', selected: [] }]), true)
  assert.equal(await pending, 'reject')
})

test('审批：设备不在线 → 抛错并留证，**不替用户决定**（不等满一个看护周期）', { timeout: 60_000 }, async () => {
  const { port, unhandled } = build()
  // **必须抛，不能返回 'reject'**：`'rejected'` 在 DSH 的原生语义里只代表
  // "用户点了拒绝"（`ui-approval/contract/slots.ts` 的 `answer()` 只接受
  // `'allowed-once' | 'rejected'`）。我们呈示不了就 reject，等于替用户做一个
  // 他没做过的决定，而且因为本应答者是 prepend 的，桌面还永远问不到。
  // 抛出去之后 `interactions.ts` 会归一成 `'unavailable'` —— 那才是"没人能答"。
  await assert.rejects(() => port.askApproval(approval(), 'dev-9'))
  assert.equal(unhandled.length, 1)
  assert.equal(unhandled[0]?.end, 'disconnected')
  assert.equal(unhandled[0]?.kind, 'approval')
})

/** 手动触发的看护定时器替身：`fire` 由 `schedule` 的回调写，测试在需要时调它。 */
function manualTimer() {
  const box: { fire: (() => void) | null } = { fire: null }
  return {
    box,
    schedule: (fn: () => void) => {
      box.fire = fn
      return () => {
        box.fire = null
      }
    },
  }
}

test('审批：看护超时 → 抛错 + 未处理记录（fail-closed，绝不静默放行）', { timeout: 60_000 }, async () => {
  const timer = manualTimer()
  const { port, unhandled } = build({ guardMs: 1000, schedule: timer.schedule })
  const pending = port.askApproval(approval(), 'dev-1')
  await tick()
  assert.ok(timer.box.fire !== null, '看护计时器必须在推题之前起表')
  timer.box.fire?.()
  await assert.rejects(() => pending, '看护收束必须抛 —— 返回 reject 会冒充用户的决定')
  assert.equal(unhandled.length, 1)
  assert.equal(unhandled[0]?.end, 'timeout')
  assert.equal(unhandled[0]?.code, 'interaction/not-pending')
})

test('审批：手机断开 → 抛错（不等超时，也不冒充用户决定）', { timeout: 60_000 }, async () => {
  const { port, presence, unhandled } = build({ guardMs: 10 * 60_000 })
  const pending = port.askApproval(approval(), 'dev-1')
  await tick()
  presence.offline('dev-1')
  await assert.rejects(() => pending)
  assert.equal(unhandled[0]?.end, 'disconnected')
})

test('审批：asker 的原 signal 取消 → 抛错', { timeout: 60_000 }, async () => {
  const { port, unhandled } = build({ guardMs: 10 * 60_000 })
  const controller = new AbortController()
  const pending = port.askApproval(approval(), 'dev-1', controller.signal)
  await tick()
  controller.abort()
  await assert.rejects(() => pending)
  assert.equal(unhandled[0]?.end, 'disconnected')
})

test('审批：会话被替换（答复的 sid 与在途 claim 不一致）→ 丢弃，不写进别的会话', { timeout: 60_000 }, async () => {
  const { port, unhandled } = build({ guardMs: 10 * 60_000 })
  const controller = new AbortController()
  const pending = port.askApproval(approval(), 'dev-1', controller.signal)
  await tick()
  assert.equal(
    port.settleClaim('sid_2', 'call-1', [{ id: 'call-1', selected: ['allowed-once'] }]),
    false,
    '认下它就是把一次批准写进一个已经不持有这个提问的会话',
  )
  assert.equal(port.pending, 1, 'claim 还在：看护随后自己走到超时并留证，不会无声无息')
  // 收尾：取消让看护立刻收束，否则这条用例会留下一个 10 分钟的定时器与一个永不兑现的 promise。
  controller.abort()
  await assert.rejects(() => pending, '会话被替换后没人答，看护收束必须抛而不是冒充用户决定')
  assert.equal(unhandled[0]?.end, 'disconnected')
})

test('提问：答案批次**原样转发**（一个字段都不翻译）', { timeout: 60_000 }, async () => {
  const { port } = build()
  const pending = port.askQuestion(question(), 'dev-1')
  await tick()
  assert.equal(
    port.settleClaim('sid_1', 'call-q', [
      { id: 'q1', selected: ['第二个'], custom: '补充一句' },
      { id: 'q2', selected: [] },
    ]),
    true,
  )
  assert.deepEqual(await pending, {
    answers: [
      { id: 'q1', selected: ['第二个'], custom: '补充一句' },
      { id: 'q2', selected: [] },
    ],
  })
})

test('提问：拿不到答案就抛，绝不返回空答案', { timeout: 60_000 }, async () => {
  const noCallId = build()
  await assert.rejects(
    () => noCallId.port.askQuestion(question({ callId: undefined }), 'dev-1'),
    /callId/,
    '没有 callId 就没有稳定身份：答复回来时无从知道它属于哪一次 ask',
  )

  const offline = build()
  await assert.rejects(
    () => offline.port.askQuestion(question(), 'dev-9'),
    /空答案/,
    '返回 {answers: []} 会被 DSH 当成"用户跳过了每一题"，而链尾本应是 reject',
  )
  assert.equal(offline.unhandled[0]?.kind, 'question')

  const timer = manualTimer()
  const timedOut = build({ guardMs: 500, schedule: timer.schedule })
  const pending = timedOut.port.askQuestion(question(), 'dev-1')
  await tick()
  timer.box.fire?.()
  await assert.rejects(() => pending, /看护以 timeout 收束/)
  assert.equal(timedOut.unhandled[0]?.end, 'timeout')
})

test('审批：`allowed-once` 标签与 DSH 的 outcome 词汇表逐字一致（跨端契约）', () => {
  // 这个字符串是**跨端契约**：`app/lib/model/interaction.dart` 有同名同值的一个，
  // 手机发回来的 `selected` 必须含它。用字面值断常量本身 ——
  // 用常量断常量的行为用例是恒真的（实测：改常量值，两条行为用例全绿）。
  assert.equal(APPROVAL_ALLOW_LABEL, 'allowed-once')
})

test('settleClaim 对没有在途 claim 的 callId 返回 false（提问路由继续走 DSH）', { timeout: 60_000 }, async () => {
  const { port } = build()
  assert.equal(port.settleClaim('sid_1', 'nope', [{ id: 'x', selected: [] }]), false)
  assert.equal(port.pending, 0)
})
