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

import { createDigestAuthenticator, type TokenDigest } from '../src/digest-auth.ts'
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
    const issued = issueToken({ kind: 'connector', id: 'conn-1' })
    await appendTokenToConfig(path, { kind: 'connector', id: 'conn-1', hash: issued.hash })

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
    const other = issueToken({ kind: 'connector', id: 'conn-2' })
    await appendTokenToConfig(path, { kind: 'connector', id: 'conn-1', hash: connector.hash })
    await appendTokenToConfig(path, { kind: 'connector', id: 'conn-2', hash: other.hash })

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
    assert.deepEqual(authenticate(other.token), { kind: 'connector', id: 'conn-2' }, '别的身份不受影响')
  })
})

test('摘要表里出现 device 条目 → 拒绝建表（v2 起中转只签连接器令牌）', () => {
  // 这条是"入口配错就在启动时失败"的单元级判据：带着 device 条目的中转**起来了也连不上**
  // （设备 403），那种半死状态比起不来难查得多。完整启动路径见 server.test.ts 的同名用例。
  //
  // 形状断言绕开类型系统是**故意的**：这些条目来自 `JSON.parse(config)`，而配置是人写的 ——
  // 校验函数的职责正是接住"类型说不可能、文件里却真有"的那种输入。
  const legacyConfig = [
    { kind: 'connector', id: 'conn-1', hash: 'a'.repeat(64) },
    { kind: 'device', id: 'dev-1', hash: 'b'.repeat(64) },
  ] as unknown as TokenDigest[]
  assert.throws(() => createDigestAuthenticator(legacyConfig), /device 条目/)
})
