/**
 * 独占（1:1）的**时序推演**：没有第二台真机，就把两台设备会发生的交错按顺序跑一遍。
 *
 * ## 它和 `exclusive.test.ts` 的分工
 *
 * 那一篇钉单点判据（"别的设备在服务就拒"）；这一篇钉**顺序**：同一组事件换个先后，
 * 结论必须仍然对。独占的 bug 几乎都不是"判据写错"，而是"顺序一换就漏"——
 * 例如旧连接迟到的断开、吊销与握手的先后、两台同时进门那一瞬。
 *
 * ## 用的是真模块，不是替身
 *
 * `createDevicePresence`（占用位的唯一事实来源）+ `createExclusiveAdmission`（准入）
 * + `createDeviceAdmin`（停用/删除 → 收连接）。这里只把"连接的生命周期事件"
 * （握手完成 / 收口 / 行失效）按连接层真实调用的那几个函数手写出来：
 * - 握手完成 = `presence.online(devId, holder)`（`connection-scope.ts` 的 `deviceEstablished`）
 * - 连接收口 = `presence.offline(devId, holder)`（同文件的 `servingEnded`）
 * - 行失效   = `deviceAdmin.setEnabled(false)` / `remove()` → 装配层按 `devId` 收连接
 *
 * 也就是说：这一篇证明的是**判据与顺序**；"设备连接对象真的被 stop"由
 * `device-admin.test.ts`（`disconnect` 被调用）与 `connection-scope.test.ts`
 * （presence 上报时机）各自守住。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createDeviceAdmin, type DeviceTablePort } from '../src/admin/device-admin.js'
import { createExclusiveAdmission } from '../src/exclusive.js'
import { createDevicePresence } from '../src/presence.js'
import { coreDomain, type DeviceRecord } from '../src/store/index.js'

interface RosterRow {
  pairedAt: number
  revokedAt?: number
  name?: string
}

/**
 * 一台电脑 + 它的名册 + 占用位。事件用**连接层真实的调用形状**表达。
 *
 * `holders` 模拟"每连接一个令牌"：同一台设备的两条连接各有一个，收口时按它判。
 */
function world(roster: Record<string, RosterRow>) {
  const presence = createDevicePresence({
    pairedAtOf: (devId) => {
      const row = roster[devId]
      return row === undefined || row.revokedAt !== undefined ? undefined : row.pairedAt
    },
  })
  const admission = createExclusiveAdmission({
    presence,
    nameOf: (devId) => roster[devId]?.name,
  })

  /** 每条"连接"一个令牌（`devId` 可以有多个：换网重连时新旧并存）。 */
  const holders = new Map<object, string>()

  /** 一条连接完成握手。返回它的令牌（收口时要拿它）。 */
  const establish = (devId: string): object => {
    const holder = {}
    holders.set(holder, devId)
    presence.online(devId, holder)
    return holder
  }

  /** 一条连接收口（`servingEnded`）。 */
  const end = (holder: object): void => {
    const devId = holders.get(holder)
    if (devId === undefined) throw new Error('收口只能对一条真的建立过的连接')
    holders.delete(holder)
    presence.offline(devId, holder)
  }

  return { presence, admission, establish, end }
}

/** 一行合法设备（schema 见 `store/index.ts`）。 */
function rowOf(name: string): DeviceRecord {
  return {
    edPub: 'a'.repeat(64),
    dhPub: 'b'.repeat(64),
    name,
    pairedAt: 1760000000000,
    pairingId: 'pair-1',
  }
}

test('推演 1：A 在服务 → B 来 → 被拒（理由里是 A），且 A 一点不受影响', () => {
  const w = world({
    'dev-a': { pairedAt: 100, name: '我的手机' },
    'dev-b': { pairedAt: 50, name: '平板' },
  })
  const a = w.establish('dev-a')

  assert.equal(w.admission.occupantOf('dev-b'), '我的手机')
  // 拒的是**新来的**：A 的记录、前台态、订阅集全都没被碰过。
  assert.equal(w.presence.serving()?.id, 'dev-a')
  assert.equal(w.presence.liveOf('dev-a')?.online, true)
  assert.equal(w.admission.occupantOf('dev-a'), undefined, 'A 自己重连照旧放行')

  w.end(a)
  assert.equal(w.presence.serving(), undefined)
})

test('推演 2：A 换网重连（新旧两条连接重叠）→ 新连接建得起来，且旧连接晚到的断开来不掉座位', () => {
  const w = world({ 'dev-a': { pairedAt: 100, name: '我的手机' } })
  const oldConnection = w.establish('dev-a')

  // 新连接进来（中转的 `replaced` 会先关旧的，但两条 TCP 的收口顺序不保证）：
  assert.equal(w.admission.occupantOf('dev-a'), undefined, '同一 devId 不被自己挡')
  const newConnection = w.establish('dev-a')
  assert.equal(w.presence.serving()?.id, 'dev-a')

  // 旧连接的断开**晚到**：不许抹掉新连接的服务位。
  w.end(oldConnection)
  assert.equal(w.presence.serving()?.id, 'dev-a', '座位仍归新连接')
  assert.equal(w.presence.liveOf('dev-a')?.online, true)

  // 新连接自己断开：座位才空，B 才能进。
  w.end(newConnection)
  assert.equal(w.presence.serving(), undefined)
  assert.equal(w.admission.occupantOf('dev-b'), undefined)
})

test('推演 3：A 切走（主动 close）→ B 立刻能进（不必等心跳）', () => {
  const w = world({
    'dev-a': { pairedAt: 100, name: '我的手机' },
    'dev-b': { pairedAt: 50, name: '平板' },
  })
  const a = w.establish('dev-a')
  assert.equal(w.admission.occupantOf('dev-b'), '我的手机')

  w.end(a) // 手机侧 dispose → socket close → servingEnded
  assert.equal(w.admission.occupantOf('dev-b'), undefined, '释放是同步的，下一次心跳之前就空')
  w.establish('dev-b')
  assert.equal(w.presence.serving()?.id, 'dev-b')
})

test('推演 4：停用占用者 → 它立刻下线，B 才能进（门槛 8e 的时序版）', async () => {
  const tableRecords = new Map<string, DeviceRecord>([
    ['dev-a', rowOf('我的手机')],
    ['dev-b', rowOf('平板')],
  ])
  const schema = coreDomain.tables['devices']?.valueSchema
  assert.ok(schema !== undefined)
  const table: DeviceTablePort = {
    get: (key) => tableRecords.get(key),
    keys: () => [...tableRecords.keys()],
    async put(key, value) {
      const parsed = schema.safeParse(value)
      assert.equal(parsed.success, true)
      tableRecords.set(key, parsed.data as DeviceRecord)
    },
    async delete(key) { return tableRecords.delete(key) },
  }

  // 名册与占用位共用同一份表：`pairedAtOf` 按 `revokedAt` 判失效。
  const presence = createDevicePresence({
    pairedAtOf: (devId) => {
      const record = table.get(devId)
      return record === undefined || record.revokedAt !== undefined ? undefined : record.pairedAt
    },
  })
  const admission = createExclusiveAdmission({
    presence,
    nameOf: (devId) => table.get(devId)?.name,
  })
  // 装配层的映射：握手成功登记 `devId → 连接`，停用/删除时按它收连接。
  const live = new Map<string, { stopped: boolean }>()
  const connectionOf = (devId: string) => {
    const connection = { stopped: false }
    live.set(devId, connection)
    return connection
  }
  const admin = createDeviceAdmin({
    tableOf: () => table,
    onlineIds: () => new Set(presence.devices().filter((row) => row.online).map((row) => row.id)),
    publish: async () => {},
    disconnect: (ids) => {
      for (const id of ids) {
        const connection = live.get(id)
        if (connection === undefined) continue
        connection.stopped = true
        // 连接对象 stop() 的收口效果：servingEnded 会调 presence.offline。
        presence.offline(id)
      }
    },
  })

  const holder = {}
  presence.online('dev-a', holder)
  const aConnection = connectionOf('dev-a')

  // A 在服务时 B 进不来。
  assert.equal(admission.occupantOf('dev-b'), '我的手机')

  await admin.setEnabled('dev-a', false)

  assert.equal(aConnection.stopped, true, '停用必须真的收掉那条连接')
  assert.equal(presence.serving(), undefined, '收掉连接之后占用位才空')
  assert.equal(admission.occupantOf('dev-b'), undefined, 'B 现在可以进')
  presence.online('dev-b')
  assert.equal(presence.serving()?.id, 'dev-b')

  // 清理已停用的行同理：行没了 → 不占位；连接也必须被收掉。
  // （活跃行不许直接删 —— 先停用，见 `device-admin` 不变量 2。）
  await admin.setEnabled('dev-b', false)
  const bConnection = connectionOf('dev-b')
  await admin.remove(['dev-b'])
  assert.equal(bConnection.stopped, true)
  assert.equal(presence.serving(), undefined)
})

test('推演 5（已知窗口，钉住现状）：两台同时握手那一瞬都会进；事后按"在位者"判', () => {
  // 准入是"hello 那一刻"判的，而"已 established"才写占用位 —— 两条握手同时进来时
  // 都会看到空座位。这是本步**刻意不接受**的窗口（闭掉它要给占用位一个"在途"维度）。
  // 这一条把它钉成**已知行为**：哪天有人改了，这里会红，提醒他同步改方案与文档。
  const w = world({
    'dev-a': { pairedAt: 100, name: '我的手机' },
    'dev-b': { pairedAt: 50, name: '平板' },
    'dev-c': { pairedAt: 10, name: '旧手机' },
  })

  // 两条握手都在座位还空时通过准入。
  assert.equal(w.admission.occupantOf('dev-a'), undefined)
  assert.equal(w.admission.occupantOf('dev-b'), undefined)

  // 双双 established：占用位里出现两条（这就是那个窗口的结果）。
  w.establish('dev-a')
  w.establish('dev-b')
  assert.equal(w.presence.devices().filter((row) => row.online).length, 2)

  // 事后判据仍然成立：第三台必拒；在位者（先来的 A）自己放行，B 被判成占用。
  assert.notEqual(w.admission.occupantOf('dev-c'), undefined)
  assert.equal(w.admission.occupantOf('dev-a'), undefined)
  assert.equal(w.admission.occupantOf('dev-b'), '我的手机')
})
