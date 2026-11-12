/**
 * 「上报哪些地址」：藏掉虚拟网卡、追加不在枚举里的地址。
 *
 * 判据只有两条，但都必须钉住：
 *
 * 1. **藏掉的地址不再出现在 `endpoint.describe` 里** —— 否则界面上"藏了"
 *    而手机照旧收到它，看起来像开关坏了。
 * 2. **追加的地址分两档**：`ws://` 只收非公网（监听面不终结 TLS，明文只该留在局域网）；
 *    `wss://` 不限主机（TLS 由外部终结 —— 反代 / frp / `tailscale serve`），
 *    所以公网地址也进得来。手机侧手填用同一套判据
 *    （`app/lib/core/endpoint.dart` 的 `isPrivateOrLoopback`）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  AdvertiseError,
  advertiseMapOf,
  assertExtraAddress,
  createAdvertiseAdmin,
  type AdvertiseTablePort,
} from '../src/admin/advertise.js'
import { describeEndpoints } from '../src/endpoints.js'
import type { Listener } from '../src/transport/listener.js'

/** 一台装了 VMware 的机器：WiFi + 以太网 + 两条虚拟网卡。 */
const listener = {
  port: 8790,
  active: 0,
  urls: [
    { url: 'ws://192.168.1.4:8790', label: 'WLAN 2' },
    { url: 'ws://192.168.2.41:8790', label: '以太网' },
    { url: 'ws://192.168.235.1:8790', label: 'VMware Network Adapter VMnet8' },
    { url: 'ws://192.168.40.1:8790', label: 'VMware Network Adapter VMnet1' },
  ],
  close: async () => {},
} as unknown as Listener

const directUrls = (advertise: Map<string, 'hide' | 'extra'>): string[] =>
  describeEndpoints({
    relayUrl: 'ws://127.0.0.1:8787/ws/connector',
    lanHint: '192.168.1.4',
    listener,
    advertise,
  })
    .endpoints.filter((endpoint) => endpoint.kind === 'direct')
    .map((endpoint) => endpoint.url)

test('上报：默认只报主地址（默认路由那条），其余进候选/折叠区', () => {
  const urls = directUrls(new Map())
  assert.deepEqual(urls, ['ws://192.168.1.4:8790'], 'VMware 与第二张网卡默认不占手机端点列表')
})

test('上报：hide 掉主地址后不再出现（界面上藏了，手机就真的收不到）', () => {
  const urls = directUrls(
    new Map<string, 'hide' | 'extra'>([['ws://192.168.1.4:8790', 'hide']]),
  )
  assert.deepEqual(urls, [], '默认集合只有主地址；藏掉它就是没有直连地址')
})

test('上报：hide 掉折叠区的地址不影响主地址', () => {
  const urls = directUrls(
    new Map<string, 'hide' | 'extra'>([
      ['ws://192.168.235.1:8790', 'hide'],
      ['ws://192.168.40.1:8790', 'hide'],
    ]),
  )
  assert.deepEqual(urls, ['ws://192.168.1.4:8790'])
})

test('上报：extra 追加一条不在默认集合里的地址（Tailscale 这类）', () => {
  const urls = directUrls(new Map<string, 'hide' | 'extra'>([['ws://100.64.1.9:8790', 'extra']]))
  assert.deepEqual(urls, ['ws://192.168.1.4:8790', 'ws://100.64.1.9:8790'])
})

test('上报：把折叠区的地址点名 extra 后才会报', () => {
  const urls = directUrls(
    new Map<string, 'hide' | 'extra'>([['ws://192.168.2.41:8790', 'extra']]),
  )
  assert.deepEqual(urls, ['ws://192.168.1.4:8790', 'ws://192.168.2.41:8790'])
})

test('上报：extra 与已有地址重名时只留一条', () => {
  const urls = directUrls(
    new Map<string, 'hide' | 'extra'>([['ws://192.168.1.4:8790', 'extra']]),
  )
  assert.equal(urls.filter((url) => url === 'ws://192.168.1.4:8790').length, 1)
})

test('上报：extra 收 `wss://` 公网地址（frp / 反代穿透出去的那一条）', () => {
  const urls = directUrls(new Map<string, 'hide' | 'extra'>([['wss://dsh.example.com', 'extra']]))
  assert.deepEqual(urls, ['ws://192.168.1.4:8790', 'wss://dsh.example.com'])
})

test('校验：extra 分两档 —— ws:// 只收非公网，wss:// 不限', () => {
  // 局域网 / 回环 / CGNAT 的明文都收。
  for (const url of [
    'ws://192.168.1.4:8790',
    'ws://10.0.0.9:8790',
    'ws://127.0.0.1:8790',
    'ws://100.64.1.9:8790',
  ]) {
    assert.doesNotThrow(() => assertExtraAddress(url), `${url} 应该收`)
  }
  // wss：TLS 已由外部终结，公网与私网都能拨。
  for (const url of [
    'wss://dsh.example.com',
    'wss://dsh.example.com:8443',
    'wss://192.168.1.4:8790',
    'wss://100.64.1.9:8790',
  ]) {
    assert.doesNotThrow(() => assertExtraAddress(url), `${url} 应该收`)
  }
  // 公网明文仍然拒：那一档只能在手机上逐次确认，面板不替用户拍板。
  assert.throws(() => assertExtraAddress('ws://example.com:8790'), AdvertiseError)
  assert.throws(() => assertExtraAddress('ws://8.8.8.8:8790'), AdvertiseError)
  assert.throws(() => assertExtraAddress('http://192.168.1.4:8790'), AdvertiseError)
  // 带凭据 / 查询串的地址不是"一条地址"，是配置写错了。
  assert.throws(() => assertExtraAddress('ws://u:p@192.168.1.4:8790'), AdvertiseError)
  assert.throws(() => assertExtraAddress('wss://u:p@dsh.example.com'), AdvertiseError)
  assert.throws(() => assertExtraAddress('ws://192.168.1.4:8790/?a=1'), AdvertiseError)
})

/** 内存版表态表（与 `domainTable` 的三个成员同形状）。 */
function tableOf(initial: Record<string, 'hide' | 'extra'> = {}): AdvertiseTablePort {
  const rows = new Map<string, { kind: 'hide' | 'extra' }>(
    Object.entries(initial).map(([url, kind]) => [url, { kind }]),
  )
  return {
    get: (key) => rows.get(key),
    keys: () => rows.keys(),
    put: async (key, value) => {
      rows.set(key, value)
    },
    delete: async (key) => rows.delete(key),
  }
}

/** 默认集合：与 `defaultDirectUrls` 同口径（主地址只有 192.168.1.4）。 */
const DEFAULTS = new Set(['ws://192.168.1.4:8790'])

test('管理面 view：报出默认集合与 extra、藏掉的、以及折叠的候选', () => {
  const admin = createAdvertiseAdmin({
    tableOf: () => tableOf({ 'ws://192.168.235.1:8790': 'hide', 'ws://100.64.1.9:8790': 'extra' }),
    candidatesOf: () => listener.urls,
    defaultUrlsOf: () => DEFAULTS,
  })
  const view = admin.view()
  assert.equal(view.candidates.length, 4, '候选是网卡枚举的原始结果（含被藏掉的）')
  assert.deepEqual(view.hidden, ['ws://192.168.235.1:8790'])
  assert.equal(view.advertised.length, 2, '默认主地址 + 1 条追加')
  assert.ok(
    view.advertised.some((entry) => entry.url === 'ws://100.64.1.9:8790' && entry.source === 'extra'),
    '追加的要标出来源',
  )
  assert.ok(
    view.advertised.every((entry) => entry.url !== 'ws://192.168.235.1:8790'),
    '藏掉的不能在"会上报"里',
  )
  assert.deepEqual(
    view.folded.map((entry) => entry.url).sort(),
    ['ws://192.168.2.41:8790', 'ws://192.168.40.1:8790'],
    '既不是默认、也没被点名 extra/hide 的地址进折叠区',
  )
})

test('管理面 set：clear 回到默认（主地址报、追加的不报）', async () => {
  const table = tableOf({ 'ws://100.64.1.9:8790': 'extra' })
  const admin = createAdvertiseAdmin({
    tableOf: () => table,
    candidatesOf: () => listener.urls,
    defaultUrlsOf: () => DEFAULTS,
  })
  assert.equal(admin.view().advertised.length, 2)
  await admin.set('ws://100.64.1.9:8790', 'clear')
  assert.equal(admin.view().advertised.length, 1)
})

test('管理面 set：extra 先校验，非法地址不落表', async () => {
  const table = tableOf()
  const admin = createAdvertiseAdmin({
    tableOf: () => table,
    candidatesOf: () => listener.urls,
    defaultUrlsOf: () => DEFAULTS,
  })
  await assert.rejects(() => admin.set('ws://example.com:8790', 'extra'), AdvertiseError)
  assert.equal(advertiseMapOf(table).size, 0, '被拒的地址不许留在表里')
})

test('advertiseMapOf：空表 / 缺行都当没有表态', () => {
  assert.equal(advertiseMapOf(null).size, 0)
  assert.equal(advertiseMapOf(tableOf()).size, 0)
})
