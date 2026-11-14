/**
 * `caps.team` 的判据（Agent Teams 任务板的**只读**面）。
 *
 * 这个能力位是这一轮连接器唯一的改动，所以单独钉一条：它的判据是
 * **`agentTeams` 服务在不在**（`packages/team/agent-team/src/index.ts:61`），
 * 而它**不决定任何方法** —— 任务板走的是 `session.projections` 里原样透传的
 * `agentTeam` 投影，不新增方法面。
 *
 * 为什么值得一条用例：能力位是"手机上那枚 tab 出不出现"的唯一输入。写成
 * `== true` 之外的任何形态（或漏读一个键），症状都是**静默少一块界面** ——
 * 与 `caps.files` / `caps.changes` 那几条同一个理由。
 *
 * 取舍见 `.agents/notes/implemented/2026-11-14-agent-team-readonly.md`。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { readCaps } from '../src/dsh/caps.js'

/** 只回答"某个服务键在不在"的宿主替身（与 `changes.test.ts` 等处同一个形状）。 */
function fakeCtx(services: Record<string, unknown>) {
  return { get: (key: string) => services[key] } as never
}

test('agentTeams 服务在 ⇒ caps.team = true（且不新增方法）', () => {
  const ctx = fakeCtx({ agentTeams: { setEnabled: async () => undefined } })
  assert.equal(readCaps(ctx).team, true)
})

test('agentTeams 缺席（老宿主 / 没带 tool bundle）⇒ caps.team = false', () => {
  const ctx = fakeCtx({})
  assert.equal(readCaps(ctx).team, false)
})

test('caps.team 与任务板投影是两件事：能力位只回答"有没有这个服务"', () => {
  // 服务在但 Team 关着（投影 `enabled: false`）仍然是 `team: true` ——
  // "没开"由投影表达，不能塌进能力位（那会让用户以为这台电脑不支持）。
  const ctx = fakeCtx({ agentTeams: {} })
  assert.equal(readCaps(ctx).team, true)
})
