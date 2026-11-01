/**
 * 只读快照的内容摘要（契约 §5.7 的 `digest` / `notModified`）。
 *
 * 判据（`.agents/notes/proposed/2026-11-01-never-pull-unchanged.md` 的 Testing 节）：
 *
 * 1. 同参数同内容两次请求 ⇒ 第二次只回 `{notModified: true}`（约 20 B，且实发字节真的降了）；
 * 2. 内容改一个字段 ⇒ 第三次回正文；
 * 3. **分页参数不同 ⇒ 摘要不互相命中**（`session.list` 的 `limit` / `offset` 不同是两个包）；
 * 4. 不带 `digest` ⇒ 与今天逐字相同（老客户端）；
 * 5. `digest` 形状不对 ⇒ `protocol/bad-frame`（静默忽略的症状是"上线了但一个字节也没省"）；
 * 6. 白名单外的方法带 `digest` 合法但**不比对**（写方法的应答不是"某一版数据"）；
 * 7. `ok:false` 的应答**不比**：错误不能被记成"没变"。
 *
 * 摘要算的是 `resFrame()` 产出的**那份字节**（不是 `result` 的重新序列化）——
 * 客户端也是对自己收到的那一包求摘要，两侧口径必须一致，否则永远不命中。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createMethodFace } from '../src/method-face.js'
import type { WireFrame } from '../src/protocol/frame.js'
import type { MethodHandler, MethodName } from '../src/protocol/methods.js'
import {
  SNAPSHOT_DIGEST_LENGTH,
  SNAPSHOT_DIGEST_METHODS,
  acceptsSnapshotDigest,
  isSnapshotDigest,
  snapshotDigestOf,
} from '../src/protocol/snapshot-digest.js'

const req = (box: string): WireFrame => ({
  v: 1,
  t: 'req',
  id: 'req_0123456789ab',
  fc: 0,
  box,
})

/** 一格可变的应答内容：改它就等于"电脑侧的数据变了"。 */
function faceOf(value: { body: unknown }, method: MethodName = 'repo.info') {
  return createMethodFace({ handlers: { [method]: () => value.body } })
}

/** 一次调用，返回（信封, 实发字节）。 */
async function call(
  face: ReturnType<typeof createMethodFace>,
  method: string,
  params: object = {},
  digest?: string,
): Promise<{ envelope: Record<string, unknown>; bytes: number }> {
  const box = JSON.stringify({ method, params, ...(digest === undefined ? {} : { digest }) })
  const res = await face.handle(req(box))
  assert.ok(res !== null && res.t === 'res')
  return { envelope: JSON.parse(res.box) as Record<string, unknown>, bytes: Buffer.byteLength(res.box) }
}

test('跨端固定向量：与手机侧同一个摘要（base64url、无填充、43 字符）', () => {
  // 期望值是外部真值（`sha256` 的定义 + RFC 4648 的 base64url），不是从本仓实现抄的。
  // 手机侧 `app/test/snapshot_digest_test.dart` 断言同一个常量 —— 两侧口径漂了，
  // 症状只是"摘要从没命中过"（多发字节，没人会去查），所以必须各钉一条。
  assert.equal(
    snapshotDigestOf('{"ok":true,"result":{"a":1}}'),
    'C-IwaBxQXATEjck-6Rpr16aLFxI7Ntsn94ThxOhHbV4',
  )
})

test('摘要口径：43 个 base64url 字符，同一份字节稳定、改一个字节就变', () => {
  // 与 `DIGEST_PATTERN` 是同一个数（写成两处但这里钉住它们一致）。
  assert.equal(SNAPSHOT_DIGEST_LENGTH, 43)
  const digest = snapshotDigestOf('{"ok":true,"result":{}}')
  assert.equal(digest.length, SNAPSHOT_DIGEST_LENGTH)
  assert.ok(isSnapshotDigest(digest))
  assert.equal(snapshotDigestOf('{"ok":true,"result":{}}'), digest, '同一份字节必须是同一个摘要')
  assert.notEqual(snapshotDigestOf('{"ok":true,"result":{"a":1}}'), digest)
})

test('同参数同内容：第二次只回 notModified，字节从正文掉到几十 B', async () => {
  const value = { body: { catalog: 'x'.repeat(4000) } }
  const face = faceOf(value)

  const first = await call(face, 'repo.info')
  assert.ok('result' in first.envelope)
  const digest = snapshotDigestOf(JSON.stringify(first.envelope))

  const second = await call(face, 'repo.info', {}, digest)
  assert.deepEqual(second.envelope, { ok: true, result: { notModified: true } })
  assert.ok(second.bytes < 100, `notModified 应该只有几十字节，实际 ${second.bytes}`)
  assert.ok(first.bytes > 4000, '前提：正文确实是"大包"')

  // **第三次：内容改了一个字段 ⇒ 摘要对不上 ⇒ 照常发正文**（这是"绝不会漏发"的方向）。
  value.body = { catalog: 'y'.repeat(4000) }
  const third = await call(face, 'repo.info', {}, digest)
  assert.deepEqual(third.envelope, { ok: true, result: { catalog: 'y'.repeat(4000) } })
})

test('不带 digest：与今天逐字相同（老客户端的形状一个字都没变）', async () => {
  const face = faceOf({ body: { a: 1 } })
  const plain = await call(face, 'repo.info')
  assert.deepEqual(plain.envelope, { ok: true, result: { a: 1 } })
})

test('分页参数不同 ⇒ 摘要不互相命中（那是两个包，共用一个就错配）', async () => {
  // 连接器把参数原样交给 handler；这里用一个"回显参数"的替身模拟 session.list。
  const face = createMethodFace({
    handlers: {
      'session.list': (params) => ({ sessions: [], echoed: params }),
    },
  })

  const page1 = await call(face, 'session.list', { limit: 50 })
  const digest1 = snapshotDigestOf(JSON.stringify(page1.envelope))

  const page2 = await call(face, 'session.list', { limit: 50, offset: 50 }, digest1)
  assert.ok(
    'result' in page2.envelope && (page2.envelope['result'] as { notModified?: true }).notModified !== true,
    '第二页带着第一页的摘要来问，必须回正文（否则手机会把第一页当成第二页）',
  )

  // 拿第二页的摘要再问同参数 ⇒ 这时才该命中。
  const digest2 = snapshotDigestOf(JSON.stringify(page2.envelope))
  const again = await call(face, 'session.list', { limit: 50, offset: 50 }, digest2)
  assert.deepEqual(again.envelope, { ok: true, result: { notModified: true } })
})

test('白名单：九个宿主状态 key + endpoint.describe，写方法一个都不认', () => {
  for (const method of [
    'session.list',
    'session.projections',
    'settings.describe',
    'job.list',
    'session.modelCatalog',
    'permission.catalog',
    'agentPresets.list',
    'workspace.list',
    'repo.info',
    'endpoint.describe',
  ]) {
    assert.ok(acceptsSnapshotDigest(method), `${method} 应该认摘要`)
  }
  // 写方法 / 流式方法的应答不是"某一版数据"，带摘要合法但不比对。
  for (const method of ['session.prompt', 'session.create', 'session.page', 'usage.summary']) {
    assert.equal(acceptsSnapshotDigest(method), false, `${method} 不该认摘要`)
  }
  // 白名单必须**从宿主状态表派生**：两份字面量必然漂移，漂移的症状是"某个 key 永不命中"。
  assert.equal(SNAPSHOT_DIGEST_METHODS.size, 10)
})

test('白名单外的方法带 digest：合法，但不比对（正文照发）', async () => {
  const face = createMethodFace({ handlers: { 'usage.summary': () => ({ total: 1 }) } })
  const first = await call(face, 'usage.summary')
  const digest = snapshotDigestOf(JSON.stringify(first.envelope))
  const second = await call(face, 'usage.summary', {}, digest)
  assert.deepEqual(second.envelope, { ok: true, result: { total: 1 } })
})

test('ok:false 不比摘要：错误不能被记成"没变"', async () => {
  const handler: MethodHandler = () => {
    throw new Error('炸了')
  }
  const face = createMethodFace({ handlers: { 'repo.info': handler } })
  const first = await call(face, 'repo.info')
  assert.equal(first.envelope['ok'], false)
  const digest = snapshotDigestOf(JSON.stringify(first.envelope))
  const second = await call(face, 'repo.info', {}, digest)
  assert.equal(second.envelope['ok'], false, '第二次照样是错误应答，不是 notModified')
})

test('digest 形状不对 ⇒ protocol/bad-frame（不是"当作没带"）', async () => {
  const face = faceOf({ body: { a: 1 } })
  for (const bad of [
    'not-a-digest',
    'x'.repeat(42),
    'x'.repeat(44),
    // base64 带填充 / 标准字母表里的 + 与 /：都不是 base64url。
    `${'x'.repeat(42)}=`,
    `${'x'.repeat(42)}+`,
    'x'.repeat(42) + '/',
  ]) {
    const box = JSON.stringify({ method: 'repo.info', params: {}, digest: bad })
    const res = await face.handle(req(box))
    assert.ok(res !== null && res.t === 'res')
    assert.equal(res.ok, false, `digest=${JSON.stringify(bad)} 必须被拒`)
    assert.equal((JSON.parse(res.box) as { code?: string }).code, 'protocol/bad-frame')
  }

  // 非字符串同样是 bad-frame。
  for (const bad of [1, true, {}, []]) {
    const box = JSON.stringify({ method: 'repo.info', params: {}, digest: bad })
    const res = await face.handle(req(box))
    assert.ok(res !== null && res.ok === false)
    assert.equal((JSON.parse(res.box) as { code?: string }).code, 'protocol/bad-frame')
  }
})
