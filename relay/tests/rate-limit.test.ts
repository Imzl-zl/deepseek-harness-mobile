/**
 * 限流的回归（契约 §12 / §3.1 的 `rate-limited`）。
 *
 * 时钟是注入的，所以"补充 / 封顶 / 拒绝 / 重试时间"四条语义都能被精确断言 ——
 * 不写"睡一会儿再看"那种又慢又脆的测试。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createRateLimiter } from '../src/rate-limit.ts'

function setup(patch: { capacity?: number; refillPerSecond?: number } = {}) {
  let clock = 1_000_000
  const limiter = createRateLimiter({
    capacity: patch.capacity ?? 3,
    refillPerSecond: patch.refillPerSecond ?? 1,
    now: () => clock,
  })
  return { limiter, advance: (ms: number) => (clock += ms) }
}

test('突发：容量内放行，超出即拒（桶是突发的上限）', () => {
  const { limiter } = setup({ capacity: 3 })
  assert.equal(limiter.take('dev-1').allowed, true)
  assert.equal(limiter.take('dev-1').allowed, true)
  assert.equal(limiter.take('dev-1').allowed, true)
  const denied = limiter.take('dev-1')
  assert.equal(denied.allowed, false, '第四次被拒')
  assert.equal(denied.retryAfterMs, 1_000, '按 1 次/秒补充，1000ms 后可再试')
})

test('补充：等待之后按速率恢复，**封顶在容量**（闲置不会攒出更大的突发）', () => {
  const { limiter, advance } = setup({ capacity: 3, refillPerSecond: 1 })
  for (let i = 0; i < 3; i += 1) assert.equal(limiter.take('dev-1').allowed, true)
  assert.equal(limiter.take('dev-1').allowed, false)

  advance(1_000)
  assert.equal(limiter.take('dev-1').allowed, true, '补回 1 个')
  assert.equal(limiter.take('dev-1').allowed, false, '只补回 1 个')

  advance(60_000)
  // 闲置一分钟本可补 60 个，但桶封顶在 3 —— 否则"歇一会儿再来"就能无限突发。
  assert.equal(limiter.take('dev-1').allowed, true)
  assert.equal(limiter.take('dev-1').allowed, true)
  assert.equal(limiter.take('dev-1').allowed, true)
  assert.equal(limiter.take('dev-1').allowed, false, '封顶之后仍然只有容量那么多')
})

test('按身份分开：一台设备被限住不影响别人（限流最常见的自伤）', () => {
  const { limiter } = setup({ capacity: 1 })
  assert.equal(limiter.take('dev-1').allowed, true)
  assert.equal(limiter.take('dev-1').allowed, false)
  assert.equal(limiter.take('dev-2').allowed, true, '别的身份有自己的桶')
})

test('拒绝也要结算补充量（否则重试时间会算错）', () => {
  const { limiter, advance } = setup({ capacity: 1, refillPerSecond: 1 })
  assert.equal(limiter.take('dev-1').allowed, true)
  const denied = limiter.take('dev-1')
  assert.equal(denied.retryAfterMs, 1_000)

  advance(600)
  const half = limiter.take('dev-1')
  assert.equal(half.allowed, false)
  assert.equal(half.retryAfterMs, 400, '距上次拒绝已过 600ms，只剩 400ms')
  advance(400)
  assert.equal(limiter.take('dev-1').allowed, true, '满 1000ms 时补回 1 个')
})

test('自清：取用足够多次之后，空闲桶会自己消失（不必等外部调用 sweep）', () => {
  // 容量 1、补充极快：于是"上一个身份"的桶很快就补满 = 与从没出现过等价。
  const { limiter, advance } = setup({ capacity: 1, refillPerSecond: 1_000 })
  limiter.take('dev-1')
  assert.equal(limiter.size, 1)

  advance(100)
  // 64 次取用触发一次自清（`SWEEP_EVERY`）：用同一个身份刷，避免新建桶干扰观察。
  for (let i = 0; i < 64; i += 1) limiter.take('dev-1')
  assert.equal(limiter.size, 1, '只剩正在用的这个桶：空闲的 dev-1 旧桶已被清掉')

  // 反证：如果不自清，下面的身份们会一直留在表里。
  for (let i = 0; i < 10; i += 1) limiter.take(`idle-${i}`)
  assert.equal(limiter.size, 11)
  advance(100)
  for (let i = 0; i < 64; i += 1) limiter.take('dev-1')
  assert.equal(limiter.size, 1, '十个空闲身份也在下一次自清里消失')
})

test('sweep：完全补满的桶与"从没出现过"等价，可以清掉', () => {
  const { limiter, advance } = setup({ capacity: 2, refillPerSecond: 1 })
  limiter.take('dev-1')
  limiter.take('dev-2')
  assert.equal(limiter.size, 2)

  advance(2_000)
  assert.equal(limiter.sweep(), 2)
  assert.equal(limiter.size, 0, '清掉之后不会白占内存')
})
