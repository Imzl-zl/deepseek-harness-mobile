/**
 * 管理台错误码翻译与「最后一个管理员」按钮的回归。
 *
 * 2026-11-06 真机两条症状：
 * 1. 只剩一个管理员时点「降为用户」→ 服务端 409 `last-admin`，页面把这个码
 *    **原样**弹出来；用户不知道"至少要留一个管理员"。
 * 2. 客户端没有提前禁用按钮，于是每个必败的操作都要先点一次、再被拒一次。
 *
 * 这里的覆盖断言会扫服务端源码里所有 `error: '…'` 字面量 —— 新加一个错误码
 * 却忘了翻译，测试立刻红。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

import { ADMIN_PAGE } from '../src/admin/page.ts'
import { ADMIN_ERROR_TEXT, adminErrorText } from '../src/admin/errors.ts'

const sourceOf = (relative: string): string =>
  readFileSync(new URL(relative, import.meta.url), 'utf8')

test('所有服务端错误码都有人话（新码漏翻会红）', () => {
  const codes = new Set<string>()
  for (const file of ['../src/admin/routes.ts', '../src/server.ts']) {
    for (const match of sourceOf(file).matchAll(/error:\s*'([a-z0-9-]+)'/g)) {
      if (match[1] !== undefined) codes.add(match[1])
    }
  }
  assert.ok(codes.size >= 20, '扫描到的码太少，说明正则或源码形状变了')
  const missing = [...codes].filter((code) => ADMIN_ERROR_TEXT[code] === undefined).sort()
  assert.deepEqual(missing, [], `这些错误码还没有人话：${missing.join('、')}`)
})

test('last-admin 翻成人话，不把码当文案', () => {
  const text = adminErrorText('last-admin', 409)
  assert.equal(text, '至少要保留一个管理员。')
  assert.doesNotMatch(text, /last-admin/, '用户不该看到协议码')
  // 未知码：人话打头，码放括号里当诊断信息。
  assert.match(adminErrorText('mystery', 500), /操作失败.*mystery/)
  assert.equal(adminErrorText(undefined, 502), '操作失败（HTTP 502）')
})

test('页面：写操作失败走翻译函数，不再原样弹 data.error', () => {
  assert.ok(
    ADMIN_PAGE.includes('errorText(data && data.error, response.status)'),
    'post() 的失败分支必须翻译错误码',
  )
  assert.equal(
    ADMIN_PAGE.includes("(data && data.error) || ('操作失败 HTTP '"),
    false,
    '旧的原样弹码写法不许回来',
  )
})

test('页面：只剩一个管理员时降级按钮真的 disabled，并给一句人话', () => {
  assert.ok(ADMIN_PAGE.includes('node.disabled = disabled === true'), 'btn 要把 disabled 落到 DOM 上')
  assert.ok(ADMIN_PAGE.includes('activeAdmins <= 1'), '要先算活跃管理员数')
  assert.ok(ADMIN_PAGE.includes('当前只有一个管理员。要降级它，先把另一个账号设为管理员。'),
    '按钮旁边要有一句能看懂的原因')
  assert.ok(ADMIN_PAGE.includes('至少要保留一个管理员。'), '按钮 title 也要给人话')
})
