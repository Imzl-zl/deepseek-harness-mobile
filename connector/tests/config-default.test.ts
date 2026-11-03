import assert from "node:assert/strict"
import { test } from "node:test"

import { BUILTIN_RELAY_URL, Config, DEFAULT_LISTEN_HOST, DEFAULT_LISTEN_PORT, relayUrlOrDefault } from "../src/config.js"

test("构造期：schema 默认值是内置中转，但**这只影响 Config({}) 这种直接构造**", () => {
  const built = Config({})
  assert.equal(built.relayUrl.get(), BUILTIN_RELAY_URL)
  // 直连默认就开（2026-11-03 产品方要求"局域网也能直接用"），明文两档仍然默认关。
  assert.equal(built.listenPort.get(), DEFAULT_LISTEN_PORT)
  assert.equal(built.listenHost.get(), DEFAULT_LISTEN_HOST)
  assert.equal(built.allowInsecureLocal.get(), false)
  assert.equal(built.allowInsecurePublic.get(), false)
})

test("显式写空串：schema 层面仍然是空（不硬填回去）", () => {
  const built = Config({ relayUrl: "" })
  assert.equal(built.relayUrl.get(), "")
})

test("运行时空着也落到内置中转（2026-11-03 真机：schema 默认值到不了 loader 那份 config）", () => {
  // 现场：装完 0.1.12、profile 里没有 config 段 → 面板「连接」卡显示「未配置中转」，
  // 点启动报「中转地址解析失败：」。所以兜底必须在读取处（`relayUrlInUse`）。
  assert.equal(relayUrlOrDefault(undefined), BUILTIN_RELAY_URL)
  assert.equal(relayUrlOrDefault(""), BUILTIN_RELAY_URL)
  assert.equal(relayUrlOrDefault("wss://relay.example.com/ws/connector"), "wss://relay.example.com/ws/connector")
})
