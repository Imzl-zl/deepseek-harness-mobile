import assert from "node:assert/strict"
import { test } from "node:test"

import { describeUpgradeFailure } from "../src/transport/relay-link.js"

test("升级被拒的状态码翻译成人话：401/403/404 各有下一步，别的只说状态码", () => {
  assert.match(describeUpgradeFailure(401), /令牌/)
  assert.match(describeUpgradeFailure(401), /401/)
  // 403 在中转那边有四种原因，文案要把"账号被停用"这一支写出来：2026-11-03 的
  // 那次真因就是它，旧文案只提"id 不一致"，把排查方向带偏了。
  assert.match(describeUpgradeFailure(403), /账号/)
  assert.match(describeUpgradeFailure(403), /id/)
  assert.match(describeUpgradeFailure(404), /\/ws\/connector/)
  assert.match(describeUpgradeFailure(502), /502/)

  // 四种必须互不相同：401 与 404 的下一步动作完全不同（换令牌 / 改地址）。
  const all = [401, 403, 404, 502].map(describeUpgradeFailure)
  assert.equal(new Set(all).size, 4, "状态码翻译不能塌成同一句话")
})
