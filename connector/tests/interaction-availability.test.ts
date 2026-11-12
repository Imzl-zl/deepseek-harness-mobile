/**
 * `interaction.respond` 的**挂载判据**：它服务两类，所以不能只按其中一类挂。
 *
 * ## 为什么这条要读源码
 *
 * 这个判据长在装配闭包里（`src/index.ts`，`ctx.get(...) === undefined` 决定
 * `handlerDeps.interaction` 给不给），而插件层没有"起一个真 ctx"的用例 ——
 * 装配面的既有做法就是**读 `index.ts` 文本**断言（`tests/assembly-wiring.test.ts`），
 * 同一个口径。
 *
 * 内核本身不用在这里重测：`tests/interaction-face.test.ts` 已经钉住了
 * "审批答复落在在途 claim 上"与"不在 claim 里的 `i:` 项回 not-pending"。
 * 这里只守一件事：**没有 `userQuestions` 时，审批的答复入口仍然要挂上**。
 *
 * 2026-11-12 之前它是 `ctx.get('userQuestions') === undefined ? null : …`：
 * 缺提问服务的部署里，审批事件照旧会产生（走 gateway 的 waterfall，
 * 与提问服务无关），而手机每张审批卡都会弹「没发出去，再试一次」，永远答不掉。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

/**
 * 去注释 + 压空白：让断言落在代码上（与 `tests/assembly-wiring.test.ts` 同一份实现）。
 *
 * 只剥块注释与**整行**的 `//` 注释（不碰行尾注释，免得把 `'ws://…'` 这类字符串切坏），
 * 再把连续空白压成一个空格 —— 多行实参因此能用一行正则匹配，普通重排/换行不会假阴。
 */
function codeOf(source: string): string {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/^[ \t]*\/\/.*$/gm, ' ')
    .replace(/\s+/g, ' ')
}

const code = codeOf(readFileSync(new URL('../src/index.ts', import.meta.url), 'utf8'))

test('interaction.respond 的挂载判据包含 approval（同一个方法服务两类）', () => {
  assert.ok(
    /ctx\.get\('userQuestions'\) === undefined && ctx\.get\('approval'\) === undefined \? null : createInteractionFace\(/
      .test(code),
    'interaction.respond 应当"两个来源至少有一个在"就挂：只按 userQuestions 挂会让审批卡永远答不掉',
  )
})

test('两个服务都不在时，交互应答面整块不挂（能力位模型的另一头）', () => {
  // 判据仍然是"缺了就不出现"——上面那条只是把"缺谁"改对了。
  // `if (interactionFace !== null)` 是唯一给 `handlerDeps.interaction` 赋值的地方。
  const assignments = code.match(/handlerDeps\.interaction = /g) ?? []
  assert.equal(assignments.length, 1, 'interaction 面只能有一处装配（两处就是两条真值）')
})
