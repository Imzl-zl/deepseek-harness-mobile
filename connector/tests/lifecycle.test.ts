/**
 * 生命周期顺序的回归（契约 §1.3）。
 *
 * 用假的步骤跑，所以能精确构造真机上很难出现的场景：**mount 中途失败**、
 * **dispose 时某一步抛错**。这两条恰恰是最容易写错、且写错后症状离起因最远的地方。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { LifecycleErrors, mount, type LifecycleStep } from '../src/lifecycle.js'

/** 记录调用序列的假步骤。 */
function tracker(): { log: string[]; step: (name: string, options?: { failRun?: boolean; failUndo?: boolean }) => LifecycleStep } {
  const log: string[] = []
  return {
    log,
    step(name, options = {}) {
      return {
        name,
        run() {
          if (options.failRun === true) throw new Error(`${name} run 失败`)
          log.push(`run:${name}`)
        },
        undo() {
          if (options.failUndo === true) throw new Error(`${name} undo 失败`)
          log.push(`undo:${name}`)
        },
      }
    },
  }
}

test('mount 按给定顺序执行，dispose 逆序回滚', async () => {
  const t = tracker()
  const lifecycle = await mount([
    t.step('validate-config'),
    t.step('open-store'),
    t.step('publish-service'),
    t.step('register-answerers'),
    t.step('start-transport'),
  ])

  // 顺序就是契约 §1.3 的顺序 —— store 必须在 answerer 之前，transport 在最后。
  assert.deepEqual(t.log, [
    'run:validate-config',
    'run:open-store',
    'run:publish-service',
    'run:register-answerers',
    'run:start-transport',
  ])
  assert.deepEqual(lifecycle.completed, [
    'validate-config',
    'open-store',
    'publish-service',
    'register-answerers',
    'start-transport',
  ])
  assert.equal(lifecycle.disposed, false)

  await lifecycle.dispose()
  assert.equal(lifecycle.disposed, true)
  // 后建的先拆。
  assert.deepEqual(t.log.slice(5), [
    'undo:start-transport',
    'undo:register-answerers',
    'undo:publish-service',
    'undo:open-store',
    'undo:validate-config',
  ])
})

test('mount 中途失败：回滚已完成的步骤，且报出失败的那一步', async () => {
  const t = tracker()
  await assert.rejects(
    mount([
      t.step('open-store'),
      t.step('register-answerers'),
      t.step('start-transport', { failRun: true }),
    ]),
    (error: unknown) => {
      assert.ok(error instanceof LifecycleErrors)
      assert.equal(error.causes[0]?.step, 'start-transport')
      return true
    },
  )

  // 只回滚**已完成**的两步，且逆序 —— 失败那一步自己没有 undo 可跑。
  assert.deepEqual(t.log, [
    'run:open-store',
    'run:register-answerers',
    'undo:register-answerers',
    'undo:open-store',
  ])
})

test('dispose 尽力而为：某一步抛错不拦住后面的步骤', async () => {
  const t = tracker()
  const lifecycle = await mount([
    t.step('open-store'),
    t.step('start-transport', { failUndo: true }),
  ])

  await assert.rejects(lifecycle.dispose(), (error: unknown) => {
    assert.ok(error instanceof LifecycleErrors)
    assert.deepEqual(error.causes.map((c) => c.step), ['start-transport'])
    return true
  })

  // 关键：transport.stop() 失败之后，store 仍然被关掉了。
  // 否则下一次挂载会看到半开的存储，而错误信息完全指向不了真正的起因。
  assert.ok(t.log.includes('undo:open-store'), 'close-store 必须照跑')
})

test('dispose 可重复调用，第二次是 no-op', async () => {
  const t = tracker()
  const lifecycle = await mount([t.step('open-store')])
  await lifecycle.dispose()
  const afterFirst = [...t.log]
  await lifecycle.dispose()
  assert.deepEqual(t.log, afterFirst)
})
