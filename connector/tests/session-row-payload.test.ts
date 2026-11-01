/**
 * 列表行的投影白名单（`protocol/session-row.ts`）：**两端必须逐字相等**。
 *
 * ## 这一组守什么
 *
 * `session.list` 的每一行原本带着宿主那整块 projection summary（本机 94.5% 的包体、
 * 其中 `turnOutline` + `trajectory` 一项就占 1 MB），而手机读一行只用五个键。
 * 白名单是"哪几个键过线"的唯一判据，所以它不能靠人记：
 *
 * 1. **白名单 = `readSessionSummary` 真正读的那几个键** —— 直接解析
 *    `app/lib/wire/rpc/session.dart` 的源码，多一个少一个都红；
 * 2. **`pickSessionRowProjectionValues` 不放行名单外的键**（含宿主将来新加的投影）；
 * 3. **本仓自带的两个重投影不在名单里**：`trajectory` / `turnOutline` 归
 *    `session.projections` 的完整快照，搭列表便车就是白搬字节。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'

import {
  SESSION_ROW_PROJECTION_KEYS,
  pickSessionRowProjectionValues,
} from '../src/protocol/session-row.js'

const APP_ROW_PARSER = join(import.meta.dirname, '..', '..', 'app', 'lib', 'wire', 'rpc', 'session.dart')

/** 手机侧 `readSessionSummary` 从 `values` 里取的键（`values?['x']` / `values['x']`）。 */
function appReadKeys(): string[] {
  const source = readFileSync(APP_ROW_PARSER, 'utf8')
  // 只认这两种写法：行解析器里读投影值的全部形态（`values?['k']` 与 `values['k']`）。
  const matches = source.matchAll(/values\??\[\s*'([^']+)'\s*\]/g)
  return [...new Set([...matches].map((match) => match[1]!))].sort()
}

test('白名单与手机侧的行解析器逐字相等（多一个白搬字节，少一个界面缺数据）', () => {
  const appKeys = appReadKeys()
  assert.ok(appKeys.length > 0, '没在 app/lib/wire/rpc/session.dart 里找到 values[...] 读点，解析口径坏了')
  assert.deepEqual([...SESSION_ROW_PROJECTION_KEYS].sort(), appKeys)
})

test('名单外的键一律不放行：宿主新加的投影、本仓自带的两个重投影都不许过线', () => {
  const hostValues = {
    title: 't',
    modelSelection: { provider: 'p', model: 'm' },
    subagentTiming: {},
    tokenUsage: {},
    subagentCatalog: [],
    // 下面这些手机读一行时一眼都不看，其中前两项是单包的最大两份
    turnOutline: [{ turn: 1 }],
    trajectory: { turns: [] },
    sessionStats: {},
    goal: {},
    contextPressure: {},
    todos: [],
    inbox: {},
    contextBreakdown: {},
    sessionListMetadata: {},
    permissions: {},
    plan: {},
    userQuestions: [],
    workingDirectory: 'D:/x',
    subagent: {},
    agentPreset: {},
    imageLimits: {},
    // 宿主将来新加的键：同样不许自动过线
    someFutureProjection: { big: true },
  }

  const picked = pickSessionRowProjectionValues(hostValues)
  assert.deepEqual(Object.keys(picked).sort(), [...SESSION_ROW_PROJECTION_KEYS].sort())
  for (const dropped of ['turnOutline', 'trajectory', 'someFutureProjection']) {
    assert.equal(dropped in picked, false, `${dropped} 不该过线`)
  }
})

test('缺席的键不补 undefined（缺席与 null 在手机侧是两种意思）', () => {
  const picked = pickSessionRowProjectionValues({ title: '只有标题' })
  assert.deepEqual(picked, { title: '只有标题' })
  assert.equal('tokenUsage' in picked, false)
})
