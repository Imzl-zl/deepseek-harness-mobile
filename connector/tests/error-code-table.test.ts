/**
 * 错误码是**封闭表**：代码里出现的每一个码都必须写在契约 §3.1 里（反之亦然）。
 *
 * 为什么值得一条门禁：§3.1 按定义是封闭的 —— 手机对每个码都有**确定的**客户端行为
 * （退避重试 / 重配 / 走快照 / 关掉连接…）。代码里冒出一个表外的码，手机就只能猜，
 * 而"猜"的表现是"这个错误之后它什么都没做"。
 *
 * 口径上的一个坑：本仓别处也有 `| \`xxx\` | ... |` 形状的表格（§5.7 的方法表就是），
 * 所以解析**必须限定在 §3.1 这一节内**，否则会把方法名当成错误码。
 * 另外先断言"两侧都抽到了东西"：解析口径坏了要报错，不能被当成"一致"通过。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

const CONTRACT = new URL('../../docs/subsystems/remote-channel.md', import.meta.url)
const ERRORS = new URL('../src/protocol/errors.ts', import.meta.url)

/** 取出 §3.1 这一节的正文（到下一个二级/三级标题为止）。 */
function section31(markdown: string): string {
  const start = markdown.indexOf('### 3.1')
  assert.equal(start >= 0, true, '契约里找不到 §3.1 —— 标题改了就要同步这条门禁')
  const rest = markdown.slice(start)
  const next = rest.slice(3).search(/\n#{2,3} /)
  return next === -1 ? rest : rest.slice(0, next + 3)
}

test('契约 §3.1 的错误码表与代码的 ErrorCode 映射完全一致（封闭表不许单边新增）', () => {
  const declared = new Set<string>()
  for (const match of section31(readFileSync(CONTRACT, 'utf8')).matchAll(/^\|\s*`([a-z][\w/-]+)`\s*\|/gm)) {
    const code = match[1]
    if (code !== undefined) declared.add(code)
  }

  const implemented = new Set<string>()
  // 键**可能没引号**（TS 里 `internal:` 与 `'internal':` 等价）—— 第一版只认带引号的，
  // 于是把 `internal` 漏掉、报出一个**假阳性**，而我差点据此去改本来就对的 `errors.ts`。
  // 教训：断言红的时候先**直接读源码确认**，再决定改哪一边。
  for (const match of readFileSync(ERRORS, 'utf8').matchAll(/^\s*'?([a-z][\w/-]+)'?:\s*'/gm)) {
    const code = match[1]
    if (code !== undefined) implemented.add(code)
  }

  assert.equal(declared.size > 0, true, '没能从 §3.1 抽出任何错误码 —— 先修解析口径，别当成通过')
  assert.equal(implemented.size > 0, true, '没能从 errors.ts 抽出任何错误码 —— 先修解析口径')

  assert.deepEqual(
    [...implemented].sort(),
    [...declared].sort(),
    '封闭表漂移了：代码里新增的码必须同时写进契约 §3.1（并给它一个客户端行为），' +
      '契约里删掉的码必须同时从代码里删 —— 表外的码，手机只能猜',
  )
})
