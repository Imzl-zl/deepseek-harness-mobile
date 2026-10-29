/**
 * 连接器令牌读取的回归（契约 §12.2）。
 *
 * 三条失败路径各配一条用例：它们都会让"连不上中转"，而只有**大声失败**才能让人
 * 一眼看出是"令牌没配/配错"而不是"网络问题"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { credentialKey, type CredentialKey, type CredentialRecord } from '@deepseek-ai/dsh-credentials'

import {
  RelayTokenError,
  clearRelayToken,
  relayTokenKey,
  relayTokenStatusOf,
  readRelayToken,
  writeRelayToken,
} from '../src/dsh/relay-token.js'

const KEY = credentialKey('dsh-mobile-connector', 'relay-token')

/** 假的凭据面：记下**实际传入的键**（`CredentialKey` 是品牌类型，只能整体比对）。 */
const source = (record: CredentialRecord | undefined) => {
  const seen: CredentialKey[] = []
  return {
    seen,
    readRecord: (key: CredentialKey) => {
      seen.push(key)
      return Promise.resolve(record)
    },
  }
}

test('读得到：返回令牌本体（不缓存，每次现读），且读的是那个具名记录', async () => {
  const s = source({ kind: 'grant', payload: { token: 'tok-1' } } as CredentialRecord)
  let reads = 0
  const credentials = {
    readRecord: () => {
      reads += 1
      return Promise.resolve({ kind: 'grant', payload: { token: 'tok-1' } } as CredentialRecord)
    },
  }
  assert.equal(await readRelayToken(credentials, 'relay-token'), 'tok-1')
  assert.equal(await readRelayToken(credentials, 'relay-token'), 'tok-1')
  assert.equal(reads, 2, '不缓存：操作者更新令牌后必须立刻生效')
})

test('记录不存在：抛（**不去编一个** —— 编出来的中转不认，症状是"连不上"）', async () => {
  await assert.rejects(
    () => readRelayToken(source(undefined), 'relay-token'),
    (error: unknown) => error instanceof RelayTokenError && /没有连接器令牌记录/.test(error.message),
  )
})

test('记录类型不对：抛（别人的记录不许静默当成"没配"）', async () => {
  await assert.rejects(
    () =>
      readRelayToken(
        source({ kind: 'oauth', payload: { token: 'tok' } } as unknown as CredentialRecord),
        'relay-token',
      ),
    (error: unknown) => error instanceof RelayTokenError && /不是本插件写的 grant 记录/.test(error.message),
  )
})

test('载荷里没有非空 token：抛（空串会退化成匿名连接，症状与"没配"一样却更难关联）', async () => {
  for (const payload of [{}, { token: '' }, { token: 42 }]) {
    await assert.rejects(
      () => readRelayToken(source({ kind: 'grant', payload } as CredentialRecord), 'relay-token'),
      (error: unknown) => error instanceof RelayTokenError && /没有非空的 token/.test(error.message),
    )
  }
})

// ---------------------------------------------------------------------------
// 写面（面板「连接」卡用）—— 记录面的唯一写路径是 `modifyRecord`，删除是 `deleteRecord`。
// ---------------------------------------------------------------------------

/** 假的记录面：只实现写/删/状态三个窄方法，并记下写了什么。 */
function store(initial?: CredentialRecord) {
  let current = initial
  const calls: string[] = []
  return {
    calls,
    get written() { return current },
    describeRecord: () => Promise.resolve({
      configured: current !== undefined,
      ...(current === undefined ? {} : { kind: current.kind }),
      writable: true,
    }),
    readRecord: () => Promise.resolve(current),
    modifyRecord: (
      _key: CredentialKey,
      mutate: (row: CredentialRecord | undefined) => Promise<CredentialRecord | undefined>,
    ) => {
      calls.push('modifyRecord')
      return mutate(current).then((next) => {
        current = next
        return next
      })
    },
    deleteRecord: () => {
      calls.push('deleteRecord')
      current = undefined
      return Promise.resolve()
    },
  }
}

test('写：走 modifyRecord，键是 <scope>/<id> 记录，值去掉首尾空白', async () => {
  const s = store()
  await writeRelayToken(s, 'relay-connector', '  tok-1  ')
  assert.deepEqual(s.calls, ['modifyRecord'])
  assert.deepEqual(s.written, { kind: 'grant', payload: { token: 'tok-1' } })
  assert.equal(String(relayTokenKey('relay-connector')), 'dsh-mobile-connector/relay-connector')
})

test('写：空串与含空白/控制字符的值一律拒（它要进 Authorization 头）', async () => {
  for (const bad of ['   ', 'a b', 'tok\r\nX-Injected: 1', 'tok\u0000']) {
    const s = store()
    await assert.rejects(() => writeRelayToken(s, 'relay-connector', bad), RelayTokenError)
    assert.deepEqual(s.calls, [], `「${JSON.stringify(bad)}」不该碰记录面`)
  }
})

test('删：走 deleteRecord（不是写一条空值 —— 空值表达不了"没有"）', async () => {
  const s = store({ kind: 'grant', payload: { token: 'tok-1' } } as CredentialRecord)
  await clearRelayToken(s, 'relay-connector')
  assert.deepEqual(s.calls, ['deleteRecord'])
  assert.equal(s.written, undefined)
})

test('状态：只回「设没设 + 能不能写」，**没有能装值的槽**', async () => {
  const present = await relayTokenStatusOf(store({ kind: 'grant', payload: { token: 'tok' } } as CredentialRecord), 'relay-connector')
  assert.deepEqual(present, { configured: true, writable: true })
  const absent = await relayTokenStatusOf(store(), 'relay-connector')
  assert.deepEqual(absent, { configured: false, writable: true })
})
