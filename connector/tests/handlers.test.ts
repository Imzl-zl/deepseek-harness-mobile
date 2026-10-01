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
  return { kill: () => 'requested', ...overrides }
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
    sessions: { list: () => Promise.resolve([]) },
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
  assert.deepEqual(info.methods, ['devices.list', 'repo.info', 'session.list'])
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
  ])

  const neither = build()
  assert.equal('job.list' in neither, false)
  assert.equal('job.kill' in neither, false)
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
  assert.deepEqual(info.methods, ['devices.list', 'repo.info', 'session.list'])

  const withJobs = build({ jobs: fakeJobs() })
  assert.equal('job.list' in withJobs, true)
  assert.deepEqual(handlers_info(withJobs).methods, [
    'devices.list',
    'job.list',
    'repo.info',
    'session.list',
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
