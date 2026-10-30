/**
 * 可变摘要表（契约 §12.2；`relay/src/token-table.ts`）。
 *
 * 这一组的价值是"吊销/恢复**不重启**就生效"：启动时建死的表只能靠改配置 + 重启，
 * 那会让已吊销的连接器在重启前继续连得上。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { createDigestAuthenticator, type TokenDigest } from '../src/digest-auth.ts'
import { createTokenTable } from '../src/token-table.ts'

const hash = (token: string): string => createHash('sha256').update(token, 'utf8').digest('hex')

const ENTRIES: readonly TokenDigest[] = [
  { kind: 'connector', id: 'home-pc', hash: hash('t-home'), owner: 'alice' },
  { kind: 'connector', id: 'work-pc', hash: hash('t-work'), owner: 'alice' },
  { kind: 'connector', id: 'solo', hash: hash('t-solo') },
  { kind: 'connector', id: 'old-pc', hash: hash('t-old'), revokedAt: 1_700_000_000_000 },
]

test('加载：已吊销的行留着但不认；可用条数不含它', () => {
  const table = createTokenTable(ENTRIES)
  assert.deepEqual(table.authenticate('t-home'), { kind: 'connector', id: 'home-pc', owner: 'alice' })
  assert.equal(table.authenticate('t-old'), undefined, '软吊销的行留在表里，但不进认证索引')
  assert.equal(table.size, 3)
  assert.equal(table.list().length, 4, '列表要能看见"这个身份曾经存在过、已被吊销"')
})

test('吊销立刻生效；恢复也立刻生效（都不重建表）', () => {
  const table = createTokenTable(ENTRIES, { now: () => 42 })
  assert.equal(table.revoke('home-pc'), true)
  assert.equal(table.authenticate('t-home'), undefined, '吊销之后同一个令牌立刻认不出')
  assert.equal(table.size, 2)
  const row = table.list().find((item) => item.id === 'home-pc')
  assert.equal(row?.revokedAt, 42, '吊销时间由注入的时钟给（可断言，不睡）')

  assert.equal(table.restore('home-pc'), true)
  assert.deepEqual(table.authenticate('t-home'), { kind: 'connector', id: 'home-pc', owner: 'alice' })
  assert.equal(table.list().find((item) => item.id === 'home-pc')?.revokedAt, undefined)
})

test('吊销不存在的 id：false，且不动别人的', () => {
  const table = createTokenTable(ENTRIES)
  assert.equal(table.revoke('nobody'), false)
  assert.equal(table.restore('nobody'), false)
  assert.deepEqual(table.authenticate('t-solo'), { kind: 'connector', id: 'solo' })
})

test('同一个 id 出现两次：**拒绝建表**（否则"吊销的是哪一条"是猜）', () => {
  const duplicated = [...ENTRIES, { kind: 'connector' as const, id: 'solo', hash: hash('t-solo-2') }]
  assert.throws(() => createTokenTable(duplicated), /同一个 id 出现两次/)
})

test('list 只给身份信息，不给摘要（摘要不离开这个模块）', () => {
  const table = createTokenTable(ENTRIES)
  for (const row of table.list()) {
    assert.equal('hash' in row, false, '管理面看得到"谁"，看不到凭据面')
    for (const key of Object.keys(row)) {
      assert.ok(['id', 'owner', 'revokedAt'].includes(key), `多出来的字段：${key}`)
    }
  }
})

test('校验规则只有一份：createDigestAuthenticator 与表同义', () => {
  // 旧形状留给"只需要认证函数"的调用方；它内部就是这张表，所以两条路径不会漂。
  const authenticate = createDigestAuthenticator(ENTRIES)
  const table = createTokenTable(ENTRIES)
  assert.deepEqual(authenticate('t-work'), table.authenticate('t-work'))
  assert.equal(authenticate('t-old'), undefined)
  assert.equal(authenticate.size, table.size)
})
