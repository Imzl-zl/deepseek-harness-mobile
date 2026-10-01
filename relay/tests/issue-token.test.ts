/**
 * 令牌签发的回归（契约 §12.2）。
 *
 * 核心是一条**安全性质**：令牌本体只出现在签发者眼前，**绝不写进配置** ——
 * 写进去那份配置就从"摘要表"退化成"凭据表"，而 §12.2 只存摘要是为了让
 * "配置被读到时里面的东西不能直接用"。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { createDigestAuthenticator } from '../src/digest-auth.ts'
import { appendTokenToConfig, issueToken } from '../src/issue-token.ts'

async function withConfig<T>(body: (path: string) => Promise<T>): Promise<T> {
  const dir = await mkdtemp(join(tmpdir(), 'dsh-relay-token-'))
  const path = join(dir, 'relay.config.json')
  await writeFile(path, JSON.stringify({ port: 0, tokens: [] }), 'utf8')
  try {
    return await body(path)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}

test('签发：128 位随机令牌 + 它的 sha256 摘要，且令牌每次不同', () => {
  const first = issueToken({ kind: 'connector', id: 'conn-1' })
  const second = issueToken({ kind: 'connector', id: 'conn-1' })

  assert.match(first.token, /^[A-Za-z0-9_-]{22}$/, '16 字节 base64url')
  assert.equal(first.hash, createHash('sha256').update(first.token, 'utf8').digest('hex'))
  assert.notEqual(first.token, second.token, '每次签发都是新令牌')
})

test('**令牌本体绝不落进配置**（配置是摘要表，不是凭据表）', async () => {
  await withConfig(async (path) => {
    const issued = issueToken({ kind: 'device', id: 'dev-1' })
    await appendTokenToConfig(path, { kind: 'device', id: 'dev-1', hash: issued.hash })

    const written = await readFile(path, 'utf8')
    assert.equal(
      written.includes(issued.token),
      false,
      '配置里出现明文令牌 = §12.2 的"只存摘要"被破坏',
    )
    assert.equal(written.includes(issued.hash), true, '摘要必须在里面')
  })
})

test('追加保留既有条目；同一身份重新签发会**替换**旧摘要（否则旧令牌仍然有效）', async () => {
  await withConfig(async (path) => {
    const connector = issueToken({ kind: 'connector', id: 'conn-1' })
    const device = issueToken({ kind: 'device', id: 'dev-1' })
    await appendTokenToConfig(path, { kind: 'connector', id: 'conn-1', hash: connector.hash })
    await appendTokenToConfig(path, { kind: 'device', id: 'dev-1', hash: device.hash })

    const rotated = issueToken({ kind: 'connector', id: 'conn-1' })
    const tokens = await appendTokenToConfig(path, {
      kind: 'connector',
      id: 'conn-1',
      hash: rotated.hash,
    })
    assert.equal(tokens.length, 2, '两个身份各一条')

    const authenticate = createDigestAuthenticator(tokens)
    assert.deepEqual(authenticate(rotated.token), { kind: 'connector', id: 'conn-1' })
    assert.equal(authenticate(connector.token), undefined, '被替换掉的旧令牌必须失效')
    assert.deepEqual(authenticate(device.token), { kind: 'device', id: 'dev-1' }, '别的身份不受影响')
  })
})
