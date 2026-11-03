import assert from "node:assert/strict"
import { test } from "node:test"

import { BUILTIN_RELAY_URL, Config } from "../src/config.js"

test("开箱即用：没写 config 段时 relayUrl 默认内置中转（装完不用编辑 YAML）", () => {
  const built = Config({})
  assert.equal(built.relayUrl.get(), BUILTIN_RELAY_URL)
  // 直连与明文开关仍然是"不配置就不存在"，别被默认值顺手打开。
  assert.equal(built.listenPort.get(), 0)
  assert.equal(built.allowInsecureLocal.get(), false)
  assert.equal(built.allowInsecurePublic.get(), false)
})

test("显式写空串仍然算「没配」：默认值不能把用户清空的地址又填回去", () => {
  const built = Config({ relayUrl: "" })
  assert.equal(built.relayUrl.get(), "")
})
