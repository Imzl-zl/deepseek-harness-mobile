/**
 * 会话增量缓冲的回归（契约 §5.5）。
 *
 * 这一层管的是**内存与不丢事件的交换**：裁早了会丢事件（手机上表现为"中间少了一段"），
 * 裁晚了会涨到超限。所以断言写的都是"哪一刻允许裁、裁到哪、裁完还能不能增量"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createSessionBuffer } from '../src/session-buffer.js'

const body = (n: number): string => `{"seq":${n}}`
const event = (seq: number): { seq: number; body: string } => ({ seq, body: body(seq) })

function setup(paired: string[] = ['dev-1'], limits: { maxFrames?: number; maxBytes?: number } = {}) {
  const warnings: string[] = []
  const log = {
    info: () => {},
    debug: () => {},
    error: () => {},
    warn: (message: string) => warnings.push(message),
  }
  const buffer = createSessionBuffer({
    pairedDevices: () => paired,
    log,
    ...limits,
  })
  return { buffer, warnings, paired }
}

test('未获确认时一行都不裁（发出去不等于对方写下去了）', () => {
  const { buffer } = setup()
  for (const seq of [1, 2, 3]) buffer.record('sid_1', event(seq))

  // 没 ack 过：裁剪点是 0。
  assert.equal(buffer.ack('sid_1', 'dev-1', 0), 0)
  assert.equal(buffer.stats.frames, 3)
  assert.deepEqual(
    buffer.tailFrom('sid_1', 0)?.map((item) => item.seq),
    [1, 2, 3],
  )
})

test('全部配对设备都确认过，才裁掉那段头部', () => {
  const { buffer } = setup(['dev-1', 'dev-2'])
  for (const seq of [1, 2, 3, 4]) buffer.record('sid_1', event(seq))

  // 一台确认到 3 不够：另一台还没确认，裁了它就会丢 1..3。
  assert.equal(buffer.ack('sid_1', 'dev-1', 3), 0)
  assert.equal(buffer.stats.frames, 4, '慢的那台没确认之前不许裁')

  assert.equal(buffer.ack('sid_1', 'dev-2', 2), 2, '两台都覆盖到 2 之后才可以裁 1..2')
  assert.deepEqual(
    buffer.tailFrom('sid_1', 0),
    undefined,
    '裁过 1..2 之后，从 0 恢复已经覆盖不到（要求快照）',
  )
  assert.deepEqual(
    buffer.tailFrom('sid_1', 2)?.map((item) => item.seq),
    [3, 4],
    '从确认过的水位接着恢复是增量的',
  )
})

test('水位只前进：乱序到达的旧 ack 不会把裁剪点拉回去', () => {
  const { buffer } = setup()
  for (const seq of [1, 2, 3]) buffer.record('sid_1', event(seq))
  assert.equal(buffer.ack('sid_1', 'dev-1', 3), 3)
  assert.equal(buffer.ack('sid_1', 'dev-1', 1), 0, '旧的 ack 不该再裁（那段已经不在了）')
  assert.equal(buffer.stats.frames, 0)
})

test('连续性：中间有洞就要求快照，而不是把洞补成"没有新事件"', () => {
  const { buffer } = setup(['dev-1'])
  buffer.record('sid_1', event(1))
  buffer.record('sid_1', event(2))
  buffer.record('sid_1', event(5)) // 3、4 没记（比如那两条是别的来源）
  assert.equal(
    buffer.tailFrom('sid_1', 1),
    undefined,
    '2 与 5 之间有洞 —— 返回空增量会让手机永远停在旧内容上',
  )
  assert.deepEqual(
    buffer.tailFrom('sid_1', 4)?.map((item) => item.seq),
    [5],
    '从 4 开始就没洞了',
  )
})

test('重复的 seq 是**幂等无操作**：两条连接订阅同一会话时不会各记一次、也不刷告警', () => {
  const { buffer, warnings } = setup()
  // 两条连接（监听面：两台设备）各自从水位 0 订阅同一会话，各自拿到同一批事件。
  // 第一台记下来，第二台的同一批 seq 必须**静默**当成"已经有了"。
  buffer.record('sid_1', event(1))
  buffer.record('sid_1', event(1))
  buffer.record('sid_1', event(2))
  buffer.record('sid_1', event(2))
  assert.equal(buffer.stats.frames, 2, '缓冲里只留一份（重复记会让重订时重放两条）')
  assert.deepEqual(
    buffer.tailFrom('sid_1', 0)?.map((item) => item.seq),
    [1, 2],
  )
  assert.deepEqual(warnings, [], '并发订阅是正常形态，不是告警（原来的实现每条刷一次 warn）')
})

test('倒退的 seq 也不记、也不告警（缓冲是追加式的，插不进更旧的那段）', () => {
  const { buffer, warnings } = setup()
  buffer.record('sid_1', event(5))
  // 另一条连接从更旧的水位追上来：它手里有 1..5，而我们只有 5。
  // 缓冲不能把 1..4 插到 5 前面（结构是追加式的）—— 覆盖不到时 `tailFrom` 会要求快照，
  // 那是安全的退化，所以这里不记是对的、也不是异常。
  buffer.record('sid_1', event(4))
  buffer.record('sid_1', event(1))
  assert.equal(buffer.stats.frames, 1)
  assert.deepEqual(warnings, [])
  assert.equal(buffer.tailFrom('sid_1', 0), undefined, '覆盖不到就要求快照（不是"没有新事件"）')
})

test('超限：先按已确认的部分裁；裁不动才置位"只允许快照"', () => {
  // 条数上限设 3，方便构造。
  const { buffer, warnings } = setup(['dev-1'], { maxFrames: 3 })
  for (const seq of [1, 2, 3, 4]) buffer.record('sid_1', event(seq))

  // 一条都没确认：裁不动 → 只允许快照（不许假装还能增量）。
  assert.equal(buffer.tailFrom('sid_1', 0), undefined)
  assert.equal(buffer.stats.frames, 4, '未确认的部分不裁（宁可超限也不丢）')
  assert.match(warnings.join('\n'), /超限且未获全部设备确认/)

  // 确认之后可以裁到上限以内，此时恢复增量能力。
  buffer.ack('sid_1', 'dev-1', 2)
  assert.deepEqual(
    buffer.tailFrom('sid_1', 2)?.map((item) => item.seq),
    [3, 4],
    '裁掉已确认的两条之后又回到"能增量"',
  )
})

test('forget：会话不再被订阅时释放缓冲与水印', () => {
  const { buffer } = setup()
  buffer.record('sid_1', event(1))
  buffer.record('sid_2', event(1))
  assert.equal(buffer.stats.sessions, 2)
  buffer.forget('sid_1')
  assert.equal(buffer.stats.sessions, 1)
  assert.equal(buffer.tailFrom('sid_1', 0), undefined)
})

test('一台设备都没配对：裁剪点是 0（不能因为"没有设备"就当成全都确认了）', () => {
  const { buffer } = setup([])
  for (const seq of [1, 2]) buffer.record('sid_1', event(seq))
  assert.equal(buffer.ack('sid_1', 'dev-1', 2), 0)
  assert.equal(buffer.stats.frames, 2)
})
