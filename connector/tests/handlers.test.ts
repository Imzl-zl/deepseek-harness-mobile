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
  assert.deepEqual(info.methods, ['devices.list', 'repo.info'])
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
