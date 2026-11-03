import assert from "node:assert/strict"
import { test } from "node:test"

import { createFailureLockout } from "../src/lockout.ts"

test("连错 5 次就锁：第 5 次之后 blocked，锁定期内连正确密码也不放行", () => {
  let at = 1_000
  const lockout = createFailureLockout({ failures: 5, cooldownMs: 60_000, now: () => at })

  for (let i = 1; i <= 4; i += 1) {
    const state = lockout.fail("ip")
    assert.equal(state.blocked, false, `第 ${i} 次不该锁`)
    assert.equal(state.failures, i)
  }
  const fifth = lockout.fail("ip")
  assert.equal(fifth.blocked, true, "第 5 次要锁")
  assert.equal(fifth.retryAfterMs, 60_000)

  at += 1_000
  const during = lockout.stateOf("ip")
  assert.equal(during.blocked, true, "锁定期内仍然是锁着的")
  assert.equal(during.retryAfterMs, 59_000)
})

test("成功一次清零：能成功就说明不是爆破方", () => {
  const lockout = createFailureLockout({ failures: 5, cooldownMs: 60_000 })
  lockout.fail("ip")
  lockout.fail("ip")
  lockout.clear("ip")
  const state = lockout.stateOf("ip")
  assert.equal(state.blocked, false)
  assert.equal(state.failures, 0, "清完之后要从 1 重新数")
})

test("冷却结束自动放行；再错一次从头数（不立刻再锁）", () => {
  let at = 0
  const lockout = createFailureLockout({ failures: 5, cooldownMs: 60_000, now: () => at })
  for (let i = 0; i < 5; i += 1) lockout.fail("ip")
  assert.equal(lockout.stateOf("ip").blocked, true)

  at = 60_001
  assert.equal(lockout.stateOf("ip").blocked, false, "到期自动放行")
  const again = lockout.fail("ip")
  assert.equal(again.blocked, false, "放行后重新攒：一次手误不该把自己永远锁在门外")
  assert.equal(again.failures, 1)
})

test("failures: 0 = 关闭（显式关掉，不是默认行为）", () => {
  const lockout = createFailureLockout({ failures: 0, cooldownMs: 60_000 })
  for (let i = 0; i < 50; i += 1) {
    assert.equal(lockout.fail("ip").blocked, false)
  }
})

test("按地址分桶：锁了 A 不影响 B", () => {
  const lockout = createFailureLockout({ failures: 2, cooldownMs: 60_000 })
  lockout.fail("a")
  lockout.fail("a")
  assert.equal(lockout.stateOf("a").blocked, true)
  assert.equal(lockout.stateOf("b").blocked, false)
})
