/**
 * 配置样例的回归（`relay.config.example.json`）。
 *
 * 样例配置最常见的坏法是"看起来对、起不来"（缺字段、字段名拼错、值不合规）——
 * 而这类错误只有**真的起一次**才会暴露。所以这条用例把样例文件当配置启动中继，
 * 断言它进入监听并打印出摘要表条数。
 *
 * 为什么值得单独一条：操作者是照着样例改的；样例坏了，他遇到的是"服务起不来"，
 * 而错误信息指向的是他自己的编辑，不是样例。
 */
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { test } from 'node:test'

import { createDigestAuthenticator } from '../src/digest-auth.ts'
import { startRelay } from '../src/server.ts'

const EXAMPLE = new URL('../relay.config.example.json', import.meta.url)

interface ExampleConfig {
  port: number
  host?: string
  tokens: { kind: 'device' | 'connector'; id: string; hash: string }[]
  rateLimit?: { capacity: number; refillPerSecond: number }
}

test('样例配置能真的把中继起起来（样例坏了，操作者会遇到"服务起不来"）', async (t) => {
  const raw = await readFile(EXAMPLE, 'utf8')
  const config = JSON.parse(raw) as ExampleConfig

  // 前置：样例里的字段必须是中继真正认识的（拼错字段名不会报错，只会静默失效）。
  assert.equal(typeof config.port, 'number')
  assert.equal(Array.isArray(config.tokens), true)
  assert.equal(config.tokens.length > 0, true, 'tokens 为空时中继会拒绝启动（引导路径要先签发）')

  const authenticate = createDigestAuthenticator(config.tokens)
  const relay = await startRelay({
    // 样例里写的是 8787；用例用 0 避免与本机已有服务撞端口（端口本身不是被测性质）。
    port: 0,
    ...(config.host === undefined ? {} : { host: config.host }),
    authenticate,
    ...(config.rateLimit === undefined ? {} : { rateLimit: config.rateLimit }),
  })
  t.after(() => relay.close())

  assert.equal(relay.port > 0, true, '样例配置能让中继监听')
  assert.equal(authenticate.size, config.tokens.length, '样例里的摘要都被装进表')
})
