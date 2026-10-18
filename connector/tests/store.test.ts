/**
 * 存储域声明的回归（契约 §8.1）。
 *
 * 这里**刻意不开 domain**：`ctx.storageDomain.open()` 需要完整 DSH 运行时与后端介质，
 * 而那些属于第 5 步的集成验收。本文件钉的是**声明期**就能确定、且一旦写错会在
 * 模块加载或首次落盘时才炸的那几条性质：
 *
 * - 域名/表名合规（`defineDomain` 会当场抛，所以"能 import 成功"本身就是一条断言）；
 * - global 的初值合法，且 schema **不接受 `null``**（null 是「从未写过」的哨兵）；
 * - 业务 schema 的逐代迁移只前进、不跳代、拒绝未来版本。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  SCHEMA_VERSION,
  coreDomain,
  initialMeta,
  migrateMeta,
  windowsDomain,
} from '../src/store/index.js'

/** `packages/storage/storage/src/backend.ts:10` 的 `UNIT_NAME_RE`。 */
const UNIT_NAME_RE = /^[a-z][a-z0-9_]*$/

test('存储域：域名与表名合规、版本合法', () => {
  for (const domain of [coreDomain, windowsDomain]) {
    assert.match(domain.name, UNIT_NAME_RE, `域名 ${domain.name} 不合规`)
    assert.ok(Number.isInteger(domain.version) && domain.version >= 0, 'version 必须是非负整数')
    for (const table of Object.keys(domain.tables)) {
      assert.match(table, UNIT_NAME_RE, `表名 ${table} 不合规`)
    }
    // 连字符是这条规则的经典踩坑点 —— `CredentialKey` 那套规则正好相反。
    assert.equal(domain.name.includes('-'), false, '域名不许带连字符')
  }

  // `windows` 单独成域，好让它的巨型写不堵住 core 的同步写。
  // 两边都排序再比：这里关心的是"有哪些表"，不是声明顺序。
  assert.deepEqual(
    Object.keys(coreDomain.tables).sort(),
    ['advertise', 'by_sid', 'by_session', 'dedupe', 'devices', 'takeover'].sort(),
  )
  assert.deepEqual(Object.keys(windowsDomain.tables).sort(), ['windows'])
})

test('存储域：global 的初值合法，且 schema 不接受 null', () => {
  const global = coreDomain.global
  assert.ok(global !== undefined, 'core 域必须有 global（meta 是单条记录）')

  // 初值必须能过自己的 schema —— 否则「从未写过」时会读到非法值。
  assert.equal(global.schema.safeParse(global.initial).success, true)

  // null 是后端「从未写过」的哨兵：可空的 global 会把"存过的 null"和"没写过"
  // 混成同一件事，重开时静默退回 initial（`spec.ts` 的 `defineDomain` 注释）。
  assert.equal(global.schema.safeParse(null).success, false)
})

test('meta：未配置由空串表达，不是靠缺字段', () => {
  const meta = initialMeta({ connectorId: 'c1', relayUrl: 'wss://x', connTokenSecretRef: 'ref' })
  assert.equal(meta.schema, SCHEMA_VERSION)
  assert.equal(meta.aliasVersion, 0)
  assert.equal(meta.connectorId, 'c1')
})

test('迁移：同版本直通、未来版本拒绝', () => {
  const current = initialMeta({ connectorId: 'c1', relayUrl: 'wss://x', connTokenSecretRef: 'ref' })
  assert.deepEqual(migrateMeta(current), current)

  // 老插件读到新数据必须拒绝启动 —— 「看起来能跑但语义已经错了」比不启动危险得多。
  assert.throws(
    () => migrateMeta({ ...current, schema: SCHEMA_VERSION + 1 }),
    /connector\/unsupported/,
  )
})

test('迁移：v1 → v2 逐代升，只动 meta，不碰设备行', () => {
  // v1 的 meta 就是「现在的形状少一代版本号」；设备记录新增的 `pairingId` 没有任何历史行
  // 需要补（配对流程还没落地，插件至今只读那张表），所以迁移不该凭空造一个配对标识出来。
  const v1 = { ...initialMeta({ connectorId: 'c1', relayUrl: 'wss://x', connTokenSecretRef: 'ref' }), schema: 1 }
  const migrated = migrateMeta(v1)

  assert.equal(migrated.schema, SCHEMA_VERSION)
  assert.equal(migrated.schema, 2)
  assert.deepEqual(
    { ...migrated, schema: 1 },
    v1,
    '迁移只该改版本号，其余字段原样带过去',
  )

  // 逐代：起点必须是紧邻的上一代，不能跳代。
  assert.throws(() => migrateMeta({ ...v1, schema: 0 }), /缺少 v0 → v1 的迁移/)
})

test('设备记录：pairingId 是必填 —— 缺了它设备能配对却再也握不上手', () => {
  const devices = coreDomain.tables['devices']
  assert.ok(devices !== undefined)
  const base = {
    edPub: 'a'.repeat(64),
    dhPub: 'b'.repeat(64),
    name: '手机',
    pairedAt: 1,
  }
  assert.equal(devices.valueSchema.safeParse(base).success, false, '没有 pairingId 必须不合法')
  assert.equal(devices.valueSchema.safeParse({ ...base, pairingId: 'pair-1' }).success, true)
  assert.equal(
    devices.valueSchema.safeParse({ ...base, pairingId: '' }).success,
    false,
    '空串不是配对标识',
  )
})
