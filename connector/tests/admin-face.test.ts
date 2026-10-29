/**
 * 管理面（`/dsh-mobile/*` RPC）的回归。
 *
 * ## 为什么这一组值得单独钉
 *
 * 它是**操作者在浏览器里的唯一出口**：看桥接状态、出配对码、按方式停启传输、
 * 停用/启用设备、删除设备。出错的样子都很安静——路由没挂上时面板空白、端点回错 JSON，
 * 而"二维码出不来"在真机上表现为"手机扫不到东西"，中间隔着一整台电脑。
 *
 * 所以这里逐条钉：
 * 1. 各端点的路径、方法、形状；
 * 2. **出码是 POST**（GET 会被预取白烧一次性 offer）；
 * 3. **传输面按通道分**：`GET /transport` 列通道、`POST /transport/{id}/{start,stop}`
 *    各停各的，且**路由按 `deps.channels()` 生成** —— 加第三种方式不改管理面形状；
 * 4. **停用/启用是一对布尔端点**（照 DSH `setBundleEnabled`），未知设备 id 不当成功；
 * 5. **删除只有 `devIds` 多选与 `scope: revoked|all` 两种 body**，
 *    `offline` scope 与 `allOffline` 批量吊销**不许回来**（2026-10-15 事故）；
 * 6. 二维码的载荷与 `pairing-qr.ts` 的**解码器真 round-trip**——
 *    期望值不是手编常量，是"编出来再解回去等于原载荷"。
 *
 * 不变量本身（解禁要把 `revokedAt` 从行上拿掉、在线的绝不删）在
 * `device-admin.test.ts` 里用真设备表钉，这里只钉路由的形状与拒绝。
 */
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

import { createAdminRoutes } from '../src/admin/routes.js'
import type { AdminDeviceRow, AdminDeps } from '../src/admin/routes.js'
import { pairingQrSvg } from '../src/pairing-qr.js'
import { issuePairingOffer, offerForScanning } from '../src/pairing-offer.js'
import type { Pairing } from '../src/pairing.js'

/**
 * jsqr 是 CJS（`module.exports = jsQR`），而本仓 tsconfig 是
 * `NodeNext + verbatimModuleSyntax` —— 那个组合下 `import jsQR from 'jsqr'`
 * 会被推成**模块命名空间**而不是可调用函数（tsc 报 TS2349，运行时反而对）。
 * 用 `createRequire` 取真正的函数，并在这里显式声明只用到的形状。
 */
const require = createRequire(import.meta.url)
type JsQr = (data: Uint8ClampedArray, width: number, height: number) => { data: string } | null
const jsQR = require('jsqr') as JsQr

const CAPS = {
  sessions: true,
  storage: true,
  approval: true,
  questions: true,
  jobs: true,
  subagents: false,
  references: false,
  plugins: false,
  files: false,
  changes: false,
  settings: true,
  credentials: true,
  direct: true,
}

/** 三行设备：一台在线前台、一台离线未吊销、一台已吊销。 */
const DEVICES: AdminDeviceRow[] = [
  { id: 'dev-live', name: '我的手机', pairedAt: 1760000000000, revoked: false, online: true, foreground: true, lastInteractedAt: 1760000600000 },
  { id: 'dev-idle', name: '平板', pairedAt: 1750000000000, revoked: false, online: false, foreground: false },
  { id: 'dev-gone', name: '旧手机', pairedAt: 1740000000000, revoked: true, online: false, foreground: false },
]

/** 两条传输通道（2026-10-17 起按"方式"分开关）。 */
const CHANNELS = [
  { id: 'relay', label: '中转拨号', running: true, detail: 'ws://127.0.0.1:8787/ws/connector' },
  { id: 'direct', label: '直连监听', running: true, detail: '0.0.0.0:8790' },
]

/** 「连接」卡的读形状（真值由 `admin/connection-card.ts` 算，这里只做路由层替身）。 */
const CONNECTION_VIEW = {
  capable: true,
  revision: 0,
  value: {
    relayUrl: 'ws://127.0.0.1:8787/ws/connector',
    allowInsecurePublic: true,
    listenPort: 8790,
    relayTokenRef: 'relay-connector',
  },
  token: { configured: true, writable: true },
  relay: { running: true, connected: true, public: false },
  direct: { running: true },
}

function deps(over: Partial<AdminDeps> = {}): AdminDeps {
  return {
    caps: () => CAPS,
    metrics: () => ({ pairedDevices: 2, failClosed: 0 }),
    devices: () => DEVICES,
    relayUrl: () => 'ws://127.0.0.1:8787/ws/connector',
    channels: () => CHANNELS,
    setChannel: async () => {},
    advertise: {
      view: () => ({ advertised: [], hidden: [], candidates: [] }),
      set: async () => {},
    },
    offer: async () => ({ svg: 'P', expiresAt: 123 }),
    setEnabled: async () => {},
    remove: async () => ({ removed: 0, skippedOnline: 0 }),
    removeScope: async () => ({ removed: 0, skippedOnline: 0 }),
    connection: {
      read: async () => CONNECTION_VIEW,
      save: async () => ({
        status: 200,
        body: { ok: true, applied: [], tokenApplied: 'none', view: CONNECTION_VIEW },
      }),
    },
    ...over,
  }
}

const routeOf = (routes: ReturnType<typeof createAdminRoutes>, path: string) => {
  const route = routes.find((r) => r.path === path)
  assert.ok(route !== undefined, `缺少路由 ${path}`)
  return route
}

/** 用 `body` 打某个端点，省掉每处都写一遍的 Request 样板。 */
const post = (routes: ReturnType<typeof createAdminRoutes>, path: string, body?: unknown): Promise<Response> =>
  routeOf(routes, path).fetch(
    new Request(`http://x${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: typeof body === 'string' ? body : JSON.stringify(body) }),
    }),
  )

/** `Response.json()` 在这边推成 `unknown`，逐处断言太吵；这一层统一收一次。 */
async function jsonOf(res: Response): Promise<Record<string, unknown>> {
  const body: unknown = await res.json()
  assert.equal(typeof body, 'object')
  assert.notEqual(body, null)
  return body as Record<string, unknown>
}

test('端点：路径、方法、形状', async () => {
  const routes = createAdminRoutes(deps())
  assert.deepEqual(
    routes.map((r) => `${r.path} ${r.methods.join(',')}`).sort(),
    [
      // **一条路由两个方法**：DSH 的 `registerFetchRoute` 按路径注册，
      // 同 path 写两条会在挂载期抛 "already registered"（0.2.1 起校验，
      // 0.2.0 不校验 —— 所以这条断言在升级前是绿的）。
      '/api/dsh-mobile/advertise GET,POST',
      '/api/dsh-mobile/connection GET,POST',
      '/api/dsh-mobile/devices/enabled POST',
      '/api/dsh-mobile/devices/remove POST',
      '/api/dsh-mobile/pair POST',
      '/api/dsh-mobile/status GET',
      '/api/dsh-mobile/transport GET',
      '/api/dsh-mobile/transport/direct/start POST',
      '/api/dsh-mobile/transport/direct/stop POST',
      '/api/dsh-mobile/transport/relay/start POST',
      '/api/dsh-mobile/transport/relay/stop POST',
    ],
  )

  const status = await routeOf(routes, '/api/dsh-mobile/status').fetch(
    new Request('http://x/api/dsh-mobile/status'),
  )
  const body = await jsonOf(status)
  assert.equal(status.status, 200)
  assert.deepEqual(body['caps'], CAPS)
  assert.deepEqual(body['metrics'], { pairedDevices: 2, failClosed: 0 })
  assert.equal(body['relayUrl'], 'ws://127.0.0.1:8787/ws/connector',
    '状态要说明拨向哪条路 —— 排查"连不上"时第一件事是看这个')
  // 传输面的总布尔已走：按方式分开关后，"整条传输在不在跑"没有单一答案，
  // 真相在 `GET /transport` 的通道列表里。留着它就是第二套会漂移的真相。
  assert.equal(body['transportRunning'], undefined, 'status 不再回传输总布尔')
  // 设备行原样给（含已吊销的那台——页面要能显示"这台已被移除"）。
  const rows = body['devices'] as Array<Record<string, unknown>>
  assert.equal(rows.length, 3)
  assert.equal(rows[2]?.['revoked'], true)
  // 在线态来自 presence，**不是**名册字段。
  assert.equal(rows[0]?.['online'], true)
  assert.equal(rows[0]?.['foreground'], true)
  assert.equal(rows[0]?.['lastInteractedAt'], 1760000600000)
  assert.equal(rows[1]?.['online'], false)
})

test('传输面：GET /transport 列通道（按"方式"分开关的唯一数据源）', async () => {
  const routes = createAdminRoutes(deps())
  const res = await routeOf(routes, '/api/dsh-mobile/transport').fetch(
    new Request('http://x/api/dsh-mobile/transport'),
  )
  assert.equal(res.status, 200)
  assert.deepEqual(await jsonOf(res), { channels: CHANNELS })
})

test('传输面：每条通道各自起停，回执带当时的通道真值', async () => {
  const seen: Array<[string, boolean]> = []
  let running = true
  const routes = createAdminRoutes(deps({
    setChannel: async (id, on) => { seen.push([id, on]); running = on },
    channels: () => CHANNELS.map((channel) => ({ ...channel, running })),
  }))

  for (const [id, on] of [['direct', false], ['relay', false], ['relay', true]] as const) {
    const res = await post(routes, `/api/dsh-mobile/transport/${id}/${on ? 'start' : 'stop'}`)
    assert.equal(res.status, 200)
    const body = await jsonOf(res)
    assert.equal(body['ok'], true)
    const channels = body['channels'] as Array<{ running: boolean }>
    assert.equal(channels[0]?.running, on, '回执带电脑侧真值，不按本地点击乐观翻转')
  }
  // **两个方式两个开关**：停 direct 不碰 relay，起 relay 不碰 direct。
  assert.deepEqual(seen, [['direct', false], ['relay', false], ['relay', true]])
})

test('传输面：起停端点一律 POST（GET 会被预取/刷新触发，那会莫名断链）', () => {
  const routes = createAdminRoutes(deps())
  for (const id of ['relay', 'direct']) {
    for (const action of ['start', 'stop']) {
      const route = routeOf(routes, `/api/dsh-mobile/transport/${id}/${action}`)
      assert.ok(!route.methods.includes('GET'), `${id}/${action} 不许 GET`)
    }
  }
})

test('传输面：启动失败带原因回界面（端口被占），不当成功', async () => {
  const routes = createAdminRoutes(deps({
    setChannel: async () => { throw new Error('listen EADDRINUSE: address already in use 8790') },
  }))
  const res = await post(routes, '/api/dsh-mobile/transport/direct/start')
  // 400 而不是 500：面板只显示 `body.error`，500 只会剩下一个没有原因的 HTTP 号。
  assert.equal(res.status, 400)
  const body = await jsonOf(res)
  assert.equal(body['ok'], false)
  assert.match(String(body['error']), /EADDRINUSE/, '原话要带回去，不许吞成"操作失败"')
})

test('上报地址：GET 回视图，POST 设表态（kind 是封闭三态）', async () => {
  const calls: [string, string][] = []
  const routes = createAdminRoutes(
    deps({
      advertise: {
        view: () => ({
          advertised: [{ url: 'ws://192.168.1.4:8790', source: 'auto' as const }],
          hidden: [],
          candidates: [{ url: 'ws://192.168.1.4:8790', label: 'WLAN 2' }],
        }),
        set: async (url, kind) => {
          calls.push([url, kind])
        },
      },
    }),
  )

  // 这个路径有 GET 与 POST 两条：`routeOf` 只按路径取第一条，所以 POST 要
  // **按方法挑**自己那条（真实服务器是按方法分派的，这里只是替身的局限）。
  const postAdvertise = (body: unknown): Promise<Response> =>
    routes
      .find((r) => r.path === '/api/dsh-mobile/advertise' && r.methods.includes('POST'))!
      .fetch(
        new Request('http://x/api/dsh-mobile/advertise', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(body),
        }),
      )

  const view = await jsonOf(
    await routeOf(routes, '/api/dsh-mobile/advertise').fetch(
      new Request('http://x/api/dsh-mobile/advertise'),
    ),
  )
  assert.equal((view['advertised'] as unknown[]).length, 1)
  assert.equal((view['candidates'] as unknown[]).length, 1)

  const ok = await postAdvertise({ url: 'ws://192.168.235.1:8790', kind: 'hide' })
  assert.equal(ok.status, 200)
  assert.deepEqual(calls, [['ws://192.168.235.1:8790', 'hide']])

  // 三态封闭：乱写的 kind 不许落到实现里（否则"藏掉"会静默变成别的意思）。
  for (const kind of ['remove', 'HIDE', '', 42]) {
    const bad = await postAdvertise({ url: 'ws://192.168.235.1:8790', kind })
    assert.equal(bad.status, 400, `kind=${String(kind)} 必须 400`)
  }
  assert.equal(calls.length, 1, '被拒的请求不许调 set')

  // url 必填。
  const noUrl = await postAdvertise({ kind: 'hide' })
  assert.equal(noUrl.status, 400)
})

test('上报地址：set 抛错（如 extra 校验不过）归一成 400 并带回原话', async () => {
  const routes = createAdminRoutes(
    deps({
      advertise: {
        view: () => ({ advertised: [], hidden: [], candidates: [] }),
        set: async () => {
          throw new Error('直连地址必须是局域网 / 回环 / CGNAT 地址（公网请走中转）')
        },
      },
    }),
  )
  const res = await routes
    .find((r) => r.path === '/api/dsh-mobile/advertise' && r.methods.includes('POST'))!
    .fetch(
      new Request('http://x/api/dsh-mobile/advertise', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ url: 'ws://example.com:8790', kind: 'extra' }),
      }),
    )
  assert.equal(res.status, 400)
  assert.match(String((await jsonOf(res))['error']), /公网请走中转/, '原因不许吞掉')
})

test('传输面：路由按通道生成 —— 加第三种方式不改管理面形状', async () => {
  // 注册表多一个端口（Tailscale / 服务器中转），路由自动多一对，
  // 而 UI 按 `GET /transport` 枚举渲染 —— 这条是"形状不变"的机械断言。
  const three = [...CHANNELS, { id: 'tailscale', label: 'Tailscale', running: false, detail: '未配置' }]
  const paths = createAdminRoutes(deps({ channels: () => three })).map((route) => route.path)
  for (const id of ['relay', 'direct', 'tailscale']) {
    assert.ok(paths.includes(`/api/dsh-mobile/transport/${id}/start`), `${id} 的 start 路由应自动出现`)
    assert.ok(paths.includes(`/api/dsh-mobile/transport/${id}/stop`), `${id} 的 stop 路由应自动出现`)
  }
})

test('传输面：没有按 id 写死的路由表，旧的一把开关端点不许回来', () => {
  // 老形状 `/transport/start` 与 `/transport/stop`（一把同时起停拨号与监听）
  // 已删：用户明确要求"两个方式两个开关"，且加新方式时一把开关又要改形状。
  const paths = createAdminRoutes(deps()).map((route) => route.path)
  assert.equal(paths.includes('/api/dsh-mobile/transport/start'), false, '一把总启动不许回来')
  assert.equal(paths.includes('/api/dsh-mobile/transport/stop'), false, '一把总停止不许回来')
  // 没注册过的通道 id 没有路由（Connection 的 Fetch 路由是精确匹配）——
  // 打过去是 404，而不是一个"假装成功"的 200。
  assert.equal(
    paths.includes('/api/dsh-mobile/transport/nope/start'),
    false,
    '未知通道 id 不该有路由',
  )
})

test('出码端点：POST，回 svg 与过期时刻（不回 payload）', async () => {
  let offerCalls = 0
  const routes = createAdminRoutes(deps({ offer: async () => { offerCalls += 1; return { svg: '<svg/>', expiresAt: 999 } } }))
  const res = await routeOf(routes, '/api/dsh-mobile/pair').fetch(
    new Request('http://x/api/dsh-mobile/pair', { method: 'POST' }),
  )
  const body = await jsonOf(res)
  assert.deepEqual(body, { svg: '<svg/>', expiresAt: 999 })
  assert.equal(offerCalls, 1)
  // **payload 不过线**：它含两把公钥，而浏览器只负责画图（`routes.ts` 的 `offer` 注释）。
  // 这条同时是"别把 payload 加回响应"的看门狗。
  assert.doesNotMatch(JSON.stringify(body), /payload/)
})

test('停用/启用：一对布尔端点 —— enabled:false 停用、enabled:true 解禁，同一个 devId', async () => {
  const seen: Array<[string, boolean]> = []
  const routes = createAdminRoutes(deps({
    setEnabled: async (devId, enabled) => { seen.push([devId, enabled]) },
  }))
  for (const enabled of [false, true]) {
    const res = await post(routes, '/api/dsh-mobile/devices/enabled', { devId: 'dev-live', enabled })
    const body = await jsonOf(res)
    assert.equal(res.status, 200)
    assert.equal(body['ok'], true)
    assert.equal(body['enabled'], enabled)
    assert.equal((body['devices'] as unknown[]).length, 3)
  }
  // **一个名字、一个布尔**，不是"停用端点 + 解禁端点"两个动作 ——
  // 照 DSH `setBundleEnabled(name, enabled)`（`plugin-manager/src/index.ts:476`）。
  assert.deepEqual(seen, [['dev-live', false], ['dev-live', true]])
})

test('停用/启用：未知设备 id → 400 且不当成功（页面不许显示假的"已停用"）', async () => {
  let called = false
  const routes = createAdminRoutes(deps({ setEnabled: async () => { called = true } }))
  const res = await post(routes, '/api/dsh-mobile/devices/enabled', { devId: 'dev-nope', enabled: false })
  assert.equal(res.status, 400)
  const body = await jsonOf(res)
  assert.equal(body['ok'], false)
  assert.equal(body['error'], '未知设备：dev-nope')
  assert.equal(called, false, '不认识就不该调 setEnabled')
})

test('停用/启用：devId 缺失 / enabled 不是布尔 → 400，不碰 setEnabled', async () => {
  let called = false
  const routes = createAdminRoutes(deps({ setEnabled: async () => { called = true } }))
  for (const body of [
    {}, { devId: '' }, { devId: 7 },
    { devId: 'dev-live' }, { devId: 'dev-live', enabled: 'yes' }, { devId: 'dev-live', enabled: null },
  ]) {
    const res = await post(routes, '/api/dsh-mobile/devices/enabled', body)
    assert.equal(res.status, 400, `${JSON.stringify(body)} 应被拒`)
  }
  assert.equal(called, false)
})

test('停用/启用：失败必须带原因回给界面（照 DSH `停用失败：{reason}`）', async () => {
  const routes = createAdminRoutes(deps({
    setEnabled: async () => { throw new Error('名册上报失败：中转不应答') },
  }))
  const res = await post(routes, '/api/dsh-mobile/devices/enabled', { devId: 'dev-live', enabled: false })
  // 400 而不是 500：面板只显示 `body.error`，500 只会剩下一个没有原因的 HTTP 号。
  assert.equal(res.status, 400)
  const body = await jsonOf(res)
  assert.equal(body['ok'], false)
  assert.match(String(body['error']), /中转不应答/, '原话要带回去，不许吞成"操作失败"')
})

test('停用/启用：请求体不是 JSON → 400（不炸成 500）', async () => {
  const routes = createAdminRoutes(deps())
  const res = await post(routes, '/api/dsh-mobile/devices/enabled', 'not json')
  assert.equal(res.status, 400)
})

test('删除：多选 —— devIds 原样交给 remove，removed/skippedOnline 回给界面', async () => {
  const seen: string[][] = []
  const routes = createAdminRoutes(deps({
    remove: async (devIds) => { seen.push([...devIds]); return { removed: 2, skippedOnline: 1 } },
  }))
  const res = await post(routes, '/api/dsh-mobile/devices/remove', {
    devIds: ['dev-idle', 'dev-gone', 'dev-live'],
  })
  const body = await jsonOf(res)
  assert.equal(res.status, 200)
  assert.equal(body['ok'], true)
  assert.equal(body['removed'], 2)
  assert.equal(body['skippedOnline'], 1)
  assert.deepEqual(seen, [['dev-idle', 'dev-gone', 'dev-live']])
})

test('删除：单台就是长度 1 的多选，走同一条服务端路', async () => {
  const seen: string[][] = []
  const routes = createAdminRoutes(deps({
    remove: async (devIds) => { seen.push([...devIds]); return { removed: 1, skippedOnline: 0 } },
  }))
  const res = await post(routes, '/api/dsh-mobile/devices/remove', { devIds: ['dev-idle'] })
  const body = await jsonOf(res)
  assert.equal(res.status, 200)
  assert.equal(body['removed'], 1)
  assert.deepEqual(seen, [['dev-idle']])
})

test('删除：不认识的 id 不当成功（400，不能回 ok）', async () => {
  let called = false
  const routes = createAdminRoutes(deps({
    remove: async () => { called = true; return { removed: 0, skippedOnline: 0 } },
  }))
  const res = await post(routes, '/api/dsh-mobile/devices/remove', { devIds: ['dev-idle', 'dev-nope'] })
  // 400 而不是 404：本文件其余失败都走 `badRequest`，404 是异类。
  assert.equal(res.status, 400, '不认识的 id 要 400，不能回 ok')
  const body = await jsonOf(res)
  assert.equal(body['error'], '未知设备：dev-nope')
  assert.equal(called, false)
})

test('删除：devIds 空数组或含非字符串 → 400', async () => {
  let called = false
  const routes = createAdminRoutes(deps({
    remove: async () => { called = true; return { removed: 0, skippedOnline: 0 } },
  }))
  for (const body of [
    { devIds: [] }, { devIds: ['dev-idle', 7] }, { devIds: ['dev-idle', ''] }, { devIds: 'dev-idle' },
  ]) {
    const res = await post(routes, '/api/dsh-mobile/devices/remove', body)
    assert.equal(res.status, 400, `${JSON.stringify(body)} 应被拒`)
  }
  assert.equal(called, false)
})

test('删除：scope 只剩 revoked / all —— 跳过的在线台数要回给界面', async () => {
  const seen: string[] = []
  const routes = createAdminRoutes(deps({
    removeScope: async (scope) => { seen.push(scope); return { removed: 30, skippedOnline: 1 } },
  }))
  for (const scope of ['revoked', 'all']) {
    const res = await post(routes, '/api/dsh-mobile/devices/remove', { scope })
    const body = await jsonOf(res)
    assert.equal(res.status, 200)
    assert.equal(body['ok'], true)
    assert.equal(body['removed'], 30)
    // 跳过了在线的必须说出来：用户按"清空全部"却发现自己那台还在，会以为按钮坏了。
    assert.equal(body['skippedOnline'], 1)
  }
  assert.deepEqual(seen, ['revoked', 'all'])

  const bad = await post(routes, '/api/dsh-mobile/devices/remove', { scope: 'everything' })
  assert.equal(bad.status, 400, 'scope 是封闭集，别放过拼错的')
})

test('删除：按当前离线批量硬删不许回来（2026-10-15 事故就是它删掉用户自己那台）', async () => {
  let called = false
  const routes = createAdminRoutes(deps({
    remove: async () => { called = true; return { removed: 0, skippedOnline: 0 } },
    removeScope: async () => { called = true; return { removed: 0, skippedOnline: 0 } },
    setEnabled: async () => { called = true },
  }))
  // 老形状 `{scope:'offline'}` 与 `{allOffline:true}` 都必须被拒，且一个 dep 都不碰。
  // 那个 scope 的人口专门命中"暂时离线但还在用"的设备 —— 事故里用户的手机
  // 正在排查重连、处于离线态，服务端"跳过在线"保护不了它。
  for (const [path, body] of [
    ['/api/dsh-mobile/devices/remove', { scope: 'offline' }],
    ['/api/dsh-mobile/devices/remove', { allOffline: true }],
    ['/api/dsh-mobile/devices/enabled', { allOffline: true }],
  ] as const) {
    const res = await post(routes, path, body)
    assert.equal(res.status, 400, `${path} ${JSON.stringify(body)} 必须被拒`)
  }
  assert.equal(called, false)
})

test('删除：devIds 与 scope 都缺 → 400，不碰 remove', async () => {
  let called = false
  const routes = createAdminRoutes(deps({
    remove: async () => { called = true; return { removed: 0, skippedOnline: 0 } },
    removeScope: async () => { called = true; return { removed: 0, skippedOnline: 0 } },
  }))
  const res = await post(routes, '/api/dsh-mobile/devices/remove', {})
  assert.equal(res.status, 400)
  assert.equal(called, false)
})

test('装配顺序：管理面挂在通道注册表创建之后（2026-10-17 真机抓到的 404）', () => {
  // 按通道生成的起停路由是**挂载时一次性生成**的（`createAdminRoutes` 调
  // `deps.channels()` 那一次）。`mountAdminFace` 若早于 `createTransportChannels`，
  // 那时的 `channels()` 还是空数组 —— 4 个 POST 路由根本不注册，而
  // GET /transport 是基础路由、面板看起来一切正常，点"停止"才 404。
  // 真机实测到这条，所以用源码顺序断言钉住（装配接错不报错，是本项目
  // 反复出现的一类故障，Dart 侧同形状的守卫在 `assembly_invariants_test.dart`）。
  const source = readFileSync(new URL('../src/index.ts', import.meta.url), 'utf8')
  const registry = source.indexOf('transportChannels = createTransportChannels')
  const mount = source.indexOf('mountAdminFace(ctx')
  assert.ok(registry > 0, 'index.ts 应创建通道注册表')
  assert.ok(mount > 0, 'index.ts 应挂管理面')
  assert.ok(
    registry < mount,
    '注册表必须先于管理面挂载 —— 否则按通道的起停路由生成时通道列表是空的',
  )
})

test('没有独立网页这一路：管理面的 UI 在插件面板里，不另起路由', () => {
  // 2026-10-15 删掉过一版 `ctx.webServer.register({kind:'prefix'})` 的内联 HTML。
  // 删的理由：与插件面板功能完全重复，且它并不额外起进程（同在 DSH 的 web server 上），
  // 留着就是两套 UI 两个维护点。这条钉住"别再长回来"。
  //
  // **先剥注释再扫**：mount.ts 的文件头有大段解释"为什么删掉 webServer"的注释，
  // 直接按文本扫会把注释里的词当成代码（`tools.md` 里那个坑的同一形状）。
  const raw = readFileSync(new URL('../src/admin/mount.ts', import.meta.url), 'utf8')
  const code = raw.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ')
  assert.doesNotMatch(code, /webServer/, 'mount 不该再注册页面路由')
  assert.doesNotMatch(code, /adminPageHtml/, '不该再生成 HTML')
  // 但 RPC 端点必须在 —— 插件面板的数据源是它们。
  assert.match(code, /connection\.fetch\.register/)
})

test('二维码：把 pairingQrSvg 的产出铺到位图再解回来，等于原载荷（真 round-trip）', async () => {
  // 形状照 `pairing-v2.md` §12.1：v / relay / pcId / 两把 64 hex 公钥 / offerId / code。
  const payload = JSON.stringify({
    v: 2,
    relay: 'ws://127.0.0.1:8787/ws/connector',
    pcId: 'local',
    pcPubEd: '45bbbc0908fb4644863a3256ca495903974dd72c0fc937730d9452f36bde6480',
    pcPubDh: '14671291ea5b1ff9ce47c1cddcdf66893ce5f4a90ee18bad75e427f3ca21ef55',
    offerId: 'VmzSrDg2ldssCTggYEhs7A',
    code: 'FsqQjW5d08rAe-RxDckZyw',
  })
  const svg = await pairingQrSvg(payload)
  assert.match(svg, /^<svg/)

  const size = Number((svg.match(/viewBox="0 0 (\d+) \d+"/) ?? [])[1])
  assert.ok(Number.isInteger(size) && size > 0, `SVG 里应有 viewBox 尺寸，实际 ${size}`)

  // 黑色 stroke path 的 `d` 是横向游程：`M x y` 起线，`h n` 画 n 个模块，
  // `m dx 0` 空出 dx 个模块（dy 恒 0）。按这个铺出模块矩阵。
  // **坐标要取整**：SVG 为了让 1px  stroke 居中在模块行上，y 写成 `2.5` 这种半数。
  const dark = new Set<string>()
  const blackPath = (svg.match(/<path stroke="#000000" d="([^"]+)"/) ?? [])[1]
  assert.ok(blackPath !== undefined, '应有一条黑色 stroke path')
  let x = 0
  let y = 0
  for (const token of blackPath.match(/[Mhm]\s*-?[\d.]+\s*-?[\d.]*/g) ?? []) {
    const cmd = token[0]
    const nums = (token.slice(1).match(/-?[\d.]+/g) ?? []).map(Number)
    if (cmd === 'M') {
      x = Math.round(nums[0] as number)
      y = Math.round(nums[1] as number)
      dark.add(`${x},${y}`)
    } else if (cmd === 'h') {
      const n = nums[0] as number
      for (let i = 0; i < n; i++) dark.add(`${x + i},${y}`)
      x += n
    } else {
      x += nums[0] as number
      y += (nums[1] ?? 0) as number
    }
  }
  assert.ok(dark.size > 0, '游程解析应得出黑模块')

  // 铺成 jsQR 吃的 RGBA 位图。放大 8 倍并留 4 模块静区，
  // 否则解码器找不到定位图形。
  const scale = 8
  const quiet = 4
  const side = (size + quiet * 2) * scale
  const data = new Uint8ClampedArray(side * side * 4)
  for (let row = 0; row < side; row++) {
    for (let col = 0; col < side; col++) {
      const mx = Math.floor(col / scale) - quiet
      const my = Math.floor(row / scale) - quiet
      const on = mx >= 0 && my >= 0 && mx < size && my < size && dark.has(`${mx},${my}`)
      const v = on ? 0 : 255
      const i = (row * side + col) * 4
      data[i] = v
      data[i + 1] = v
      data[i + 2] = v
      data[i + 3] = 255
    }
  }

  const decoded = jsQR(data, side, side)
  assert.ok(decoded !== null, 'jsQR 应能解出内容 —— 解不出说明编码产物是坏的')
  assert.equal(decoded.data, payload,
    '解回来的载荷必须与编码前逐字相同：改一个字段就说明形状在链路里被动了')
})

test('issuePairingOffer：登记失败就抛，不出码', async () => {
  const pairing = { offer: () => ({ offerId: 'o1', code: 'c', expiresAt: 1, payload: '{}' }) } as unknown as Pairing
  await assert.rejects(
    () => issuePairingOffer({
      pairing,
      register: async () => { throw new Error('relay down') },
    }),
    /登记到中转/,
    '登记不成必须抛 —— 吞掉它等于发出一张注定配不上的二维码',
  )
})

test('offerForScanning：成功时文本里带载荷；失败时是 error 而不是 success', async () => {
  const pairing = { offer: () => ({ offerId: 'o1', code: 'c', expiresAt: Date.now() + 60000, payload: '{"v":2}' }) } as unknown as Pairing
  const ok = await offerForScanning({ pairing, register: async () => {} })
  assert.equal(ok.kind, 'success')
  assert.match(ok.kind === 'success' ? ok.text : '', /\{"v":2\}/)

  const bad = await offerForScanning({
    pairing,
    register: async () => { throw new Error('nope') },
  })
  assert.equal(bad.kind, 'error')
  assert.match(bad.kind === 'error' ? bad.text : '', /中转/)
})
