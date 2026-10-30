/**
 * 装配层的接线：面板「连接」卡的**读取投影**，以及"抽出来的逻辑真的被用上"。
 *
 * ## 为什么读取投影要单独钉
 *
 * 卡片自己（`admin/connection-card.ts` 的 `createConnectionCard`）有完整用例，
 * 但它读到的**真值**是装配层拼出来的：`settings.describe` 的快照 + 通道注册表 +
 * 凭据记录状态。那一段原来是一个写在 `index.ts` 装配闭包里的 `read()`，三个面各读一格，
 * 只能靠隔离实例手工 e2e 看它拼得对不对。它的错法**都不报错**：
 *
 * - 快照里没有 `relayUrl` 时"猜"一个默认地址 → 用户看到一条自己没配过的转发目标；
 * - `listenPort` 取不到时回 `0` → 面板显示"不监听"，而实际监听面在跑；
 * - 通道注册表还没建时抛错 → 整张卡 500，而不是如实显示"未运行"；
 * - `allowInsecurePublic` 用 `Boolean(value)` 判 → 字符串 `"false"` 被当成开。
 *
 * 所以投影抽成 `readConnectionState(inputs)`，本文件钉它的每一格。
 *
 * ## 为什么还要一条"装配层真的用了它"
 *
 * 抽走的逻辑可以是死代码：模块健在、用例全绿，而线上那条路仍在用本地副本。
 * 这里按 `tests/connection-surface.test.ts` 的既有做法**读源码**断言 —— 那条门禁
 * 也是"读 `index.ts` 文本"，同一个口径。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

import { readConnectionState, type ConnectionReadInputs } from '../src/admin/connection-card.js'
import type { ChannelState } from '../src/transport/channels.js'

/**
 * 去注释 + 压空白：让"接线"断言落在代码上。
 *
 * 只剥块注释与**整行**的 `//` 注释（不碰行尾注释，免得把 `'ws://…'` 这类字符串切坏），
 * 再把连续空白压成一个空格 —— 多行实参因此能用一行正则匹配，普通重排/换行不会假阴。
 */
function codeOf(source: string): string {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/^[ \t]*\/\/.*$/gm, ' ')
    .replace(/\s+/g, ' ')
}

/** 一条通道状态（只有 `id` 与 `running` / `connected` 参与投影）。 */
function channel(over: Partial<ChannelState> & { id: string }): ChannelState {
  return {
    label: over.id,
    running: false,
    detail: '',
    ...over,
  }
}

/** 一份"什么都配好了"的接线输入。 */
function inputs(over: Partial<ConnectionReadInputs> = {}): ConnectionReadInputs & { asked: string[] } {
  const asked: string[] = []
  return {
    asked,
    snapshot: {
      revision: 7,
      values: {
        relayUrl: 'wss://relay.example.com/ws/connector',
        allowInsecurePublic: false,
        allowInsecureLocal: false,
        listenPort: 8790,
        relayTokenRef: 'relay-connector',
      },
    },
    channels: [
      channel({ id: 'relay', running: true, connected: true }),
      channel({ id: 'direct', running: true }),
    ],
    tokenStatusOf: async (ref) => {
      asked.push(ref)
      return { configured: true, writable: true }
    },
    configuredListenPort: () => 0,
    ...over,
  }
}

test('投影：白名单四格照快照，revision 一并带出（写入要拿它做乐观锁）', async () => {
  const state = await readConnectionState(inputs())
  assert.deepEqual(state, {
    revision: 7,
    relayUrl: 'wss://relay.example.com/ws/connector',
    allowInsecurePublic: false,
    allowInsecureLocal: false,
    listenPort: 8790,
    relayTokenRef: 'relay-connector',
    token: { configured: true, writable: true },
    relay: { running: true, connected: true },
    direct: { running: true },
  })
})

test('投影：令牌只回「设没设 + 能不能写」，没有能装值的槽（值永不过线）', async () => {
  const state = await readConnectionState(inputs())
  assert.deepEqual(Object.keys(state.token).sort(), ['configured', 'writable'])
})

test('投影：`relayTokenRef` 缺席时不问凭据面，直接回"没设"（不自造一个 ref 去读）', async () => {
  const asked: string[] = []
  const cases: Array<{ values: Record<string, unknown>; ref: string | undefined }> = [
    // 根本没有这一格
    { values: { relayUrl: 'ws://127.0.0.1:8787/ws/connector' }, ref: undefined },
    // 空串 = 未配置（`save()` 也把空串当未配置，见 connection-card.ts）
    { values: { relayUrl: 'ws://127.0.0.1:8787/ws/connector', relayTokenRef: '' }, ref: '' },
    // 类型不对的不是 ref：不认，也不猜成 `String(42)`
    { values: { relayUrl: 'ws://127.0.0.1:8787/ws/connector', relayTokenRef: 42 }, ref: undefined },
  ]
  for (const { values, ref } of cases) {
    const state = await readConnectionState(inputs({
      snapshot: { revision: 0, values },
      tokenStatusOf: async (askedRef) => {
        asked.push(askedRef)
        return { configured: true, writable: true }
      },
    }))
    assert.deepEqual(state.token, { configured: false, writable: false })
    assert.equal(state.relayTokenRef, ref)
  }
  assert.deepEqual(asked, [], '没有可用的 ref 就不该碰凭据面')
})

test('投影：没有 settings 服务时 revision 是 undefined（卡片据此说"此部署没有设置服务"）', async () => {
  const state = await readConnectionState(inputs({ snapshot: undefined }))
  assert.equal(state.revision, undefined)
  // 其余各格如实为空/兜底，不猜地址：
  assert.equal(state.relayUrl, undefined)
  assert.equal(state.allowInsecurePublic, false)
  assert.equal(state.listenPort, 0)
})

test('投影：快照里 `listenPort` 不是数字时用配置活读的那个值（不擅自回 0）', async () => {
  const state = await readConnectionState(inputs({
    snapshot: { revision: 0, values: { relayUrl: 'ws://127.0.0.1:8787/ws/connector', listenPort: '8790' } },
    configuredListenPort: () => 8790,
  }))
  assert.equal(state.listenPort, 8790)
})

test('投影：布尔格只认真 true（字符串 "false" 不能被当成打开）', async () => {
  const state = await readConnectionState(inputs({
    snapshot: {
      revision: 0,
      values: {
        relayUrl: 'ws://127.0.0.1:8787/ws/connector',
        allowInsecurePublic: 'false',
        allowInsecureLocal: 'true',
      },
    },
  }))
  assert.equal(state.allowInsecurePublic, false)
  assert.equal(state.allowInsecureLocal, false)
})

test('投影：注册表还没建（空列表）时如实报"未运行"，不是抛错也不是猜', async () => {
  const state = await readConnectionState(inputs({ channels: [] }))
  assert.deepEqual(state.relay, { running: false, connected: false })
  assert.deepEqual(state.direct, { running: false })
})

test('投影：通道按 id 找，不按位置（顺序变了不该读串）', async () => {
  const state = await readConnectionState(inputs({
    channels: [
      channel({ id: 'direct', running: true }),
      channel({ id: 'relay', running: true, connected: false }),
    ],
  }))
  assert.deepEqual(state.direct, { running: true })
  // `running` 与 `connected` 是两件事：跑着但控制面没通。
  assert.deepEqual(state.relay, { running: true, connected: false })
})

test('投影：只有 running、没有 connected 的通道（监听面）不会被当成"连上了"', async () => {
  const state = await readConnectionState(inputs({
    channels: [channel({ id: 'relay', running: true }), channel({ id: 'direct', running: true })],
  }))
  assert.equal(state.relay.connected, false)
})

/**
 * 装配层的接线：**四处在用、而且实参接对**。
 *
 * 只断言"名字出现过"是不够的 —— 下面这些接错全都过 `tsc`、也过其余全部用例，
 * 而症状是"手机连不上 / 面板读错"：
 *
 * ① `startRelay` 与 `startDirect` 对调（缺令牌时被当成直连失败 → 整体抛出 → 插件不挂）；
 * ② `listenPort` 写成常量 0（面板改端口不再生效，直连永远起不来）；
 * ③ 键集合事件里不再用 `paths`、或投影去读别的注册表/别的存（重建与面板显示跟真值脱钩）；
 * ④ 写/清令牌漏排重建（令牌不进 volatile 引用，不会有 `loader/volatile-update`）。
 *
 * 所以断言做在**实参**上，并且先**去注释 + 压空白**：普通重排、换行、缩进不会假阴，
 * 注释里提到同名符号也不会假阳（模式里是 `key: value` 与调用的实参形状）。
 * 它仍是文本级（证明不了运行时行为），所以 `transport-*` 两组替身用例与真机验收照样要跑。
 */
test('装配层确实用的是抽出来的那几处，且实参接对（不是本地又留了一份副本）', () => {
  const code = codeOf(readFileSync(new URL('../src/index.ts', import.meta.url), 'utf8'))

  // 四处抽取物必须都在装配层被**调用**：抽出来不接上，回归网保护的就是死代码。
  for (const call of ['channelsToRebuild(', 'createRebuildQueue(', 'createTransportStarter(', 'readConnectionState(']) {
    assert.ok(code.includes(call), `index.ts 没有调用 ${call}`)
  }
  // 配置热改的入口仍是那条事件（接线断了的话，面板保存就不再生效）。
  assert.ok(code.includes("'loader/volatile-update'"), 'index.ts 不再订阅 loader/volatile-update')

  const pins: Array<[RegExp, string]> = [
    [/startRelay: startRelayChannel/, '起传输时"中转"那一格没接 startRelayChannel'],
    [/startDirect: startDirectChannel/, '起传输时"直连"那一格没接 startDirectChannel'],
    [/listenPort: \(\) => config\.listenPort\(\)/, '直连端口不是"用时读配置"（写成常量后热改不生效）'],
    [/for \(const channel of channelsToRebuild\(paths\)\) void rebuildQueue\.enqueue\(channel\)/, '配置热改没有把事件里的 paths 交给 channelsToRebuild'],
    [/channels: transportChannels\?\.channels\(\) \?\? \[\]/, '面板投影没读通道注册表'],
    [/tokenStatusOf: \(ref\) => relayTokenStatusOf\(ctx\.credentials, ref\)/, '面板的令牌状态没接凭据面'],
    [/await rebuildQueue\.settle\(\) return rebuildQueue\.failure\(\)/, '保存回执没有等重建落地并带回失败原因'],
  ]
  for (const [pattern, why] of pins) assert.match(code, pattern, why)

  // 写令牌与清令牌各要显式排一次中转重建（一共 2 处，少一处就是"换了令牌不重连"）。
  const explicitRebuilds = code.match(/await rebuildQueue\.enqueue\('relay'\)/g) ?? []
  assert.equal(explicitRebuilds.length, 2, '写令牌与清令牌各要排一次中转重建（现在不是 2 处）')
})
