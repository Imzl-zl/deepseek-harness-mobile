/**
 * 方法面分发的回归（契约 §5.7）。
 *
 * 三条规则都是「写错了不会立刻报错、但会破坏不变量」的那一类，所以逐条钉：
 * 未知方法要回结构化错误而不是抛（否则手机端一个拼错的方法名会断掉连接），
 * 幂等键必须在分发前强制（漏键 = 重复执行用户指令），以及**分发器从不抛**。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

import { ProtocolError } from '../src/protocol/errors.js'
import {
  IDEMPOTENT_METHODS,
  METHODS,
  createDispatcher,
  decodeRequest,
  isMethod,
  requiresIdempotencyKey,
} from '../src/protocol/methods.js'

test('方法表：封闭集，幂等键标记与契约 §5.7 的表一致', () => {
  // 2026-10-15 加 `session.projections` 后是 23，同日加 `permission.catalog` 与
  // `permission.switch`（权限切换：读预设目录 + 写 `/permission <档位>`）后是 25，
  // 加 `session.select-model` 与 `session.modelCatalog` 后是 26。
  // 2026-10-15 晚加 `workspace.list`（会话列表按工作区分组）后是 **27**；
  // 2026-10-16 加 `workspace.archive` / `workspace.unarchive`（归档面）后是 **29**；
  // 2026-10-17 加 `session.updateQueue`（排队项编辑 / 删除 / 插话）后是 **30**；
  // 同日加 `agentPresets.list`（Agent 预设目录，只读）后是 **31**。
  // 2026-10-19 加 `usage.summary`（跨会话用量汇总，只读）后是 **32**。
  // 2026-10-21 加 `workspace.insertSessionBefore` / `workspace.pin` /
  // `workspace.unpin`（侧栏会话重排与置顶）后是 **35**。
  // 同日加 `subagent.prompt`（给可继续子会话投递人写的消息 —— 子会话不能用
  // `session.prompt`，宿主会拒成 `is owned by subagent routing`）后是 **36**。
  // 2026-10-21 晚加 `workspace.insertBefore`（侧栏项目头拖动排序，DSH 的
  // `workspace-controller/src/index.ts:135-145`）后是 **37**。
  // 2026-10-23 加 `command.execute`（斜杠命令执行面，白名单只放 /goal 与 /plan）后是 **38**。
  // 2026-10-24 加 `refs.files` / `refs.sessions`（`@` 候选，只读）后是 **40**。
  // **这个数是契约 §5.7 的表与 `tools.md` 的同步闸**：加了方法不改这里就会红，
  // 而它红的方式是"数不对"，所以改它必须同时改契约那一行。
  assert.equal(METHODS.length, 40, '方法数变了要同步契约 §5.7 的表')
  assert.equal(new Set(METHODS).size, METHODS.length, '方法名不能重复')

  // 幂等集**从契约 §5.7 的表里读**，不在测试里手抄第二份 ——
  // 手抄的那份一旦与表漂了，这个用例名里的"与契约一致"就是假的
  // （2026-10-21 审查指出：以前正是硬拷常量）。
  // 判据是「幂等键」列非空：`—` = 不带键，`requestId` / `i:<callId>` 都是键。
  const contract = readFileSync(
    new URL('../../docs/subsystems/remote-channel.md', import.meta.url),
    'utf8',
  )
  const from = contract.indexOf('### 5.7')
  const to = contract.indexOf('### 5.8')
  assert.ok(from > 0 && to > from, '契约里找不到 §5.7 的表')
  const declared: string[] = []
  for (const line of contract.slice(from, to).split('\n')) {
    if (!line.startsWith('| `')) continue
    const cells = line.split('|')
    if (cells.length < 5) continue
    const methodCell = cells[1] ?? ''
    const keyCell = (cells[3] ?? '').trim()
    if (keyCell === '—') continue
    for (const match of methodCell.matchAll(/`([A-Za-z]+\.[A-Za-z-]+)`/g)) {
      declared.push(match[1]!)
    }
  }
  assert.deepEqual(
    [...IDEMPOTENT_METHODS].sort(),
    declared.sort(),
    '幂等集必须与契约 §5.7 的「幂等键」列逐项一致（表改了这里跟着红）',
  )
  assert.equal(requiresIdempotencyKey('session.list'), false)
  assert.equal(requiresIdempotencyKey('session.prompt'), true)
  assert.equal(requiresIdempotencyKey('session.create'), true)
  assert.equal(requiresIdempotencyKey('session.select-model'), true)
  assert.equal(requiresIdempotencyKey('permission.switch'), true)
  assert.equal(requiresIdempotencyKey('command.execute'), true)
  assert.equal(requiresIdempotencyKey('workspace.archive'), true)
  assert.equal(requiresIdempotencyKey('workspace.unarchive'), true)
  assert.equal(requiresIdempotencyKey('workspace.insertSessionBefore'), true)
  assert.equal(requiresIdempotencyKey('workspace.insertBefore'), true)
  assert.equal(requiresIdempotencyKey('workspace.pin'), true)
  assert.equal(requiresIdempotencyKey('workspace.unpin'), true)
  assert.equal(requiresIdempotencyKey('permission.catalog'), false, '读方法不带幂等键')

  assert.equal(isMethod('session.list'), true)
  assert.equal(isMethod('session.typo'), false)
  assert.equal(isMethod(undefined), false)
})

test('请求信封：只解析形状，不判方法是否认识', () => {
  assert.deepEqual(decodeRequest('{"method":"session.list"}'), { method: 'session.list' })
  assert.deepEqual(decodeRequest('{"method":"session.prompt","requestId":"r1","params":{"x":1}}'), {
    method: 'session.prompt',
    requestId: 'r1',
    params: { x: 1 },
  })
  // 未知方法**不在这里**拦 —— 交给分发器回 connector/unsupported，连接留着。
  assert.deepEqual(decodeRequest('{"method":"future.method"}'), { method: 'future.method' })

  for (const bad of ['not json', '[]', '"x"', '{}', '{"method":""}', '{"method":"a","requestId":""}']) {
    assert.throws(
      () => decodeRequest(bad),
      (e: unknown) => e instanceof ProtocolError,
      `${bad} 应被拒`,
    )
  }
})

test('分发：未知方法回 connector/unsupported，不是抛也不是断连', async () => {
  const dispatcher = createDispatcher({})
  const response = await dispatcher.dispatch({ method: 'session.typo' })
  assert.equal(response.ok, false)
  assert.equal(response.ok === false && response.code, 'connector/unsupported')
})

test('分发：表里认识但没实现的方法回 unsupported，与未知方法区分开', async () => {
  const dispatcher = createDispatcher({})
  const known = await dispatcher.dispatch({ method: 'session.list' })
  // 两者都是 unsupported（手机端都该置灰），但消息不同，便于电脑侧排查。
  assert.equal(known.ok === false && known.code, 'connector/unsupported')
  assert.match(known.ok === false ? (known.message ?? '') : '', /尚未实现/)
})

test('分发：标了幂等键的方法漏键时在分发前被拦', async () => {
  let called = false
  const dispatcher = createDispatcher({
    'session.prompt': () => {
      called = true
      return { accepted: true }
    },
  })

  const missing = await dispatcher.dispatch({ method: 'session.prompt', params: { text: 'hi' } })
  assert.equal(missing.ok, false)
  assert.equal(missing.ok === false && missing.code, 'protocol/bad-frame')
  // 关键:handler **根本不该被调用** —— 漏键的重发会变成第二条消息（I8）。
  assert.equal(called, false, '漏键时 handler 不得执行')

  const ok = await dispatcher.dispatch({
    method: 'session.prompt',
    requestId: 'r1',
    params: { text: 'hi' },
  })
  assert.deepEqual(ok, { ok: true, result: { accepted: true } })
  assert.equal(called, true)
})

test('分发：从不抛 —— handler 抛错也变成 ok:false 的信封', async () => {
  const dispatcher = createDispatcher({
    'session.list': () => {
      throw new ProtocolError('session/not-found', '会话不存在')
    },
    'repo.info': () => {
      throw new Error('内部炸了')
    },
  })

  const protocolFailure = await dispatcher.dispatch({ method: 'session.list' })
  // 协议错误保留自己的码 —— 手机端要靠它决定"从列表移除"还是"重试"。
  assert.equal(protocolFailure.ok === false && protocolFailure.code, 'session/not-found')

  const internal = await dispatcher.dispatch({ method: 'repo.info' })
  assert.equal(internal.ok === false && internal.code, 'internal')
  assert.match(internal.ok === false ? (internal.message ?? '') : '', /内部炸了/)

  // 异步抛错同样被收住。
  const async = createDispatcher({
    'job.list': async () => {
      throw new ProtocolError('job/not-found')
    },
  })
  assert.equal((await async.dispatch({ method: 'job.list' })).ok, false)
})

test('分发：implemented 只列真正有 handler 的方法', () => {
  const dispatcher = createDispatcher({
    'session.list': () => [],
    'repo.info': () => ({}),
  })
  assert.deepEqual([...dispatcher.implemented].sort(), ['repo.info', 'session.list'])
})

test('分发：把 requestId 与会话别名传给 handler', async () => {
  let seen: unknown = null
  const dispatcher = createDispatcher({
    'credentials.set': (_params, context) => {
      seen = context
      return { accepted: true }
    },
  })
  await dispatcher.dispatch({ method: 'credentials.set', requestId: 'k1' }, { sid: 'sid-1' })
  assert.deepEqual(seen, { requestId: 'k1', sid: 'sid-1' })
})
