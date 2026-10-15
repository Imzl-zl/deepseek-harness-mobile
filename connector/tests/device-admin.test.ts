/**
 * 设备管理面三条不变量的回归（`admin/device-admin.ts`）。
 *
 * ## 为什么单独一篇
 *
 * 这三条是 2026-10-15 事故（31 条记录被硬删）之后**最不能错**的地方，而它们
 * 全在服务端的写路径里：
 *
 * 1. **解禁必须把 `revokedAt` 从行上拿掉**。设备行是整行覆盖（`put` 不做部分合并），
 *    所以"解禁"要么解构剔除、要么写 `undefined`。后者会让键留着、值悬空 ——
 *    域表的 `put` 不重新过 zod（`domain.ts:307-313` 直接存对象），读回来只靠
 *    `revokedAt !== undefined` 的判断碰巧救回来。**这条断言钉的是"键不在"，
 *    不是"值等于 undefined"**：JSON 序列化会把 `undefined` 的键丢掉，于是两条路
 *    在磁盘上看起来一样，而内存里的行不一样 —— 同一个进程内先写后读就会露出来。
 * 2. **在线豁免只属于按状态批量**。`removeScope(scope)` 的人口是隐式的一整类，
 *    2026-10-15 事故的危险正来自隐式人口，所以在线的绝不碰；`remove(devIds)`
 *    是操作者指着某一行 / 逐个勾的，意图无歧义，**可以删在线的**（手机丢了还在线，
 *    要立刻弄死它）。
 * 3. **删完要重发名册**：中转按名册认设备（§8.2 / I7），不重发的话删掉的行
 *    还换得到票。一台都没删则不重发。
 *
 * 这里用**真域表**（`coreDomain` 的 `devices` 表）而不是手写替身：`revokedAt`
 * 的存法与读法都是 zod schema 决定的，替身会把这条最关键的环节绕开。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createDeviceAdmin, type DeviceTablePort } from '../src/admin/device-admin.js'
import { coreDomain, type DeviceRecord } from '../src/store/index.js'

/** 一行设备的最小合法形状（schema 见 `store/index.ts`）。 */
function row(over: Partial<DeviceRecord> = {}): DeviceRecord {
  return {
    edPub: 'a'.repeat(64),
    dhPub: 'b'.repeat(64),
    name: '手机',
    pairedAt: 1760000000000,
    pairingId: 'pair-1',
    ...over,
  }
}

/**
 * 一个**真 schema、假介质**的设备表。
 *
 * 值按 `deviceSchema` 校验后再进 map —— 落盘的形状必须和域表一致，
 * 否则"解禁后键还在不在"这条断言就是自己哄自己。
 */
function tableOf(seed: Record<string, DeviceRecord>): DeviceTablePort & { snapshot(): Map<string, DeviceRecord> } {
  const records = new Map<string, DeviceRecord>(Object.entries(seed))
  const schema = coreDomain.tables['devices']?.valueSchema
  assert.ok(schema !== undefined, 'core 域必须声明 devices 表')
  return {
    get: (key) => records.get(key),
    keys: () => [...records.keys()],
    async put(key, value) {
      const parsed = schema.safeParse(value)
      assert.equal(parsed.success, true, `写进去的行必须合法：${JSON.stringify(value)}`)
      records.set(key, parsed.data as DeviceRecord)
    },
    async delete(key) {
      return records.delete(key)
    },
    snapshot: () => records,
  }
}

/** 在线的设备 id 集合。每台建一次 admin，避免跨用例串味。 */
function adminOf(table: DeviceTablePort, online: readonly string[] = [], published: number[] = []) {
  return createDeviceAdmin({
    tableOf: () => table,
    onlineIds: () => new Set(online),
    publish: async () => { published.push(Date.now()) },
  })
}

test('停用：只标 revokedAt，行还在（记录仍会保留）', async () => {
  const table = tableOf({ dev1: row(), dev2: row({ name: '平板' }) })
  const published: number[] = []
  await adminOf(table, [], published).setEnabled('dev1', false)

  const after = table.snapshot()
  assert.equal(after.size, 2, '停用不删行')
  assert.equal(typeof after.get('dev1')?.revokedAt, 'number', ' revokedAt 是时间戳')
  assert.equal(after.get('dev2')?.revokedAt, undefined, '别的行不动')
  // 停用要摘出名册，所以必须重发。
  assert.equal(published.length, 1)
})

test('解禁：revokedAt 从行上**去掉**，不是写成 undefined', async () => {
  const table = tableOf({ dev1: row({ revokedAt: 1760000000000 }) })
  await adminOf(table).setEnabled('dev1', true)

  const after = table.snapshot().get('dev1')
  assert.ok(after !== undefined)
  // **键必须不在**。`'revokedAt' in row` 与 `row.revokedAt === undefined` 是两件事：
  // 前者才是"这行没有被停用过"的如实表达，后者会留下一个悬空的键。
  assert.equal('revokedAt' in after, false, '解构剔除，不是写 undefined')
  assert.equal(after.revokedAt, undefined)
  // 其余字段原样带过去（整行覆盖，不许顺手丢字段）。
  assert.deepEqual(after, row())
})

test('解禁：没停用过的行也是幂等的（键照样不在，其余不动）', async () => {
  const table = tableOf({ dev1: row() })
  await adminOf(table).setEnabled('dev1', true)

  assert.deepEqual(table.snapshot().get('dev1'), row())
})

test('停用/启用：未知设备 id 抛错，且不当成功', async () => {
  const table = tableOf({ dev1: row() })
  await assert.rejects(
    () => adminOf(table).setEnabled('dev-nope', false),
    /未知设备：dev-nope/,
    '不认识的 id 必须抛 —— 静默返回会让页面显示"已停用"而什么都没发生',
  )
  assert.equal(table.snapshot().size, 1)
  assert.equal(table.snapshot().get('dev1')?.revokedAt, undefined)
})

test('删除：多选删指定几台，行从表里抹掉', async () => {
  const table = tableOf({
    dev1: row(), dev2: row({ name: '平板' }), dev3: row({ name: '旧手机' }),
  })
  const published: number[] = []
  const result = await adminOf(table, [], published).remove(['dev2', 'dev3'])

  assert.deepEqual(result, { removed: 2, skippedOnline: 0 })
  assert.deepEqual([...table.snapshot().keys()], ['dev1'])
  assert.equal(published.length, 1, '删完了要重发名册')
})

test('删除：单台就是长度 1 的多选，同一条路', async () => {
  const table = tableOf({ dev1: row(), dev2: row() })
  const result = await adminOf(table).remove(['dev1'])
  assert.deepEqual(result, { removed: 1, skippedOnline: 0 })
  assert.deepEqual([...table.snapshot().keys()], ['dev2'])
})

test('删除：显式点名的 id 可以删在线的（单台与多选都算）', async () => {
  // **在线豁免只属于按状态批量**（不变量 2）。显式 = 操作者指着某一行 / 逐个勾的，
  // 意图无歧义 —— 手机丢了还在线，要立刻弄死它，为此先"让那台手机断开连接"是荒谬的。
  // 改这条之前，单台删除一直是允许删在线的；悄悄收回能力比危险更糟。
  const seed = {
    live: row({ name: '我的手机' }),
    idle: row({ name: '平板' }),
  }

  // 单台（长度 1 的数组）：点名了在线那台，就删它。
  const single = tableOf(seed)
  assert.deepEqual(await adminOf(single, ['live']).remove(['live']), { removed: 1, skippedOnline: 0 })
  assert.deepEqual([...single.snapshot().keys()], ['idle'], '在线那台被删掉了')

  // 多选：一台在线一台离线，两台都删。
  const multi = tableOf(seed)
  assert.deepEqual(await adminOf(multi, ['live']).remove(['live', 'idle']), { removed: 2, skippedOnline: 0 })
  assert.equal(multi.snapshot().size, 0, '显式删除一台都不跳过')
})

test('删除：按状态批量绝不碰在线的（scope 两种都算）', async () => {
  const seed = {
    live: row({ name: '我的手机' }),
    idle: row({ name: '平板' }),
    gone: row({ name: '旧手机', revokedAt: 1760000000000 }),
  }

  // scope 'all'：在线那台留下。
  const all = tableOf(seed)
  assert.deepEqual(await adminOf(all, ['live']).removeScope('all'), { removed: 2, skippedOnline: 1 })
  assert.deepEqual([...all.snapshot().keys()], ['live'])

  // scope 'revoked'：只删已停用的，未停用的一台不动。
  const revoked = tableOf(seed)
  assert.deepEqual(await adminOf(revoked, ['live']).removeScope('revoked'), { removed: 1, skippedOnline: 0 })
  assert.deepEqual([...revoked.snapshot().keys()], ['live', 'idle'])
})

test('删除：skippedOnline 只数"本来要删、因在线而没删"的行', async () => {
  // `live` 在线且**未停用**，`gone` 在线且**已停用**。按"已停用"清时只有 `gone`
  // 本来会被删 —— 把 `live` 也算成跳过会报一个比真实情况大的数字。
  const table = tableOf({
    live: row({ name: '我的手机' }),
    gone: row({ name: '旧手机', revokedAt: 1760000000000 }),
  })
  const result = await adminOf(table, ['live', 'gone']).removeScope('revoked')
  assert.deepEqual(result, { removed: 0, skippedOnline: 1 })
})

test('删除：一台都没删就不重发名册（无事不打扰中转）', async () => {
  const table = tableOf({ dev1: row() })
  const published: number[] = []
  const result = await adminOf(table, ['dev1'], published).removeScope('all')
  assert.deepEqual(result, { removed: 0, skippedOnline: 1 })
  assert.equal(published.length, 0, '一台都没动就不必打扰中转')
})

test('删除：scope=revoked 只删已停用的，未停用的一台不动', async () => {
  const table = tableOf({
    idle: row({ name: '平板' }),
    gone: row({ name: '旧手机', revokedAt: 1760000000000 }),
  })
  assert.deepEqual(await adminOf(table).removeScope('revoked'), { removed: 1, skippedOnline: 0 })
  assert.deepEqual([...table.snapshot().keys()], ['idle'])
})
