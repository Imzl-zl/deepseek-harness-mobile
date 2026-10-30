/**
 * 「连接」卡（`GET/POST /api/dsh-mobile/connection`）的逻辑回归。
 *
 * ## 为什么这一组必须逐条钉
 *
 * 这张卡是**操作者在浏览器里改连接配置的唯一入口**，而它踩在三件容易悄悄出错的事上：
 *
 * 1. **白名单**：`describe()` 会把该条目 11 个 volatile 字段全给出来（隔离实例实测），卡片只碰其中 3 格。
 *    卡片只该碰 `relayUrl` / `allowInsecurePublic` / `listenPort` 三格 —— 写错的后果是
 *    "顺手把一个没人会用的窗口上界也改了"，而界面上根本看不出来。
 * 2. **地址校验**：schema **不管**这件事（实测 `http://example.com/not-a-relay` 能被
 *    `settings.update` 成功写进 patch）。校验必须与 `validate-config` 同一处判据
 *    （`relayUrlOf`），且校验的是**这次保存之后的完整状态**：勾选与地址同一次提交时，
 *    不能按字段出现顺序判。
 * 3. **一次写入**：三格改动用一次 `settings.update`。三次 `mutate` 会让 revision
 *    每次都 +1，第二次拿旧 revision 必 409（`packages/settings/settings/src/index.ts:315-317`）。
 *
 * 令牌那一半另有三态（留空/填写/显式删除）与"配置已生效、令牌没写进去"的半成功语义，
 * 它们都在 `src/admin/connection-card.ts` 里判。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  CONNECTION_FIELDS,
  createConnectionCard,
  type ConnectionPorts,
  type ConnectionState,
} from '../src/admin/connection-card.js'
import { clearRelayToken, writeRelayToken } from '../src/dsh/relay-token.js'
import type { CredentialKey, CredentialRecord } from '@deepseek-ai/dsh-credentials'

/** 一份"正常"的电脑侧真值（WSS、直连开着、令牌已设置）。 */
function state(over: Partial<ConnectionState> = {}): ConnectionState {
  return {
    revision: 0,
    relayUrl: 'wss://relay.example.com/ws/connector',
    allowInsecurePublic: false,
    allowInsecureLocal: false,
    listenPort: 8790,
    relayTokenRef: 'relay-connector',
    token: { configured: true, writable: true },
    relay: { running: true, connected: true },
    direct: { running: true },
    ...over,
  }
}

/**
 * 记录面替身：只实现 `relay-token.ts` 用到的三个窄方法。
 *
 * **只记录"写了什么"，不回传值** —— 与真 seam 的类型约束同一个方向
 * （`CredentialInfo` 没有能装值的槽）。
 */
function store(
  calls: { writeToken: Array<[string, string]>; clearToken: string[] },
  options: { tokenError?: Error },
  onCommitted: () => void,
) {
  return {
    describeRecord: async () => ({ configured: true, writable: true }),
    readRecord: async () => undefined,
    modifyRecord: async (
      key: CredentialKey,
      mutate: (current: CredentialRecord | undefined) => Promise<CredentialRecord | undefined>,
    ) => {
      const next = await mutate(undefined)
      // `CredentialRecord` 是联合类型（api-key 那条没有 payload），按我们用到的形状收窄。
      const payload = (next as { payload?: { token?: string } } | undefined)?.payload
      calls.writeToken.push([String(key), payload?.token ?? ''])
      if (options.tokenError !== undefined) throw options.tokenError
      onCommitted()
      return next
    },
    deleteRecord: async (key: CredentialKey) => {
      calls.clearToken.push(String(key))
      onCommitted()
    },
  }
}

/** 端口替身：记录调用，并按需模拟冲突 / 令牌写失败。 */
function harness(options: {
  over?: Partial<ConnectionState>
  conflict?: boolean
  tokenError?: Error
} = {}) {
  const calls = {
    writeFields: [] as Array<{ patch: Record<string, unknown>; revision: number | undefined }>,
    writeToken: [] as Array<[string, string]>,
    clearToken: [] as string[],
    settle: 0,
  }
  let current = state(options.over)
  const ports: ConnectionPorts = {
    read: async () => current,
    writeFields: async (patch, revision) => {
      calls.writeFields.push({ patch: { ...patch }, revision })
      if (options.conflict === true) {
        const error = new Error('settings namespace changed') as Error & { code: string }
        error.code = 'SETTINGS_CONFLICT'
        // 冲突的含义正是"别处已经改成新 revision 了"，所以读面要跟着变。
        current = { ...current, revision: (current.revision ?? 0) + 7 }
        throw error
      }
      current = { ...current, revision: (current.revision ?? 0) + 1 }
    },
    // 令牌两格**走真的记录面模块**（`dsh/relay-token.ts`）：形状校验在那儿，
    // 用替身重写一遍就会变成"测试替身的规则"而不是产品的规则。
    writeToken: (ref, token) => writeRelayToken(store(calls, options, () => {
      current = { ...current, token: { configured: true, writable: true } }
    }), ref, token),
    clearToken: (ref) => clearRelayToken(store(calls, options, () => {
      current = { ...current, token: { configured: false, writable: true } }
    }), ref),
    settle: async () => {
      calls.settle += 1
      return undefined
    },
  }
  return { ports, calls, card: createConnectionCard(ports), get: () => current }
}

test('GET：只回白名单四字段；公网/内网按主机判，未配置中转时不报"内网"', async () => {
  const { card } = harness()
  const view = await card.read()
  assert.deepEqual(Object.keys(view.value).sort(), ['allowInsecurePublic', 'listenPort', 'relayTokenRef', 'relayUrl'])
  assert.equal(view.capable, true)
  assert.equal(view.relay.public, true, '域名按公网算（宁可严一格，与 relayUrlOf 同一判据）')

  const loopback = harness({ over: { relayUrl: 'ws://127.0.0.1:8787/ws/connector', allowInsecureLocal: true } })
  assert.equal((await loopback.card.read()).relay.public, false, '回环是内网')

  const none = harness({ over: { relayUrl: undefined } })
  assert.equal((await none.card.read()).relay.public, false, '没配中转时不给"内网"这个假答案')
})

test('GET：设置服务缺席（revision 拿不到）时 capable=false，且值面仍是四格', async () => {
  const { card } = harness({ over: { revision: undefined } })
  const view = await card.read()
  assert.equal(view.capable, false)
  assert.deepEqual(Object.keys(view.value).sort(), ['allowInsecurePublic', 'listenPort', 'relayTokenRef', 'relayUrl'])
})

test('保存：只发真的变了的键，一次写入，回执带新 revision', async () => {
  const { card, calls } = harness()
  const result = await card.save({ revision: 0, relayUrl: 'wss://relay2.example.com/ws/connector', allowInsecurePublic: false, listenPort: 8790 })
  assert.equal(result.status, 200)
  assert.deepEqual(calls.writeFields.length, 1, '三格只该写一次')
  assert.deepEqual(calls.writeFields[0]?.patch, { relayUrl: 'wss://relay2.example.com/ws/connector' },
    '没变的 allowInsecurePublic / listenPort 不该进 patch（不把默认值钉进配置文件）')
  assert.equal(calls.writeFields[0]?.revision, 0)
  if (result.status !== 200) return
  assert.deepEqual(result.body.applied, ['relayUrl'])
  assert.equal(result.body.tokenApplied, 'none')
  assert.equal(result.body.view.revision, 1)
  assert.deepEqual(calls.writeToken, [], '令牌留空 = 不改')
})

test('保存：什么都没改就不写、不动 revision（保存键不该把配置搅一遍）', async () => {
  const { card, calls } = harness()
  const result = await card.save({ revision: 0, relayUrl: 'wss://relay.example.com/ws/connector', listenPort: 8790 })
  assert.equal(result.status, 200)
  assert.deepEqual(calls.writeFields, [])
  if (result.status !== 200) return
  assert.deepEqual(result.body.applied, [])
  assert.equal(result.body.view.revision, 0)
})

test('地址校验：明文公网地址 + 未勾选 ⇒ 400，且**什么都没写**', async () => {
  const { card, calls } = harness()
  const result = await card.save({ revision: 0, relayUrl: 'ws://relay.example.com/ws/connector' })
  assert.equal(result.status, 400)
  if (result.status !== 400) return
  assert.equal(result.body.field, 'relayUrl')
  assert.match(result.body.error, /WSS/)
  assert.deepEqual(calls.writeFields, [], '校验不过不许落盘')
})

test('地址校验：勾选与地址同一次提交时按**结果状态**判（与字段顺序无关）', async () => {
  const { card, calls } = harness()
  const result = await card.save({ revision: 0, relayUrl: 'ws://relay.example.com/ws/connector', allowInsecurePublic: true })
  assert.equal(result.status, 200)
  assert.deepEqual(calls.writeFields[0]?.patch, { relayUrl: 'ws://relay.example.com/ws/connector', allowInsecurePublic: true })
})

test('地址校验：解析不了、带查询串、空串各报各的（且都不落盘）', async () => {
  for (const bad of ['not a url', 'wss://relay.example.com/ws?token=x', '   ']) {
    const { card, calls } = harness()
    const result = await card.save({ revision: 0, relayUrl: bad })
    assert.equal(result.status, 400, `「${bad}」应被拒`)
    assert.deepEqual(calls.writeFields, [])
  }
})

test('端口：越界 / 非整数 / 非数字 ⇒ 400，且不落盘', async () => {
  for (const bad of [65_536, -1, 1.5, '8790']) {
    const { card, calls } = harness()
    const result = await card.save({ revision: 0, listenPort: bad })
    assert.equal(result.status, 400, `「${String(bad)}」应被拒`)
    if (result.status !== 400) continue
    assert.equal(result.body.field, 'listenPort')
    assert.deepEqual(calls.writeFields, [])
  }
})

test('端口 0：等于「停用直连」，是一次正常的显式变更', async () => {
  const { card, calls } = harness()
  const result = await card.save({ revision: 0, listenPort: 0 })
  assert.equal(result.status, 200)
  assert.deepEqual(calls.writeFields[0]?.patch, { listenPort: 0 })
  if (result.status !== 200) return
  assert.deepEqual(result.body.applied, ['listenPort'])
})

test('revision 过期：409 + 冲突标记 + 最新真值（面板据此回填，而不是猜）', async () => {
  const { card } = harness({ conflict: true })
  const result = await card.save({ revision: 3, relayUrl: 'wss://relay2.example.com/ws/connector' })
  assert.equal(result.status, 409)
  if (result.status !== 409) return
  assert.equal(result.body.conflict, true)
  assert.equal(result.body.view.revision, 7, '回执要带**实际** revision')
})

test('令牌：填写 ⇒ 记录面写 grant；显式清除 ⇒ 删除记录', async () => {
  const set = harness()
  const written = await set.card.save({ revision: 0, token: { op: 'set', value: '  tok-123  ' } })
  assert.equal(written.status, 200)
  // 键是**记录** `<scope>/<id>`，`relayTokenRef` 只是 id 那一半；值写之前去掉首尾空白。
  assert.deepEqual(set.calls.writeToken, [['dsh-mobile-connector/relay-connector', 'tok-123']])

  const clear = harness()
  const cleared = await clear.card.save({ revision: 0, token: { op: 'clear' } })
  assert.equal(cleared.status, 200)
  assert.deepEqual(clear.calls.clearToken, ['dsh-mobile-connector/relay-connector'])
  assert.deepEqual(clear.calls.writeToken, [])
  if (cleared.status !== 200) return
  assert.equal(cleared.body.tokenApplied, 'clear')
})

test('令牌：空白值不许当"清除"用（那是两种意图）；非法字符被拒', async () => {
  for (const bad of ['   ', 'a b', 'tok\r\nInjected: 1']) {
    const { card, calls } = harness()
    const result = await card.save({ revision: 0, token: { op: 'set', value: bad } })
    assert.equal(result.status, 400)
    assert.deepEqual(calls.writeToken, [])
  }
})

test('半成功：配置已写、令牌写失败 ⇒ 400 field=token 且 configApplied=true', async () => {
  const { card, calls } = harness({ tokenError: new Error('凭据存储只读') })
  const result = await card.save({
    revision: 0,
    relayUrl: 'wss://relay2.example.com/ws/connector',
    token: { op: 'set', value: 'tok-123' },
  })
  assert.equal(result.status, 400)
  if (result.status !== 400) return
  assert.equal(result.body.field, 'token')
  assert.equal(result.body.configApplied, true, '配置那一半确实生效了，界面要能分开说')
  assert.equal(calls.writeFields.length, 1)
})

test('设置服务缺席：保存直接 400（不是静默成功）', async () => {
  const { card, calls } = harness({ over: { revision: undefined } })
  const result = await card.save({ revision: undefined, relayUrl: 'wss://x.example/ws' })
  assert.equal(result.status, 400)
  if (result.status !== 400) return
  assert.equal(result.body.field, 'body')
  assert.deepEqual(calls.writeFields, [])
})

test('冲突的实测形状：SETTINGS_CONFLICT 走 code 认，不按 message 认', async () => {
  const { card } = harness({
    over: { revision: 2 },
    conflict: true,
  })
  const result = await card.save({ revision: 2, listenPort: 9000 })
  assert.equal(result.status, 409)
})

test('字段白名单与 schema 对齐：三格且只有三格', () => {
  assert.deepEqual([...CONNECTION_FIELDS], ['relayUrl', 'allowInsecurePublic', 'listenPort'])
})
