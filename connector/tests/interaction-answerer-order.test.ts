/**
 * 应答者的**顺序**：接管的判定必须排在任何桌面应答者前面。
 *
 * 这里不是"为了测试造出来的语义"，而是 Cordis 的实测语义
 * （`vendor/cordis/src/events.ts:234-243`）：`waterfall` 按注册顺序从队首依次调用，
 * `next()` 就是 `cbs.shift()`，**谁不调 `next()` 谁把后面全挡掉**
 * （`{ prepend: true }` 插到队首，`:254-257`）。
 *
 * DSH 里真的存在一个"先注册、且自己不回答就不放行"的桌面应答者：
 * `packages/api/remotes/src/index.ts:57-75` 把 `approval/request` 转发给浏览器 GUI
 * （`forwardWaterfall`，`:135-158`），只有在浏览器回"委托"时才 `next()`；
 * 而它**每条 Client 流注册一次**（`packages/api/remotes/README.md:47`），
 * 也就是说浏览器一挂上来就有一条监听器排在当时的队尾。
 *
 * 2026-10-13 真机事故：profile 是 `--no-open`，但用户浏览器里开着 8099 那个 GUI；
 * 连接器的应答者是**异步**注册的（`index.ts:300-303` 的 `register-answerers`
 * 排在 `open-store` 之后），于是那条转发监听器先注册、把审批挂在了**没人点的桌面对话框**上。
 * 会话停在 `approval/asked`，手机点「允许一次」无处可落 —— 排查用的临时文件日志
 * **从未生成**，说明连接器的应答者根本没被问到。
 * 取舍见 `.agents/notes/implemented/2026-10-13-answerer-must-be-prepended.md`。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { registerInteractions } from '../src/dsh/interactions.js'

type Answerer = (request: never, next: () => unknown) => unknown

/** 把事件循环跑到静默：answerer 是 async 的，"注册返回"不等于"已经被问过"。 */
async function settle(): Promise<void> {
  for (let i = 0; i < 16; i += 1) await Promise.resolve()
}

/**
 * 一条按 Cordis 语义排队的瀑布，外加一个"浏览器开着、但没人点"的桌面应答者。
 *
 * 桌面应答者**先注册**（与事故发生时的顺序一致：浏览器在连接器激活前就挂上了），
 * 并且被问到就挂着不回答 —— 正是 `forwardWaterfall` 等浏览器结果的那个形状。
 *
 * **按事件名分派**：Cordis 的 `ctx.on(name, …)` 只把 `name` 的事件送给那条监听器，
 * 所以假瀑布也必须按名字筛。第一版没筛，于是两个应答者都 `prepend` 之后，
 * `approval/request` 被喂给了 `user-questions/request` 的应答者（`questions is not
 * iterable`）—— 那是**假实现的缺陷**，不是被测代码的。
 */
function setupOrderedWaterfall() {
  const hooks: { event: string; handler: Answerer }[] = []
  let desktopAsked = false
  let phoneAsked = 0

  const ctx = {
    on: (event: string, handler: Answerer, options?: { prepend?: boolean }) => {
      const entry = { event, handler }
      if (options?.prepend === true) hooks.unshift(entry)
      else hooks.push(entry)
      return () => {
        const at = hooks.indexOf(entry)
        if (at !== -1) hooks.splice(at, 1)
      }
    },
  }

  // 桌面那一侧（`api-remotes` 就是不带选项的 `ctx.on`）：被问就记一笔，然后永远不回答。
  ctx.on('approval/request', () => {
    desktopAsked = true
    return new Promise(() => {})
  })

  const dispatch = (event: string, request: Record<string, unknown>): void => {
    const queue = hooks.filter((entry) => entry.event === event)
    const next = (): unknown => {
      const cb = queue.shift()
      return cb === undefined ? 'unavailable' : cb.handler(request as never, next)
    }
    void next()
  }

  return {
    ctx,
    dispatch,
    desktopAsked: () => desktopAsked,
    phoneAsked: () => phoneAsked,
    notePhoneAsked: () => {
      phoneAsked += 1
    },
  }
}

const approvalRequest = () => ({
  agent: { id: 'dsh-session-1' },
  callId: 'call-1',
  toolName: 'pwsh',
  signal: new AbortController().signal,
})

/** 注册连接器的应答者，并把它接进上面那条瀑布。 */
function mount(wf: ReturnType<typeof setupOrderedWaterfall>, mode: string) {
  const decisions: string[] = []
  registerInteractions(wf.ctx as never, {
    port: {
      askApproval: () => {
        wf.notePhoneAsked()
        decisions.push('allow-once')
        return Promise.resolve('allow-once' as const)
      },
      askQuestion: () => Promise.reject(new Error('本用例不涉及提问')),
    },
    takeover: {
      mode: () => mode as never,
      devices: () => [{ id: 'dev-1', online: true, pairedAt: 1 }] as never,
      sidOf: () => 'sid_1',
    },
    log: { warn: () => {} },
  } as never)
  return decisions
}

test('接管条件成立时，连接器的应答者必须**先于桌面应答者**被问到', async () => {
  const wf = setupOrderedWaterfall()
  const decisions = mount(wf, 'always')

  wf.dispatch('approval/request', approvalRequest())
  await settle()

  assert.equal(
    wf.phoneAsked(),
    1,
    '接管条件成立却没人问手机 —— 会话会永远停在 approval/asked，手机答了也无处可落',
  )
  assert.deepEqual(decisions, ['allow-once'])
  assert.equal(
    wf.desktopAsked(),
    false,
    '手机已经接管，桌面应答者不该再被问：它会把审批挂在没人点的浏览器对话框上',
  )
})

test('不接管时，`next()` 照旧把审批交回桌面（先问手机不等于挡死桌面）', async () => {
  const wf = setupOrderedWaterfall()
  mount(wf, 'never')

  wf.dispatch('approval/request', approvalRequest())
  await settle()

  assert.equal(wf.phoneAsked(), 0, 'never 档不该打扰手机')
  assert.equal(wf.desktopAsked(), true, '不接管就必须继续往下问 —— 桌面审批不能因此消失')
})
