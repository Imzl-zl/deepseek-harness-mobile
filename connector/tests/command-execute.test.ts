/**
 * 斜杠命令执行面（`command.execute`，契约 §5.7）。
 *
 * 这一层钉八件事，每一条都是「写错了不会立刻报错，但会破坏不变量」的那类：
 *
 * 1. **方法名与幂等键**在封闭集里（写操作，重发不该落两张命令卡）；
 * 2. **请求形状**：`{sid, line}` —— `agentId` 由连接器从 `sid` 解析，
 *    手机不传 agent id（Typert 的线上键是 `agentId`，`tools.md` 铁律①）；
 * 3. **附件恒为空数组**（与 Web 的 `/permission` 调用同一个形状，`session.ts:388`）；
 * 4. **`undefined` 是 `matched:false`**（DSH 的 `execute` 在语法/名字没解析出来时回
 *    `undefined`，`interaction/commands/src/index.ts:367-370`；Web 的推导在
 *    `session-controller/src/client/sessions/session.ts:390`）；
 * 5. **`{kind:'error'}` 原样过线** —— 命令在、但参数不对，是电脑侧的措辞；
 * 6. **白名单**：不在名单里的名字回 `connector/unsupported` 且**不去问 DSH**；
 *    不是命令形状的行**照原样交给宿主**（别自己发明语法）；
 * 7. **坏参数 → `protocol/bad-frame`**，未知 sid → `session/not-found`（都不去问 DSH）；
 * 8. **没有活动 agent → `internal`**（不是 `session/not-found`：那会让手机把会话删掉）；
 * 9. **白名单原样过线**（`repo.info.commands`）：手机侧画候选菜单只画这里给的名字，
 *    而 `command.execute` 没挂时**连 `commands` 这个键都不报**。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import {
  commandNameOf,
  createCommandLineRunner,
  type CommandLineRunner,
} from '../src/dsh/command-line.js'
import { IDEMPOTENT_METHODS, METHODS, isMethod } from '../src/protocol/methods.js'

/** 最小可用的假 DSH 上下文：只按形状回答本插件问到的那几个键。 */
function fakeCtx(services: Record<string, unknown>) {
  return { get: (key: string) => services[key] } as never
}

const SID = 'sid_1'
const ALIASES = {
  ensure: async () => SID,
  sessionOf: (sid: string) => (sid === SID ? 'dsh-1' : undefined),
} as never
const NO_SESSIONS = { list: async () => [] } as never

function depsWith(commandLine: CommandLineRunner): HandlerDeps {
  return {
    sessions: NO_SESSIONS,
    aliases: ALIASES,
    commandLine,
  } as unknown as HandlerDeps
}

/** 只记账、不真的跑：用来验"白名单/形状校验有没有走到 DSH"。 */
function spyRunner(
  view: unknown = { matched: true, execution: {} },
  descriptions: Record<string, string> = {},
) {
  const seen: { sid: string; line: string }[] = []
  const asked: string[][] = []
  const runner: CommandLineRunner = {
    run: async (sid, line) => {
      seen.push({ sid, line })
      return view as { matched: boolean }
    },
    describe: (names) => {
      asked.push([...names])
      const declared: Record<string, string> = {}
      for (const name of names) {
        const description = descriptions[name]
        if (description !== undefined) declared[name] = description
      }
      return declared
    },
  }
  return { runner, seen, asked }
}

test('方法表：command.execute 在封闭集里，且带幂等键', () => {
  assert.equal(isMethod('command.execute'), true, 'command.execute 必须在封闭集里')
  assert.ok(METHODS.includes('command.execute'))
  assert.equal(
    IDEMPOTENT_METHODS.has('command.execute'),
    true,
    '跑命令是写操作：重发不该落两张 command/run 卡',
  )
})

test('命令名语法与 DSH 逐字一致（interaction/commands/src/index.ts:126）', () => {
  assert.equal(commandNameOf('/goal 睡觉'), 'goal')
  assert.equal(commandNameOf('/plan off'), 'plan')
  assert.equal(commandNameOf('/goal'), 'goal', '没有参数也是命令')
  assert.equal(commandNameOf('/select-model x'), 'select-model', '名字里允许连字符')
  assert.equal(commandNameOf('/a1_b'), 'a1_b')
  // 不是命令形状的一律 `undefined` —— 由宿主回 `undefined`，我们别自己发明语法。
  assert.equal(commandNameOf('/Goal x'), undefined, '大写不是合法命令名')
  assert.equal(commandNameOf('/goal:x'), undefined, '名字后面必须跟空白或行尾')
  assert.equal(commandNameOf('/etc/passwd 是啥'), undefined, '斜杠开头的路径不是命令')
  assert.equal(commandNameOf('goal 睡觉'), undefined)
  assert.equal(commandNameOf(''), undefined)
})

test('请求形状：agent 由 sid 解析，附件为空数组，带取消信号', async () => {
  const calls: {
    agent: unknown
    line: string
    attachments: readonly unknown[]
    signal: unknown
  }[] = []
  const runner = createCommandLineRunner(
    fakeCtx({
      commands: {
        execute: async (
          agent: unknown,
          line: string,
          attachments: readonly unknown[],
          signal: AbortSignal,
        ) => {
          calls.push({ agent, line, attachments, signal })
          return { commandId: 'cmd-1-1', result: { kind: 'success', text: 'Goal created' } }
        },
      },
      agents: { get: (id: string) => ({ id, session: { id } }) },
    }),
    { sessionOf: (sid) => (sid === SID ? 'dsh-1' : undefined) },
  )

  const view = await runner.run(SID, '/goal 睡觉')

  assert.equal(calls.length, 1)
  assert.equal(calls[0]?.line, '/goal 睡觉', '命令行原样过线（不 trim、不改写）')
  assert.deepEqual(calls[0]?.attachments, [], '命令不随附件发送（契约 §5.7）')
  // 手机只给 `sid`；换 agent 的那一步在连接器里（契约 §5.1）。
  assert.equal((calls[0]?.agent as { id: string }).id, 'dsh-1')
  assert.ok(calls[0]?.signal instanceof AbortSignal, '要带取消信号（不进 args）')
  assert.deepEqual(view, {
    matched: true,
    execution: { commandId: 'cmd-1-1', result: { kind: 'success', text: 'Goal created' } },
  })
})

test('DSH 回 undefined = 没解析出命令 ⇒ matched:false', async () => {
  const runner = createCommandLineRunner(
    fakeCtx({
      commands: { execute: async () => undefined },
      agents: { get: () => ({}) },
    }),
    { sessionOf: () => 'dsh-1' },
  )
  assert.deepEqual(await runner.run(SID, '/nope'), { matched: false })
})

test('handler 回 error 时原样过线（不翻译、不改码）', async () => {
  const runner = createCommandLineRunner(
    fakeCtx({
      commands: {
        execute: async () => ({
          commandId: 'cmd-2-1',
          result: { kind: 'error', text: 'A goal is already active. Use /goal edit <objective>.' },
        }),
      },
      agents: { get: () => ({}) },
    }),
    { sessionOf: () => 'dsh-1' },
  )
  assert.deepEqual(await runner.run(SID, '/goal 新目标'), {
    matched: true,
    execution: {
      commandId: 'cmd-2-1',
      result: { kind: 'error', text: 'A goal is already active. Use /goal edit <objective>.' },
    },
  })
})

test('会话没有活动 agent：internal，不是 session/not-found', async () => {
  const runner = createCommandLineRunner(
    fakeCtx({
      commands: { execute: async () => ({}) },
      agents: { get: () => undefined },
    }),
    { sessionOf: () => 'dsh-1' },
  )
  await assert.rejects(
    () => runner.run(SID, '/goal x'),
    (error: unknown) => {
      assert.match((error as Error).message, /活动 agent/)
      // `session/not-found` 的客户端动作是"从列表移除"（契约 §3.1）——
      // 这个会话是存在的，用那个码会让手机把一个好会话删掉。
      assert.equal((error as { code?: string }).code, 'internal')
      return true
    },
  )
})

test('白名单：/goal 与 /plan 放行，命令行原样交给执行层', async () => {
  for (const line of ['/goal 睡觉', '/plan off']) {
    const { runner, seen } = spyRunner()
    const handlers = createHandlers(depsWith(runner))
    await handlers['command.execute']!({ sid: SID, line }, undefined as never)
    assert.deepEqual(seen, [{ sid: SID, line }], `${line} 该原样交给 DSH`)
  }
})

test('白名单：不在名单里的命令回 connector/unsupported，且**不去问 DSH**', async () => {
  // `/compact` 是本轮**有意**不放的那一个（没有反向命令 + 一次模型总结），
  // 所以它是这条判据的样本。
  for (const line of ['/compact', '/export', '/feedback 很好', '/permission read-only']) {
    const { runner, seen } = spyRunner()
    const handlers = createHandlers(depsWith(runner))
    let caught: { code?: string; message?: string } | undefined
    try {
      await handlers['command.execute']!({ sid: SID, line }, undefined as never)
    } catch (error) {
      caught = error as { code?: string; message?: string }
    }
    assert.equal(caught?.code, 'connector/unsupported', `${line} 应被白名单拒掉`)
    // 错误里要报出名单本身：手机原样显示这句话，不在本地抄第二份名单。
    assert.match(caught?.message ?? '', /\/goal/)
    assert.match(caught?.message ?? '', /\/plan/)
    assert.equal(seen.length, 0, '被白名单拒掉的行不该走到 DSH')
  }
})

test('不是命令形状的行：照原样交给宿主（由它回 undefined）', async () => {
  // `/etc/passwd 是啥` 是**一条普通消息**：DSH 的 parseCommand 解析不出名字，
  // 于是 `execute` 回 `undefined`，手机按 Web 的同一条推导退成 `session.prompt`。
  const { runner, seen } = spyRunner({ matched: false })
  const handlers = createHandlers(depsWith(runner))
  const result = await handlers['command.execute']!(
    { sid: SID, line: '/etc/passwd 是啥' },
    undefined as never,
  )
  assert.deepEqual(seen, [{ sid: SID, line: '/etc/passwd 是啥' }])
  assert.deepEqual(result, { matched: false })
})

test('坏参数：line 缺失 / 空 / 非字符串 / 带换行 → protocol/bad-frame', async () => {
  const { runner, seen } = spyRunner()
  const handlers = createHandlers(depsWith(runner))
  for (const params of [
    { sid: SID },
    { sid: SID, line: '' },
    { sid: SID, line: 7 },
    { sid: SID, line: '/goal 睡觉\n/goal 另一个' },
    { sid: SID, line: '/goal\r\nx' },
  ]) {
    let caught: { code?: string } | undefined
    try {
      await handlers['command.execute']!(params, undefined as never)
    } catch (error) {
      caught = error as { code?: string }
    }
    assert.equal(caught?.code, 'protocol/bad-frame', `${JSON.stringify(params)} 应被拒`)
  }
  // sid 形状不对同样是 bad-frame（契约 §5.7 两条跨方法规则）。
  for (const params of [{ line: '/goal x' }, { sid: '', line: '/goal x' }, { sid: 7, line: '/goal x' }]) {
    let caught: { code?: string } | undefined
    try {
      await handlers['command.execute']!(params, undefined as never)
    } catch (error) {
      caught = error as { code?: string }
    }
    assert.equal(caught?.code, 'protocol/bad-frame', `${JSON.stringify(params)} 应被拒`)
  }
  assert.equal(seen.length, 0, '坏参数不该走到 DSH')
})

test('未知 sid：session/not-found，不去问 DSH', async () => {
  const { runner, seen } = spyRunner()
  const handlers = createHandlers(depsWith(runner))
  let caught: { code?: string } | undefined
  try {
    await handlers['command.execute']!(
      { sid: 'sid_unknown', line: '/goal x' },
      undefined as never,
    )
  } catch (error) {
    caught = error as { code?: string }
  }
  assert.equal(caught?.code, 'session/not-found')
  assert.equal(seen.length, 0, '别名都不认识，不该去问 DSH')
})

test('commandLine 缺席时方法不挂（repo.info 自然也不报）', () => {
  const handlers = createHandlers({
    caps: () => ({
      sessions: true, storage: true, approval: false, questions: false,
      jobs: false, subagents: false, settings: false, credentials: true, direct: false,
    }),
    aliasVersion: () => 0,
    sessions: NO_SESSIONS,
    aliases: ALIASES,
    devices: () => [],
  } as unknown as HandlerDeps)
  assert.equal(handlers['command.execute'], undefined, '能力位为 false 时不该挂（契约 §7）')
  const info = handlers['repo.info']!({}, undefined as never) as { methods: string[] }
  assert.equal(info.methods.includes('command.execute'), false)
  // **不报一个调不通的名单**：没有 `command.execute` 就没有 `commands`
  // （契约 §5.7 表后："多一个必然失败的按钮"）。
  assert.equal('commands' in info, false)
})

test('命令说明从宿主定义读（`commands.list(agent)` 的 description），不手抄文案', () => {
  // 断言值故意是一句**不可能被手抄到**的字符串：手抄文案的实现在这里必红。
  const fromHost = 'HOST-DECLARED-description-of-goal'
  const runner = createCommandLineRunner(
    fakeCtx({
      commands: {
        execute: async () => undefined,
        list: () => [
          { name: 'goal', description: fromHost },
          { name: 'plan', description: '' },
          { name: 'export', description: '不在白名单里' },
        ],
      },
      agents: { get: () => undefined, list: () => [{ id: 'dsh-1' }] },
    }),
    { sessionOf: () => 'dsh-1' },
  )
  // 空说明视同没给；不在询问名单里的不报。
  assert.deepEqual(runner.describe(['goal', 'plan']), { goal: fromHost })
})

test('一个活 agent 都没有 ⇒ 说明为空（repo.info 只报名字）', () => {
  const runner = createCommandLineRunner(
    fakeCtx({
      commands: { execute: async () => undefined, list: () => [{ name: 'goal', description: 'x' }] },
      agents: { get: () => undefined, list: () => [] },
    }),
    { sessionOf: () => 'dsh-1' },
  )
  assert.deepEqual(runner.describe(['goal']), {}, '没有 agent 就没法读宿主定义：回空表，不编')
})

test('repo.info 报斜杠命令白名单（原样过线，手机据此画候选菜单）', () => {
  const { runner, asked } = spyRunner(undefined, {
    goal: 'Set or view the goal for a long-running task',
  })
  const handlers = createHandlers({
    ...depsWith(runner),
    caps: () => ({
      sessions: true, storage: true, approval: false, questions: false,
      jobs: false, subagents: false, settings: false, credentials: true, direct: false,
    }),
    aliasVersion: () => 0,
  } as unknown as HandlerDeps)
  const info = handlers['repo.info']!({}, undefined as never) as {
    commands?: { name: string; description?: string }[]
  }
  // 与 `MOBILE_COMMANDS` **同一份**：手机侧不抄第二份，加一个名字这里就多一项。
  // 形状是 `{name, description?}[]`：说明来自宿主的命令定义，读不到就不带这个键。
  assert.deepEqual(info.commands, [
    { name: 'goal', description: 'Set or view the goal for a long-running task' },
    { name: 'plan' },
  ])
  assert.deepEqual(asked, [['goal', 'plan']], '一次问完全部白名单名字，不逐个往返')
})
