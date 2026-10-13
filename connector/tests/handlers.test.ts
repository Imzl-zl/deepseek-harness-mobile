/**
 * handler 表的回归（契约 §5.7）。
 *
 * 两件事值得单独钉住：
 *
 * 1. **`repo.info` 报的 `methods` 必须是表的键**，而不是手抄的清单 ——
 *    手抄的会在下次加方法时忘掉同步，症状是"按钮能点但永远转圈"。
 * 2. **`devices.list` 不带公钥**：手机不需要别人的公钥，少发一个字段就少一处泄漏面。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers, type HandlerDeps } from '../src/handlers.js'
import { ProtocolError } from '../src/protocol/errors.js'
import { WIRE_VERSION } from '../src/protocol/frame.js'
import type { Caps } from '../src/dsh/caps.js'
import type { JobControlPort, JobsPort } from '../src/dsh/jobs.js'
import type { JobSubscriptions } from '../src/job-subscriptions.js'
import type { SessionPager } from '../src/session-page.js'
import type { SessionSubscriptions } from '../src/session-subscriptions.js'
import { createFakeAliases } from './support/fake-aliases.js'

/** 什么都不做的任务端口；只用它来"挂着 `job.*`"。 */
function fakeJobs(overrides: Partial<JobsPort> = {}): JobsPort {
  return {
    listOwnedBy: () => [],
    readOutput: () => ({ chunks: [], next: 0, lossy: false }),
    subscribe: () => () => {},
    ...overrides,
  }
}

/** 任务控制端口：默认受理，可注入失败。 */
function fakeJobControl(overrides: Partial<JobControlPort> = {}): JobControlPort {
  return {
    kill: () => 'requested',
    follow: () => (async function* () {})(),
    ...overrides,
  }
}

/** 已经分配过别名的替身（`sid_dsh-1` → `dsh-1`），供需要反解的方法用。 */
function preloadedAliases(): ReturnType<typeof createFakeAliases> {
  const aliases = createFakeAliases()
  aliases.bySid.set('sid_dsh-1', 'dsh-1')
  return aliases
}

/** 取 `repo.info` 报出来的方法清单。 */
function handlers_info(handlers: Partial<Record<string, unknown>>): { methods: string[] } {
  const info = handlers['repo.info'] as (() => { methods: string[] }) | undefined
  if (info === undefined) throw new Error('repo.info 不在表里')
  return info()
}

const CAPS: Caps = {
  sessions: true,
  storage: true,
  approval: false,
  questions: false,
  jobs: true,
  subagents: false,
  settings: true,
  credentials: true,
}

function build(overrides: Partial<Parameters<typeof createHandlers>[0]> = {}) {
  return createHandlers({
    caps: () => CAPS,
    aliasVersion: () => 7,
    devices: () => [],
    // 会话面的替身：`list` 给 DSH 权威行，`aliases` 两个方向都给（`job.list` 要反解）。
    sessions: { list: () => Promise.resolve([]), prompt: () => Promise.resolve({ accepted: true }) },
    aliases: createFakeAliases(),
    ...overrides,
  })
}

test('repo.info：协议版本、能力位、别名版本，以及**表的键**', async () => {
  const handlers = build()
  const handler = handlers['repo.info']
  assert.ok(handler !== undefined)

  const info = (await handler(undefined, {})) as {
    protocol: number
    caps: Caps
    aliasVersion: number
    methods: string[]
  }

  assert.equal(info.protocol, WIRE_VERSION)
  assert.deepEqual(info.caps, CAPS)
  assert.equal(info.aliasVersion, 7)
  // 报的必须是"表里真有的方法"：加一个 handler 就自动多一行，删一个就自动少一行。
  assert.deepEqual(info.methods, Object.keys(handlers).sort())
  assert.deepEqual(info.methods, ['devices.list', 'repo.info', 'session.list', 'session.prompt'])
})

test('job.kill：转达受理与否，并把 jobId 交给宿主门面', () => {
  const seen: unknown[][] = []
  const handlers = build({
    aliases: preloadedAliases(),
    jobControl: fakeJobControl({
      kill: (sessionId, jobId) => {
        seen.push([sessionId, jobId])
        return jobId === 'j-done' ? 'already-finished' : 'requested'
      },
    }),
  })
  const handler = handlers['job.kill']
  assert.ok(handler !== undefined)

  assert.deepEqual(handler({ sid: 'sid_dsh-1', jobId: 'j1' }, {}), { outcome: 'requested' })
  assert.deepEqual(handler({ sid: 'sid_dsh-1', jobId: 'j-done' }, {}), { outcome: 'already-finished' })
  assert.deepEqual(seen, [
    ['dsh-1', 'j1'],
    ['dsh-1', 'j-done'],
  ], '门面要的是 DSH 会话 id，不是别名')
})

test('job.kill：jobId 缺失或形状不对 → protocol/bad-frame；别名未知 → session/not-found', () => {
  const handlers = build({ aliases: preloadedAliases(), jobControl: fakeJobControl() })
  const handler = handlers['job.kill']
  assert.ok(handler !== undefined)

  for (const params of [undefined, {}, { sid: 'sid_dsh-1' }, { sid: 'sid_dsh-1', jobId: '' }, { sid: 'sid_dsh-1', jobId: 7 }]) {
    assert.throws(
      () => handler(params, {}),
      (error: unknown) => error instanceof ProtocolError && error.code === 'protocol/bad-frame',
      `${JSON.stringify(params)} 应当被拒`,
    )
  }

  assert.throws(
    () => handler({ sid: 'sid_nobody', jobId: 'j1' }, {}),
    (error: unknown) => error instanceof ProtocolError && error.code === 'session/not-found',
  )
})

test('job.kill：宿主的 job/not-found 原样转达（手机据此刷新任务列表）', () => {
  const handlers = build({
    aliases: preloadedAliases(),
    jobControl: fakeJobControl({
      kill: () => {
        throw new ProtocolError('job/not-found', '不属于这个会话')
      },
    }),
  })
  const handler = handlers['job.kill']
  assert.ok(handler !== undefined)

  assert.throws(
    () => handler({ sid: 'sid_dsh-1', jobId: 'j-foreign' }, {}),
    (error: unknown) => error instanceof ProtocolError && error.code === 'job/not-found',
  )
})

test('两种任务能力可以独立缺失：只列不停 / 都没有', () => {
  // 只装 base 的部署（没有 jobController）：能列任务，停不了。
  const listOnly = build({ jobs: fakeJobs() })
  assert.equal('job.list' in listOnly, true)
  assert.equal('job.kill' in listOnly, false)
  assert.deepEqual(handlers_info(listOnly).methods, [
    'devices.list',
    'job.list',
    'repo.info',
    'session.list',
    'session.prompt',
  ])

  const neither = build()
  assert.equal('job.list' in neither, false)
  assert.equal('job.kill' in neither, false)
})

/** 任务输出订阅注册表：默认什么都不做。 */
function fakeSubscriptions(overrides: Partial<JobSubscriptions> = {}): JobSubscriptions {
  return {
    follow: (input) => Promise.resolve({ from: input.from ?? 0 }),
    unfollow: () => true,
    stopAll: () => {},
    active: 0,
    ...overrides,
  }
}

/** 会话订阅注册表：默认什么都不做。 */
function fakeSessionSubscriptions(
  overrides: Partial<SessionSubscriptions> = {},
): SessionSubscriptions {
  return {
    subscribe: (input) =>
      Promise.resolve({ since: input.since ?? 0, hasMore: false }),
    unsubscribe: () => true,
    cursorOf: () => undefined,
    sids: () => [],
    stopAll: () => {},
    active: 0,
    ...overrides,
  }
}

test('session.subscribe：把 sid 与 DSH 会话 id 都交给注册表，并回水位与 hasMore', async () => {
  const seen: unknown[] = []
  const handlers = build({
    aliases: preloadedAliases(),
    sessionSubscriptions: fakeSessionSubscriptions({
      subscribe: (input) => {
        seen.push(input)
        return Promise.resolve({ since: 100, hasMore: true })
      },
    }),
  })
  const handler = handlers['session.subscribe']
  assert.ok(handler !== undefined)

  assert.deepEqual(await handler({ sid: 'sid_dsh-1' }, {}), { since: 100, hasMore: true })
  assert.deepEqual(seen, [{ sid: 'sid_dsh-1', dshSessionId: 'dsh-1' }])
  await handler({ sid: 'sid_dsh-1', since: 7 }, {})
  assert.deepEqual(seen[1], { sid: 'sid_dsh-1', dshSessionId: 'dsh-1', since: 7 })
})

test('session.subscribe / unsubscribe：参数与别名不合规就回结构化错误', async () => {
  const handlers = build({
    aliases: preloadedAliases(),
    sessionSubscriptions: fakeSessionSubscriptions(),
  })
  const subscribe = handlers['session.subscribe']
  const unsubscribe = handlers['session.unsubscribe']
  assert.ok(subscribe !== undefined && unsubscribe !== undefined)

  for (const since of [-1, 2.5, '9', null]) {
    await assert.rejects(
      async () => subscribe({ sid: 'sid_dsh-1', since }, {}),
      (error: unknown) => error instanceof ProtocolError && error.code === 'protocol/bad-frame',
      `since=${String(since)} 应当被拒`,
    )
  }
  await assert.rejects(
    async () => subscribe({ sid: 'sid_nobody' }, {}),
    (error: unknown) => error instanceof ProtocolError && error.code === 'session/not-found',
  )
  assert.throws(
    () => unsubscribe({ sid: 'sid_nobody' }, {}),
    (error: unknown) => error instanceof ProtocolError && error.code === 'session/not-found',
  )

  const without = build()
  assert.equal('session.subscribe' in without, false)
  assert.equal('session.unsubscribe' in without, false)
})

test('session.prompt：参数递下去，回 { accepted }', async () => {
  const seen: unknown[][] = []
  const handlers = build({
    aliases: preloadedAliases(),
    sessions: {
      list: () => Promise.resolve([]),
      prompt: (...args: unknown[]) => {
        seen.push(args)
        return Promise.resolve({ accepted: true })
      },
    } as never,
  })
  const handler = handlers['session.prompt']
  assert.ok(handler !== undefined)

  const content = [{ type: 'text', text: '你好' }]
  assert.deepEqual(await handler({ sid: 'sid_dsh-1', content }, { requestId: 'req_1' }), {
    accepted: true,
  })
  assert.deepEqual(seen[0], ['dsh-1', 'req_1', content, 'queue'], '默认排队')

  await handler({ sid: 'sid_dsh-1', content, mode: 'steer' }, { requestId: 'req_2' })
  assert.equal(seen[1]?.[3], 'steer', 'mode 原样传下去（它决定"插队"还是"排队"）')
})

test('session.prompt：requestId / content / mode 的形状不合规就回 protocol/bad-frame', async () => {
  const handlers = build({ aliases: preloadedAliases() })
  const handler = handlers['session.prompt']
  assert.ok(handler !== undefined)
  const base = { sid: 'sid_dsh-1', content: [{ type: 'text', text: 'x' }] }
  const withKey = { requestId: 'req_1' }

  for (const patch of [
    { content: undefined },
    { content: [] },
    { content: 'not-an-array' },
    { content: [{}] },
    { content: ['x'] },
    { mode: 'later' },
  ]) {
    await assert.rejects(
      async () => handler({ ...base, ...patch }, withKey),
      (error: unknown) => error instanceof ProtocolError && error.code === 'protocol/bad-frame',
      `${JSON.stringify(patch)} 应当被拒`,
    )
  }
  await assert.rejects(
    async () => handler({ ...base, sid: 'sid_nobody' }, withKey),
    (error: unknown) => error instanceof ProtocolError && error.code === 'session/not-found',
  )
})

/** 会话翻页端口：默认回空页。 */
function fakePager(overrides: Partial<SessionPager> = {}): SessionPager {
  return {
    page: (input) => Promise.resolve({ items: [], hasMore: false, throughSeq: input.beforeSeq ?? 0 }),
    refetch: ({ seq }) => Promise.resolve({ record: { event: { seq } } as never }),
    ...overrides,
  }
}

test('session.page：参数原样递下去（水位由翻页层从订阅面的缓存里取）', async () => {
  const seen: unknown[] = []
  const handlers = build({
    aliases: preloadedAliases(),
    sessionPager: fakePager({
      page: (input) => {
        seen.push(input)
        return Promise.resolve({ items: [], hasMore: true, throughSeq: 42 })
      },
    }),
  })
  const handler = handlers['session.page']
  assert.ok(handler !== undefined)

  assert.deepEqual(await handler({ sid: 'sid_dsh-1' }, {}), {
    items: [],
    hasMore: true,
    throughSeq: 42,
  })
  assert.deepEqual(seen[0], { sid: 'sid_dsh-1', dshSessionId: 'dsh-1' }, '没给的可选参数就不带')

  await handler({ sid: 'sid_dsh-1', beforeSeq: 10, maxMessages: 20 }, {})
  assert.deepEqual(seen[1], {
    sid: 'sid_dsh-1',
    dshSessionId: 'dsh-1',
    beforeSeq: 10,
    maxMessages: 20,
  })
})

test('session.page / session.refetch：下标与条数必须是非负整数；refetch 的 seq 必填', async () => {
  const handlers = build({ aliases: preloadedAliases(), sessionPager: fakePager() })
  const page = handlers['session.page']
  const refetch = handlers['session.refetch']
  assert.ok(page !== undefined && refetch !== undefined)

  for (const key of ['beforeSeq', 'maxMessages']) {
    for (const value of [-1, 1.5, '10', null, true]) {
      await assert.rejects(
        async () => page({ sid: 'sid_dsh-1', [key]: value }, {}),
        (error: unknown) => error instanceof ProtocolError && error.code === 'protocol/bad-frame',
        `${key}=${String(value)} 应当被拒`,
      )
    }
  }
  for (const value of [undefined, -1, 2.5, '3']) {
    await assert.rejects(
      async () => refetch({ sid: 'sid_dsh-1', seq: value }, {}),
      (error: unknown) => error instanceof ProtocolError && error.code === 'protocol/bad-frame',
      `seq=${String(value)} 应当被拒`,
    )
  }
  assert.deepEqual(await refetch({ sid: 'sid_dsh-1', seq: 9 }, {}), {
    record: { event: { seq: 9 } },
  })

  await assert.rejects(
    async () => page({ sid: 'sid_nobody' }, {}),
    (error: unknown) => error instanceof ProtocolError && error.code === 'session/not-found',
  )

  const without = build()
  assert.equal('session.page' in without, false)
  assert.equal('session.refetch' in without, false)
})

test('job.follow：把 sid 与 DSH 会话 id 都交给注册表，并回它给出来的起点', async () => {
  const seen: unknown[] = []
  const handlers = build({
    aliases: preloadedAliases(),
    jobSubscriptions: fakeSubscriptions({
      follow: (input) => {
        seen.push(input)
        return Promise.resolve({ from: 42 })
      },
    }),
  })
  const handler = handlers['job.follow']
  assert.ok(handler !== undefined)

  assert.deepEqual(await handler({ sid: 'sid_dsh-1', jobId: 'j1' }, {}), { from: 42 })
  assert.deepEqual(
    seen,
    [{ sid: 'sid_dsh-1', dshSessionId: 'dsh-1', jobId: 'j1' }],
    '订阅键是 sid（通道的键），宿主流要的是 DSH 会话 id —— 两个都得给',
  )

  await handler({ sid: 'sid_dsh-1', jobId: 'j1', from: 100 }, {})
  assert.deepEqual(seen[1], { sid: 'sid_dsh-1', dshSessionId: 'dsh-1', jobId: 'j1', from: 100 })
})

test('job.follow / job.unfollow：参数与别名不合规就回结构化错误', async () => {
  const handlers = build({ aliases: preloadedAliases(), jobSubscriptions: fakeSubscriptions() })
  const follow = handlers['job.follow']
  const unfollow = handlers['job.unfollow']
  assert.ok(follow !== undefined && unfollow !== undefined)

  for (const params of [undefined, {}, { sid: 'sid_dsh-1' }, { sid: 'sid_dsh-1', jobId: '' }]) {
    await assert.rejects(
      async () => follow(params, {}),
      (error: unknown) => error instanceof ProtocolError && error.code === 'protocol/bad-frame',
      `${JSON.stringify(params)} 应当被拒`,
    )
  }
  // 偏移是绝对字节下标：负数 / 小数 / 非数字都不接受。
  for (const from of [-1, 1.5, '10', null]) {
    await assert.rejects(
      async () => follow({ sid: 'sid_dsh-1', jobId: 'j1', from }, {}),
      (error: unknown) => error instanceof ProtocolError && error.code === 'protocol/bad-frame',
      `from=${String(from)} 应当被拒`,
    )
  }

  await assert.rejects(
    async () => follow({ sid: 'sid_nobody', jobId: 'j1' }, {}),
    (error: unknown) => error instanceof ProtocolError && error.code === 'session/not-found',
  )
  assert.throws(
    () => unfollow({ sid: 'sid_nobody', jobId: 'j1' }, {}),
    (error: unknown) => error instanceof ProtocolError && error.code === 'session/not-found',
  )
})

test('job.unfollow：回"有没有真的停掉一个"', () => {
  const answers = [true, false]
  const handlers = build({
    aliases: preloadedAliases(),
    jobSubscriptions: fakeSubscriptions({ unfollow: () => answers.shift() ?? false }),
  })
  const handler = handlers['job.unfollow']
  assert.ok(handler !== undefined)

  assert.deepEqual(handler({ sid: 'sid_dsh-1', jobId: 'j1' }, {}), { stopped: true })
  assert.deepEqual(handler({ sid: 'sid_dsh-1', jobId: 'j1' }, {}), { stopped: false })
})

test('订阅能力缺了：job.follow / job.unfollow 不在表里', () => {
  const without = build()
  assert.equal('job.follow' in without, false)
  assert.equal('job.unfollow' in without, false)
})

test('job.list：sid 反解回会话，逐字段映射任务行', async () => {
  const aliases = createFakeAliases()
  const sid = await aliases.ensure('dsh-1')
  const asked: string[] = []

  const handlers = build({
    aliases,
    jobs: {
      listOwnedBy: (dshSessionId) => {
        asked.push(dshSessionId)
        return [
          {
            id: 'j1',
            kind: 'shell',
            label: '构建',
            status: 'running',
            progress: '2/5',
            startedAt: 10,
            outputTotal: 42,
          },
          {
            id: 'j2',
            kind: 'shell',
            label: '测试',
            status: 'completed',
            detail: 'ok',
            startedAt: 5,
            finishedAt: 20,
            outputTotal: 7,
          },
        ]
      },
      readOutput: () => ({ chunks: [], next: 0, lossy: false }),
      subscribe: () => () => {},
    },
  })
  const handler = handlers['job.list']
  assert.ok(handler !== undefined)

  const listed = (await handler({ sid }, {})) as { jobs: Record<string, unknown>[] }
  assert.deepEqual(asked, ['dsh-1'], '手机给的是 sid，适配器要的是 DSH 会话 id')
  assert.deepEqual(listed.jobs, [
    { id: 'j1', kind: 'shell', label: '构建', status: 'running', startedAt: 10, outputTotal: 42, progress: '2/5' },
    { id: 'j2', kind: 'shell', label: '测试', status: 'completed', startedAt: 5, outputTotal: 7, detail: 'ok', finishedAt: 20 },
  ])
  assert.equal('owner' in (listed.jobs[0] ?? {}), false, '归属是电脑侧的内部事实，不必下发')
})

test('job.list：别名不认识 → session/not-found（绝不回空列表）', async () => {
  const handlers = build({ jobs: fakeJobs() })
  const handler = handlers['job.list']
  assert.ok(handler !== undefined)

  // 回空列表等于对手机撒谎（"这个会话没有任务"），而事实是"我不认识这个会话"。
  await assert.rejects(
    // 用 async 包一层：handler 是同步函数，抛错发生在 Promise.resolve 之前。
    async () => handler({ sid: 'sid_nobody' }, {}),
    (error: unknown) => error instanceof ProtocolError && error.code === 'session/not-found',
  )
})

test('job.list：sid 缺失或形状不对 → protocol/bad-frame', async () => {
  const handlers = build({ jobs: fakeJobs() })
  const handler = handlers['job.list']
  assert.ok(handler !== undefined)

  for (const params of [undefined, {}, { sid: '' }, { sid: 42 }, 'nope']) {
    await assert.rejects(
      async () => handler(params, {}),
      (error: unknown) => error instanceof ProtocolError && error.code === 'protocol/bad-frame',
      `${JSON.stringify(params)} 应当被拒`,
    )
  }
})

test('可选服务缺了：`job.*` 干脆不在表里（能力位与能力清单同源）', async () => {
  const withoutJobs = build()
  assert.equal('job.list' in withoutJobs, false, '没有 jobs 服务就不该挂这个方法')
  // `repo.info` 报的是表的键，所以能力位自动跟着走 —— 手机侧看到的是"没这个方法"，
  // 而不是一个会被点开、然后回错的按钮。
  const info = handlers_info(withoutJobs)
  assert.deepEqual(info.methods, ['devices.list', 'repo.info', 'session.list', 'session.prompt'])

  const withJobs = build({ jobs: fakeJobs() })
  assert.equal('job.list' in withJobs, true)
  assert.deepEqual(handlers_info(withJobs).methods, [
    'devices.list',
    'job.list',
    'repo.info',
    'session.list',
    'session.prompt',
  ])
})

test('session.list：逐字段映射，别名在方法面合成，**DSH 会话 id 不过线**', async () => {
  const handlers = build({
    sessions: {
      list: () =>
        Promise.resolve([
          { dshSessionId: 'dsh-1', updatedAt: 200, running: true, blank: false, subagent: false, cwd: '/repo/a' },
          { dshSessionId: 'dsh-2', updatedAt: 100, running: false, blank: true, subagent: true },
        ]),
      prompt: () => Promise.resolve({ accepted: true }),
    },
  })
  const handler = handlers['session.list']
  assert.ok(handler !== undefined)

  const listed = (await handler(undefined, {})) as { sessions: Record<string, unknown>[] }
  assert.deepEqual(listed.sessions, [
    { sid: 'sid_dsh-1', updatedAt: 200, running: true, blank: false, subagent: false, cwd: '/repo/a' },
    { sid: 'sid_dsh-2', updatedAt: 100, running: false, blank: true, subagent: true },
  ])
  for (const row of listed.sessions) {
    assert.equal('dshSessionId' in row, false, 'DSH 会话 id 绝不能过线 —— 中继与手机只见 sid')
    assert.match(String(row['sid']), /^[A-Za-z0-9_-]+$/, 'sid 要过 AAD 的字符集要求')
  }
})

test('session.list：并发分配别名（不同会话互不影响）', async () => {
  const seen: string[] = []
  const handlers = build({
    sessions: {
      list: () =>
        Promise.resolve(
          Array.from({ length: 5 }, (_, i) => ({
            dshSessionId: `dsh-${i}`,
            updatedAt: i,
            running: false,
            blank: false,
            subagent: false,
          })),
        ),
      prompt: () => Promise.resolve({ accepted: true }),
    },
    aliases: {
      ...createFakeAliases(),
      ensure: (id) => {
        seen.push(id)
        return Promise.resolve(`sid_${id}`)
      },
    },
  })
  const handler = handlers['session.list']
  assert.ok(handler !== undefined)

  const listed = (await handler(undefined, {})) as { sessions: { sid: string }[] }
  assert.equal(listed.sessions.length, 5)
  assert.deepEqual(seen.sort(), ['dsh-0', 'dsh-1', 'dsh-2', 'dsh-3', 'dsh-4'], '每个会话都要拿到别名')
  assert.equal(listed.sessions[4]?.sid, 'sid_dsh-4', '顺序与权威给的一致（已按活动排序）')
})

test('devices.list：含已吊销的，且不泄漏公钥', async () => {
  const handlers = build({
    devices: () => [
      { id: 'dev-1', name: '我的手机', pairedAt: 1000, revoked: false },
      { id: 'dev-2', name: '旧手机', pairedAt: 900, revoked: true },
    ],
  })
  const handler = handlers['devices.list']
  assert.ok(handler !== undefined)

  const listed = (await handler(undefined, {})) as { devices: Record<string, unknown>[] }
  assert.deepEqual(listed.devices, [
    { devId: 'dev-1', name: '我的手机', pairedAt: 1000, revoked: false },
    { devId: 'dev-2', name: '旧手机', pairedAt: 900, revoked: true },
  ])
  for (const device of listed.devices) {
    assert.equal('edPub' in device || 'dhPub' in device, false, '公钥不该出现在给手机的清单里')
  }
})

/** presence 上报面的替身：把每次调用记下来。 */
function fakePresence() {
  const calls: { what: string; devId: string; sid?: string; state?: string; sids?: readonly string[] }[] = []
  return {
    calls,
    sink: {
      online: (devId: string) => calls.push({ what: 'online', devId }),
      offline: (devId: string) => calls.push({ what: 'offline', devId }),
      app: (devId: string, state: string) => calls.push({ what: 'app', devId, state }),
      subscriptions: (devId: string, sids: readonly string[]) =>
        calls.push({ what: 'subscriptions', devId, sids }),
      interacted: (devId: string, sid: string) => calls.push({ what: 'interacted', devId, sid }),
    },
  }
}

test('sync.hello：一次声明整份订阅集 + 前后台态，恢复语义复用 session.subscribe', async () => {
  const seen: unknown[] = []
  const presence = fakePresence()
  const handlers = build({
    aliases: preloadedAliases(),
    sessionSubscriptions: fakeSessionSubscriptions({
      subscribe: (input) => {
        seen.push(input)
        return Promise.resolve({ since: input.since ?? 0, hasMore: input.since === undefined })
      },
    }),
    connection: { deviceId: () => 'dev-1', presence: presence.sink },
  })
  const handler = handlers['sync.hello']
  assert.ok(handler !== undefined)

  const reply = (await handler(
    {
      app: 'foreground',
      sessions: [{ sid: 'sid_dsh-1', since: 12 }, { sid: 'sid_dsh-1' }],
    },
    {},
  )) as { app: string; sessions: { sid: string; since: number; hasMore: boolean }[] }

  assert.equal(reply.app, 'foreground')
  assert.deepEqual(reply.sessions, [
    { sid: 'sid_dsh-1', since: 12, hasMore: false },
    { sid: 'sid_dsh-1', since: 0, hasMore: true },
  ])
  assert.deepEqual(
    seen,
    [
      { sid: 'sid_dsh-1', dshSessionId: 'dsh-1', since: 12 },
      { sid: 'sid_dsh-1', dshSessionId: 'dsh-1' },
    ],
    '每个声明的会话都走同一个订阅面：不另起一套恢复语义',
  )
  // **前后台态在订阅之前上报**：反了会出现一段"已订阅但仍判不在前台"的窗口
  // （那段时间里审批会被让回桌面）。
  assert.deepEqual(presence.calls, [
    { what: 'app', devId: 'dev-1', state: 'foreground' },
  ])
})

test('sync.hello：app / sessions 形状不合规 → protocol/bad-frame；别名未知 → session/not-found', async () => {
  const handlers = build({
    aliases: preloadedAliases(),
    sessionSubscriptions: fakeSessionSubscriptions(),
    connection: { deviceId: () => null, presence: fakePresence().sink },
  })
  const handler = handlers['sync.hello']
  assert.ok(handler !== undefined)

  for (const params of [
    { sessions: [] },
    { app: 'foreground' },
    { app: 'visible', sessions: [] },
    { app: 'foreground', sessions: {} },
    { app: 'foreground', sessions: [{}] },
    { app: 'foreground', sessions: [{ sid: '' }] },
    { app: 'foreground', sessions: [{ sid: 'sid_dsh-1', since: -1 }] },
  ]) {
    await assert.rejects(
      async () => handler(params, {}),
      (error: unknown) => error instanceof ProtocolError && error.code === 'protocol/bad-frame',
      `${JSON.stringify(params)} 应当被拒`,
    )
  }

  await assert.rejects(
    async () => handler({ app: 'foreground', sessions: [{ sid: 'sid_nobody' }] }, {}),
    (error: unknown) => error instanceof ProtocolError && error.code === 'session/not-found',
    '与 session.subscribe 逐字一致：一个别名未知就整票失败，客户端动作正是「从列表移除」',
  )
})

test('interaction.respond：内核照常被调，并记 lastInteractedAt（时间戳由连接器盖）', () => {
  const presence = fakePresence()
  const seen: unknown[] = []
  const handlers = build({
    aliases: preloadedAliases(),
    interaction: {
      pendingOf: () => [],
      respond: (params) => {
        seen.push(params)
        return { itemId: 'i:call-1' }
      },
    },
    connection: { deviceId: () => 'dev-1', presence: presence.sink },
  })
  const handler = handlers['interaction.respond']
  assert.ok(handler !== undefined)

  const answers = [{ id: 'call-1', selected: ['allowed-once'] }]
  assert.deepEqual(handler({ sid: 'sid_dsh-1', callId: 'call-1', answers }, {}), {
    itemId: 'i:call-1',
  })
  // 分叉点在内核里（它问一次 settleClaim），处理器不替它决定这是审批还是提问。
  assert.deepEqual(seen, [{ sid: 'sid_dsh-1', callId: 'call-1', answers }])
  // **lastInteractedAt 由连接器盖**：客户端时钟会漂，而这个值只喂仲裁排序的并列判据。
  assert.deepEqual(presence.calls, [{ what: 'interacted', devId: 'dev-1', sid: 'sid_dsh-1' }])
})

test('interaction.respond / sync.hello 的能力缺失时整个方法不出现（能力位模型）', () => {
  const bare = build()
  assert.equal('interaction.respond' in bare, false)
  assert.equal('sync.hello' in bare, false)

  const full = build({
    sessionSubscriptions: fakeSessionSubscriptions(),
    interaction: { pendingOf: () => [], respond: () => ({ itemId: 'i:x' }) },
  })
  assert.deepEqual(handlers_info(full).methods, [
    'devices.list',
    'interaction.respond',
    'repo.info',
    'session.list',
    'session.prompt',
    'session.subscribe',
    'session.unsubscribe',
    'sync.hello',
  ])
})
