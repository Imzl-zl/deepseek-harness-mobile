/**
 * 直连监听面的配置面（`docs/subsystems/connector-and-relay.md` §1.1）。
 *
 * ## 默认值改过一次方向（2026-11-03）
 *
 * 原判据：`listenPort` 默认 `0`（不监听），理由是"默认敞开的端口操作者不会预期"。
 * **2026-11-03 由产品方（用户原话「局域网的也能启动啊」）改成默认开**：
 * 局域网直连是"中转不通时的唯一活路"，而"装完还得先填端口"等于这条路默认不存在。
 *
 * 代价与边界写清楚了才改的：
 * - 监听面要过**设备身份握手**，未配对的对端握不上手 —— 它不是开放的门，只是开着的窗；
 * - 真不想要：卡片里勾「停用直连」（写 `listenPort: 0`），或配置里写 `listenPort: 0`；
 * - **`0` 仍然是"关"**，只有"没配"才落到默认值 —— 这一格不能反，否则关不掉。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { Config, DEFAULT_LISTEN_HOST, DEFAULT_LISTEN_PORT } from '../src/config.js'

/** Schemastery 的 schema 可直接当函数调用，得到补全默认值后的配置。 */
const resolve = (input: Record<string, unknown>): Record<string, unknown> =>
  (Config as unknown as (value: unknown) => Record<string, unknown>)(input)

/**
 * 取一个 `.volatile()` 字段的值。
 *
 * `Volatile<T>` 是**稳定引用**（`{ get() }`）而不是普通值（`tools.md` 的 Pitfalls 记着这条）——
 * 所以断言要经 `.get()`，与 `index.ts` 的读法一致。
 */
const valueOf = (config: Record<string, unknown>, key: string): unknown =>
  (config[key] as { get(): unknown }).get()

const MINIMAL = { relayUrl: 'wss://relay.example/ws', relayTokenRef: 'connector-token' }

test('默认就监听：8790 / 0.0.0.0（局域网直连要能直接用，不用先填端口）', () => {
  const config = resolve(MINIMAL)
  assert.equal(valueOf(config, 'listenPort'), DEFAULT_LISTEN_PORT, '没配就该用默认端口')
  assert.equal(valueOf(config, 'listenHost'), DEFAULT_LISTEN_HOST, '默认要能被手机连到')
})

test('显式 0 仍然是"关"：关不掉的话卡片上的「停用直连」就是假旋钮', () => {
  const config = resolve({ ...MINIMAL, listenPort: 0 })
  assert.equal(valueOf(config, 'listenPort'), 0)
})

test('显式配置能覆盖：端口与地址都取配置值', () => {
  const config = resolve({ ...MINIMAL, listenPort: 8787, listenHost: '100.64.0.1' })
  assert.equal(valueOf(config, 'listenPort'), 8787)
  assert.equal(valueOf(config, 'listenHost'), '100.64.0.1')
})
