/**
 * 幂等执行的回归（契约 §5.6、不变量 I8）。
 *
 * 这一层的每条规则都对应一种"重复生效"的事故形状，所以断言写的都是**执行次数**：
 * 命中缓存不该执行、并发重发不该执行第二次、失败必须允许重来、坏行不该让通道失能。
 * 只断言"返回值一样"是无效证据 —— 执行两次也可能返回一样的值。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createIdempotency, DEDUPE_CAPACITY, DEDUPE_SWEEP_LIMIT, DEDUPE_TTL_MS } from '../src/idempotency.js'
import type { ResponseEnvelope } from '../src/protocol/methods.js'
import { createMemoryDedupeRows } from './support/dedupe-rows.js'

/** 计数的执行闭包：返回 `{"n":N}`，并记录被调用了几次。 */
function counter(result: unknown = { accepted: true }): {
  execute: () => Promise<ResponseEnvelope>
  calls: () => number
} {
  let calls = 0
  return {
    calls: () => calls,
    execute: () => {
      calls += 1
      return Promise.resolve({ ok: true, result })
    },
  }
}

test('命中即回上次结果：第二次不执行', async () => {
  const rows = createMemoryDedupeRows()
  const idempotency = createIdempotency({ rows })
  const job = counter({ accepted: true })

  const first = await idempotency.run('k1', job.execute)
  const second = await idempotency.run('k1', job.execute)

  assert.deepEqual(first, { ok: true, result: { accepted: true } })
  assert.deepEqual(second, first, '重发必须拿到与第一次相同的应答')
  assert.equal(job.calls(), 1, '第二次绝不能执行')
  assert.equal(rows.size, 1)
  assert.equal(rows.get('k1')?.status, 'done')
})

test('不同键各自执行', async () => {
  const rows = createMemoryDedupeRows()
  const idempotency = createIdempotency({ rows })
  const job = counter()

  await idempotency.run('k1', job.execute)
  await idempotency.run('k2', job.execute)

  assert.equal(job.calls(), 2)
  assert.equal(rows.size, 2)
})

test('同键并发：合流成一次执行，两边拿到同一个应答', async () => {
  const rows = createMemoryDedupeRows()
  const idempotency = createIdempotency({ rows })

  let release: () => void = () => {}
  let calls = 0
  const execute = async (): Promise<ResponseEnvelope> => {
    calls += 1
    await new Promise<void>((resolve) => {
      release = resolve
    })
    return { ok: true, result: 'done' }
  }

  // 第一次还挂在执行里，第二次同键请求就到了（手机重发的真实形状）。
  const first = idempotency.run('k1', execute)
  const second = idempotency.run('k1', execute)
  assert.equal(idempotency.inFlight, 1, '同键只该有一个执行在飞')

  release()
  const [a, b] = await Promise.all([first, second])
  assert.equal(calls, 1, '合流之后只执行一次')
  assert.deepEqual(a, b)
  assert.equal(idempotency.inFlight, 0, '执行结束后不该留在飞行表里')
})

test('失败不进表：第二次仍会真的执行', async () => {
  const rows = createMemoryDedupeRows()
  const idempotency = createIdempotency({ rows })

  let calls = 0
  const failing = (): Promise<ResponseEnvelope> => {
    calls += 1
    return Promise.resolve({ ok: false, code: 'internal', message: '临时故障' })
  }

  const first = await idempotency.run('k1', failing)
  assert.equal(first.ok, false)
  assert.equal(rows.size, 0, '失败不该被记住 —— 否则一次瞬时故障会变成 24 小时死路')

  const second = await idempotency.run('k1', failing)
  assert.equal(second.ok, false)
  assert.equal(calls, 2, '失败之后必须允许重来')
})

test('执行抛异常：同样不记，且异常照原样抛给调用方', async () => {
  const rows = createMemoryDedupeRows()
  const idempotency = createIdempotency({ rows })

  await assert.rejects(
    () =>
      idempotency.run('k1', () => {
        throw new Error('炸了')
      }),
    /炸了/,
  )
  assert.equal(rows.size, 0)
  assert.equal(idempotency.inFlight, 0, '抛了也要把飞行表收干净，否则这个键永远合流到一个失败的 promise')
})

test('坏行：当未命中处理、清掉它、重新执行', async () => {
  const rows = createMemoryDedupeRows({ k1: { at: 1, status: 'done', resultRef: '不是 JSON' } })
  const idempotency = createIdempotency({ rows })
  const job = counter('重新算出来的')

  const envelope = await idempotency.run('k1', job.execute)
  assert.deepEqual(envelope, { ok: true, result: '重新算出来的' })
  assert.equal(job.calls(), 1)
  // 坏行被清掉并被新结果覆盖，下一次重发不会又撞上它。
  assert.equal(rows.size, 1)
  assert.equal(JSON.parse(String(rows.get('k1')?.resultRef)).result, '重新算出来的')
})

test('坏行里的未知错误码：读回来时归一成 internal（§3.1 的表是封闭的）', async () => {
  // `at` 取当下：这一条测的是**码的归一**，不是 TTL（过期的行会走"按未命中处理"那条路）。
  const rows = createMemoryDedupeRows({
    k1: { at: 1000, status: 'done', resultRef: JSON.stringify({ ok: false, code: 'made/up' }) },
  })
  const idempotency = createIdempotency({ rows, now: () => 1001 })
  const job = counter()

  const envelope = await idempotency.run('k1', job.execute)
  assert.deepEqual(envelope, { ok: false, code: 'internal' })
  assert.equal(job.calls(), 0, '命中缓存就不该执行')
})

test('落盘失败：应答照回（操作已经生效），只是不记住', async () => {
  const warnings: string[] = []
  const rows = createMemoryDedupeRows()
  const idempotency = createIdempotency({
    rows: {
      ...rows,
      put: () => Promise.reject(new Error('磁盘满了')),
    },
    log: {
      info: () => {},
      debug: () => {},
      error: () => {},
      warn: (message) => warnings.push(message),
    },
  })
  const job = counter()

  const envelope = await idempotency.run('k1', job.execute)
  assert.deepEqual(envelope, { ok: true, result: { accepted: true } }, '生效了就必须回成功')
  assert.equal(warnings.length, 1, '记不住要留声 —— 它是可观测的降级，不是隐藏的失败')
})

test('惰性过期：过期条目按未命中处理（清扫是有界的，正确性不能靠它）', async () => {
  const rows = createMemoryDedupeRows({
    k1: { at: 0, status: 'done', resultRef: JSON.stringify({ ok: true, result: '旧的' }) },
  })
  // 时钟已经走过 TTL：即便清扫一次都没跑过，这一行也不能再被当成命中。
  const idempotency = createIdempotency({ rows, now: () => DEDUPE_TTL_MS + 1 })
  const job = counter('新的')

  const envelope = await idempotency.run('k1', job.execute)
  assert.deepEqual(envelope, { ok: true, result: '新的' }, '过期的应答不许再回给手机')
  assert.equal(job.calls(), 1)
  assert.equal(JSON.parse(String(rows.get('k1')?.resultRef)).result, '新的', '过期行被新结果替换')
})

test('收敛有上限：一次最多清 SWEEP_LIMIT 条，余量留给下一次', async () => {
  const rows = createMemoryDedupeRows()
  for (let i = 0; i < DEDUPE_SWEEP_LIMIT + 3; i += 1) {
    rows.map.set(`k${i}`, { at: 0, status: 'done', resultRef: '{}' })
  }
  const idempotency = createIdempotency({ rows, now: () => DEDUPE_TTL_MS + 1 })

  assert.equal(await idempotency.prune(), DEDUPE_SWEEP_LIMIT, '单次有界 —— 否则挂载会变成上万次串行落盘')
  assert.equal(rows.size, 3)
  // 再来一次就把剩下的清干净。
  assert.equal(await idempotency.prune(), 3)
  assert.equal(rows.size, 0)
})

test('收敛：TTL 过期清掉，容量超限清最旧的', async () => {
  const ttlRows = createMemoryDedupeRows({
    old: { at: 0, status: 'done', resultRef: '{}' },
    fresh: { at: DEDUPE_TTL_MS, status: 'done', resultRef: '{}' },
  })
  const atTtl = createIdempotency({ rows: ttlRows, now: () => DEDUPE_TTL_MS + 1 })
  assert.equal(await atTtl.prune(), 1, '只清过期的那条')
  assert.deepEqual([...ttlRows.map.keys()], ['fresh'])

  const capRows = createMemoryDedupeRows()
  for (let i = 0; i < 5; i += 1) capRows.map.set(`k${i}`, { at: i, status: 'done', resultRef: '{}' })
  const capped = createIdempotency({ rows: capRows, now: () => 100, capacity: 3 })
  assert.equal(await capped.prune(), 2, '超出容量要清到容量以内')
  assert.deepEqual([...capRows.map.keys()], ['k2', 'k3', 'k4'], '清的是最旧的')
  assert.equal(DEDUPE_CAPACITY, 10_000)
})

test('容量上限：写入后超过容量会自动收敛一次', async () => {
  const rows = createMemoryDedupeRows()
  const idempotency = createIdempotency({ rows, capacity: 2, now: () => 100 })

  for (const key of ['k1', 'k2', 'k3']) await idempotency.run(key, counter().execute)
  assert.equal(rows.size <= 2, true, `容量是 2，实际 ${rows.size}`)
})
