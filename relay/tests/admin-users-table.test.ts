/**
 * 管理台「用户」表的列语义。
 *
 * 2026-11-06 真机：默认电脑数是 2，行里却显示 `1 / 1`。根因是那一格用了
 * `activeConnectors / connectors`（未吊销令牌 / 全部令牌），而表头写的是「#电脑」——
 * 用户自然读成「已用 / 上限」。
 *
 * 这里钉死两件事：
 * 1. `#电脑` 只表达**已用 / 上限**；`#在线` 另有列，不混进这一格；
 * 2. 上限只算一次（`computerLimit`），表格与「改电脑数」共用，不写第二份。
 *
 * 页面是内联模板字符串，没法在 Node 里整页渲染；断言直接扫产出的脚本 ——
 * 这两条都是**文本形状**上的不变量，变异时能立刻变红。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { ADMIN_PAGE } from '../src/admin/page.ts'

test('管理台用户表：#电脑 = 已用/上限，不是 在线/已绑定', () => {
  assert.ok(ADMIN_PAGE.includes('#电脑 已用/上限'), '表头必须写明这一格是「已用/上限」')
  assert.ok(
    ADMIN_PAGE.includes("row.activeConnectors + ' / ' + computerLimit"),
    '「已用」必须是未吊销的电脑数，上限用同一个 computerLimit',
  )
  assert.equal(
    ADMIN_PAGE.includes("row.activeConnectors + ' / ' + row.connectors"),
    false,
    '旧的 未吊销/全部令牌 写法不许回来 —— 用户会把它读成 已用/上限',
  )
})

test('管理台用户表：上限只算一次（默认值兜底不写第二份）', () => {
  const expression = 'var computerLimit = row.maxConnectors === null ? state.auth.defaultMaxConnectors : row.maxConnectors'
  assert.equal(
    ADMIN_PAGE.split(expression).length - 1,
    1,
    '`maxConnectors ?? defaultMaxConnectors` 只能出现一次，否则两处会漂',
  )
})
