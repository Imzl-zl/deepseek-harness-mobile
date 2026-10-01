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

import { createHandlers } from '../src/handlers.js'
import { WIRE_VERSION } from '../src/protocol/frame.js'
import type { Caps } from '../src/dsh/caps.js'

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
    // 会话面的替身：`list` 给 DSH 权威行，`aliases` 给通道自己的别名。
    sessions: { list: () => Promise.resolve([]) },
    aliases: { ensure: (id) => Promise.resolve(`sid_${id}`) },
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
