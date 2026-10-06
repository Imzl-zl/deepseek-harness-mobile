/**
 * 直连监听面的配置面（`docs/subsystems/connector-and-relay.md` §1.1）。
 *
 * 只钉**一条安全相关的默认值**：`listenPort` 默认是 `0`（不监听）。
 *
 * 这条值得一条用例，因为它是一个"默认敞开"的隐患：插件装进 profile 后没人会主动去配监听，
 * 而一个默认监听的桥接会在真机上表现为"莫名其妙多开了一个端口"—— 操作者不会预期它，
 * 排查时也不会往那里想。默认关、要显式开，是这里唯一可接受的方向。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { Config } from '../src/config.js'

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

test('默认不监听：listenPort 是 0（"默认敞开"是这里唯一不可接受的方向）', () => {
  const config = resolve(MINIMAL)
  assert.equal(valueOf(config, 'listenPort'), 0, '没配就不监听 —— 不是"监听了但没人用"')
  assert.equal(valueOf(config, 'listenHost'), '127.0.0.1', '默认只在本机，不默认暴露到网络')
})

test('显式配置能覆盖：端口与地址都取配置值', () => {
  const config = resolve({ ...MINIMAL, listenPort: 8787, listenHost: '100.64.0.1' })
  assert.equal(valueOf(config, 'listenPort'), 8787)
  assert.equal(valueOf(config, 'listenHost'), '100.64.0.1')
})

test('端口越界被拦（0 到 65535 之外不是合法端口）', () => {
  assert.throws(() => resolve({ ...MINIMAL, listenPort: 70_000 }), '越界端口要在配置校验处被拦')
  assert.throws(() => resolve({ ...MINIMAL, listenPort: -1 }))
})
