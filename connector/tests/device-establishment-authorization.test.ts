/**
 * 真建连回调的授权回归：直接从 index.ts 的 AST 取生产函数，再注入边界。
 * 不重抄回调、不增加生产 test-only 导出；只在内存重放，不建立真实连接。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import ts from 'typescript'

import { replacedRowsOf } from '../src/pairing-endpoint.js'
import { silentLogger } from '../src/observability.js'
import type { DeviceRecord } from '../src/store/index.js'

const sourcePath = new URL('../src/index.ts', import.meta.url)
const source = ts.createSourceFile('index.ts', readFileSync(sourcePath, 'utf8'), ts.ScriptTarget.ES2022, true)
const variables = new Map<string, ts.Expression>()
const connectionCalls: ts.CallExpression[] = []
function visit(node: ts.Node): void {
  if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer !== undefined) {
    variables.set(node.name.text, node.initializer)
  }
  if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === 'createDeviceConnection') {
    connectionCalls.push(node)
  }
  ts.forEachChild(node, visit)
}
visit(source)
assert.equal(connectionCalls.length, 1, '真实 makeConnection 应只有一个 createDeviceConnection 入口')

function property(object: ts.Expression | undefined, name: string): ts.Expression {
  assert.ok(object !== undefined && ts.isObjectLiteralExpression(object), `${name} 必须来自生产对象字面量`)
  const found = object.properties.find((item) => ts.isPropertyAssignment(item)
    && (ts.isIdentifier(item.name) || ts.isStringLiteral(item.name)) && item.name.text === name)
  assert.ok(found !== undefined && ts.isPropertyAssignment(found), `生产入口缺少 ${name}`)
  return found.initializer
}

const options = connectionCalls[0]!.arguments[0]
const established = property(property(options, 'scope'), 'onDeviceEstablished')
const notified = property(variables.get('scopeDeps'), 'onDeviceEstablished')
const pruneExpression = variables.get('pruneReplaced')
assert.ok(pruneExpression !== undefined, '必须重放真正的 pruneReplaced，而不是测试自己删旧行')
const prune: ts.Expression = pruneExpression

function bind<T>(expression: ts.Expression, dependencies: Record<string, unknown>): T {
  const emitted = ts.transpileModule(`exports.value = (${expression.getText(source)});`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText
  const result: { value?: unknown } = {}
  new Function(...Object.keys(dependencies), 'exports', emitted)(...Object.values(dependencies), result)
  assert.equal(typeof result.value, 'function', 'AST 必须给出可执行的生产回调')
  return result.value as T
}

const oldId = 'synthetic-old'
const newId = 'synthetic-new'
function row(overrides: Partial<DeviceRecord> = {}): DeviceRecord {
  return {
    edPub: 'a'.repeat(64), dhPub: 'b'.repeat(64), name: 'synthetic', pairedAt: 1,
    pairingId: 'synthetic-pair', ...overrides,
  }
}

function harness(current: DeviceRecord | undefined) {
  const old = row()
  const records = new Map<string, DeviceRecord>([[oldId, old]])
  if (current !== undefined) records.set(newId, current)
  const events: string[] = []
  const batches: string[][] = []
  let newStopped = false
  let oldStopped = false
  let scopeCalls = 0
  const self = { stop: () => { newStopped = true; events.push('stop-new') } }
  const serving = new Map([[oldId, { stop: () => { oldStopped = true; events.push('stop-old') } }]])
  const servingConnections = {
    get: (id: string) => serving.get(id),
    set(id: string, connection: typeof self) {
      events.push('register-new')
      serving.set(id, connection)
      return serving
    },
  }
  const devicesTable = {
    get: (id: string) => records.get(id),
    keys: () => [...records.keys()],
    async deleteMany(ids: readonly string[]) {
      batches.push([...ids])
      // 模拟宿主单写链的提交槽：callback 入队后，介质提交才在后续微任务完成。
      await Promise.resolve()
      let removed = 0
      for (const id of ids) if (records.delete(id)) removed += 1
      events.push('delete-old')
      return removed
    },
  }
  const failures: unknown[] = []
  const logger = { ...silentLogger, warn: (_message: string, error?: unknown) => failures.push(error) }
  const pruneReplaced = bind<(id: string) => Promise<void>>(prune, {
    devicesTable, servingConnections, replacedRowsOf, logger,
    scheduleDevices: async () => { events.push('schedule-roster') },
  })
  const notify = bind<(id: string) => void>(notified, { pruneReplaced, logger })
  const scopeDeps = {
    onDeviceEstablished(id: string) {
      scopeCalls += 1
      events.push('notify-scope')
      notify(id)
    },
  }
  const callback = bind<(id: string) => void>(established, {
    self, servingConnections, scopeDeps, devicesTable,
  })
  return {
    callback, serving, self, records, old, events, failures,
    snapshot: () => ({
      newStopped, registered: serving.has(newId), scopeCalls, batches,
      oldStillPresent: records.has(oldId), oldStopped,
    }),
  }
}

const afterTurn = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))

for (const [name, current] of [
  ['新行缺失', undefined],
  ['新行在 hello 后已吊销', row({ replaces: oldId, revokedAt: 2 })],
] as const) {
  test(`业务鉴权收尾：${name}只停止新连接，不登记/通知/裁旧`, { timeout: 60_000 }, async () => {
    const state = harness(current)
    state.callback(newId)
    assert.ok(state.events.includes('stop-new'), '无效身份必须当场 stop，不能延后到裁旧完成')
    await afterTurn()
    assert.deepEqual(state.snapshot(), {
      newStopped: true, registered: false, scopeCalls: 0, batches: [],
      oldStillPresent: true, oldStopped: false,
    }, '尚未确认有效的新身份不能抹掉旧授权或登记为 serving')
    assert.equal(state.records.get(oldId), state.old, '保留原来的旧行，而非重建一份替身成功记录')
    assert.deepEqual(state.failures, [])
  })
}

test('业务鉴权收尾：有效新行仍先登记/通知，提交成功后停旧连接并调度名册', { timeout: 60_000 }, async () => {
  const state = harness(row({ replaces: oldId }))
  state.callback(newId)
  await afterTurn()
  assert.deepEqual(state.snapshot(), {
    newStopped: false, registered: true, scopeCalls: 1, batches: [[oldId]],
    oldStillPresent: false, oldStopped: true,
  })
  assert.equal(state.serving.get(newId), state.self)
  assert.ok(state.events.indexOf('register-new') < state.events.indexOf('notify-scope'))
  assert.ok(state.events.indexOf('delete-old') < state.events.indexOf('stop-old'))
  assert.ok(state.events.indexOf('stop-old') < state.events.indexOf('schedule-roster'))
  assert.deepEqual(state.failures, [])
})
