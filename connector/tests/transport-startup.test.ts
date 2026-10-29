/**
 * 「起传输时哪些缺席算配置允许的」的回归 —— 2026-10-29 的「无令牌可挂载」那条规则。
 *
 * ## 为什么这条必须有自己的网
 *
 * 上轮把「凭据里没有连接器令牌 → 拒绝挂载」改成「只让中转通道起不来」，理由是
 * 自锁：令牌能在面板里删，而删了以后重启就连面板都打不开（管理面挂在 `start-transport`
 * 之后）。这条规则的证明当时只有一次隔离实例手工 e2e —— 它恰恰是**以后最容易被
 * "顺手收紧"** 的一类代码：任何人把 `catch` 去掉、或者把 `instanceof RelayTokenError`
 * 放宽成 `catch {}`（吞掉坏地址、端口被占），手机上都会表现为"整个插件不工作"，
 * 而门禁全绿。
 *
 * 所以钉两条：
 *
 * 1. **容忍判据只认 `RelayTokenError`** —— 不是"随便什么错都放过"；
 * 2. **`listenPort = 0` 是"不监听"，不是失败** —— 但它同样不该被当成"起成功了"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { RelayTokenError } from '../src/dsh/relay-token.js'
import {
  createTransportStarter,
  toleratesRelayStartFailure,
  type StartupPorts,
} from '../src/transport/startup.js'

/** 可编程的起停替身：记调用，按配置抛。 */
function ports(spec: {
  listenPort: number
  relayError?: unknown
  directError?: unknown
}): StartupPorts & { calls: string[]; tolerated: unknown[] } {
  const calls: string[] = []
  const tolerated: unknown[] = []
  return {
    calls,
    tolerated,
    startRelay: async () => {
      calls.push('relay')
      if (spec.relayError !== undefined) throw spec.relayError
    },
    startDirect: async () => {
      calls.push('direct')
      if (spec.directError !== undefined) throw spec.directError
    },
    listenPort: () => spec.listenPort,
    onTolerated: (error) => { tolerated.push(error) },
  }
}

test('容忍判据：只认「凭据里读不到令牌」，别的错误一律不放行', () => {
  assert.equal(toleratesRelayStartFailure(new RelayTokenError('凭据里没有连接器令牌记录')), true)
  // 坏地址 / 端口被占 / 宿主抛出来的东西 —— 这些必须吵（静默的话手机上表现为"插件不工作"）。
  for (const error of [
    new Error('listen EADDRINUSE: 8790'),
    new Error('relayUrl 必须是 ws:// 或 wss://'),
    'plain string',
    undefined,
    null,
  ]) {
    assert.equal(toleratesRelayStartFailure(error), false, `${String(error)} 不该被当成"允许的缺席"`)
  }
})

test('缺令牌：不抛、留痕，直连照常起（插件挂得上，面板还能打开自救）', async () => {
  const p = ports({ listenPort: 8790, relayError: new RelayTokenError('记录缺失') })
  await createTransportStarter(p)()

  assert.deepEqual(p.calls, ['relay', 'direct'], '中转失败不能让直连也起不来')
  assert.equal(p.tolerated.length, 1, '容忍要留痕（日志 + 「连接」卡的原因）')
})

test('缺令牌 + 没配直连：整体不抛（这正是"删了令牌再重启"那条路径）', async () => {
  const p = ports({ listenPort: 0, relayError: new RelayTokenError('记录缺失') })
  await assert.doesNotReject(() => createTransportStarter(p)())
  assert.deepEqual(p.calls, ['relay'], 'listenPort=0 时根本不该调直连')
})

test('别的失败照旧整体抛出，且不再接着起直连（真故障不许半挂）', async () => {
  const p = ports({ listenPort: 8790, relayError: new Error('relayUrl 必须是 ws:// 或 wss://') })
  await assert.rejects(() => createTransportStarter(p)(), /relayUrl/)

  assert.deepEqual(p.calls, ['relay'], '第一个真故障就该中断，不该继续起下一条')
  assert.equal(p.tolerated.length, 0)
})

test('listenPort = 0：不调直连，也不算失败（配置明说"不监听"）', async () => {
  const p = ports({ listenPort: 0 })
  await createTransportStarter(p)()
  assert.deepEqual(p.calls, ['relay'])
})

test('直连端口被占：原样抛出（界面要看见原因，而不是停在假的"已启动"）', async () => {
  const p = ports({ listenPort: 8790, directError: new Error('listen EADDRINUSE: 8790') })
  await assert.rejects(() => createTransportStarter(p)(), /EADDRINUSE/)
  assert.deepEqual(p.calls, ['relay', 'direct'])
})

test('每次调用都重读 listenPort（面板热改端口后，下一次起就该跟着走）', async () => {
  let port = 0
  const calls: string[] = []
  const start = createTransportStarter({
    startRelay: async () => { calls.push('relay') },
    startDirect: async () => { calls.push('direct') },
    listenPort: () => port,
    onTolerated: () => {},
  })

  await start()
  assert.deepEqual(calls, ['relay'])

  port = 8790
  await start()
  assert.deepEqual(calls, ['relay', 'relay', 'direct'], '第二次读到了新端口')
})
