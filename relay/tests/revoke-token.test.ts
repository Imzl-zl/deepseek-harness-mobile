/**
 * 令牌吊销的回归（契约 §12.2：软吊销）。
 *
 * 三条性质：吊销后**认证不通过**、行**留着**（`revokedAt`）、重新签发**清掉**吊销
 * （签发即轮换 —— 那也正是从"吊销"恢复的唯一路径）。
 */
import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { createDigestAuthenticator } from '../src/digest-auth.ts'
import { appendTokenToConfig, issueToken, revokeTokenInConfig } from '../src/issue-token.ts'

async function withConfig<T>(body: (path: string) => Promise<T>): Promise<T> {
  const dir = await mkdtemp(join(tmpdir(), 'dsh-relay-revoke-'))
  const path = join(dir, 'relay.config.json')
  await writeFile(path, JSON.stringify({ port: 0, tokens: [] }), 'utf8')
  try {
    return await body(path)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}

test('吊销：认证不再通过，但**行还留着**（软吊销，审计线索不丢）', async () => {
  await withConfig(async (path) => {
    const issued = issueToken({ kind: 'connector', id: 'conn-1' })
    await appendTokenToConfig(path, { kind: 'connector', id: 'conn-1', hash: issued.hash })
    assert.deepEqual(
      createDigestAuthenticator((await appendTokenToConfig(path, { kind: 'connector', id: 'conn-2', hash: issueToken({ kind: 'connector', id: 'conn-2' }).hash })))(issued.token),
      { kind: 'connector', id: 'conn-1' },
      '吊销前可用',
    )

    const { tokens, revoked } = await revokeTokenInConfig(path, { kind: 'connector', id: 'conn-1' }, 1_000)
    assert.equal(revoked, true)
    assert.equal(tokens.length, 2, '行没有被删掉')
    assert.equal(tokens.find((entry) => entry.id === 'conn-1')?.revokedAt, 1_000)

    const authenticate = createDigestAuthenticator(tokens)
    assert.equal(authenticate(issued.token), undefined, '被吊销的令牌不能再认证')
    assert.equal(tokens.some((entry) => entry.hash === issued.hash), true, '摘要还在配置里')

    const written = await readFile(path, 'utf8')
    assert.equal(written.includes('revokedAt'), true, '吊销落盘')
  })
})

test('吊销是幂等的：重复执行不刷新吊销时刻；未知身份不报错', async () => {
  await withConfig(async (path) => {
    const issued = issueToken({ kind: 'connector', id: 'conn-1' })
    await appendTokenToConfig(path, { kind: 'connector', id: 'conn-1', hash: issued.hash })

    await revokeTokenInConfig(path, { kind: 'connector', id: 'conn-1' }, 1_000)
    const again = await revokeTokenInConfig(path, { kind: 'connector', id: 'conn-1' }, 2_000)
    assert.equal(
      again.tokens.find((entry) => entry.id === 'conn-1')?.revokedAt,
      1_000,
      '第二次吊销不覆盖第一次的时刻（幂等）',
    )

    const unknown = await revokeTokenInConfig(path, { kind: 'connector', id: 'nobody' })
    assert.equal(unknown.revoked, false, '未知身份如实回 false，而不是抛')
    assert.equal(unknown.tokens.length, 1)
  })
})

test('重新签发即轮换：清掉吊销、旧令牌失效、新令牌可用', async () => {
  await withConfig(async (path) => {
    const first = issueToken({ kind: 'connector', id: 'conn-1' })
    await appendTokenToConfig(path, { kind: 'connector', id: 'conn-1', hash: first.hash })
    await revokeTokenInConfig(path, { kind: 'connector', id: 'conn-1' })

    const second = issueToken({ kind: 'connector', id: 'conn-1' })
    const tokens = await appendTokenToConfig(path, { kind: 'connector', id: 'conn-1', hash: second.hash })
    assert.equal(tokens.length, 1, '同一身份仍只有一条')
    assert.equal(tokens[0]?.revokedAt, undefined, '重新签发清掉吊销')

    const authenticate = createDigestAuthenticator(tokens)
    assert.deepEqual(authenticate(second.token), { kind: 'connector', id: 'conn-1' })
    assert.equal(authenticate(first.token), undefined, '旧令牌失效')
  })
})
