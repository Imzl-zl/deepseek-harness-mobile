/* 自动化任务页 + 对话 dock(目标 / 任务清单)截图。
   用法:先 pwsh -File mock/proto/tools/cdp.ps1 -Port 9400,
   再 CDP_URL=http://127.0.0.1:9400 node mock/proto/tools/shoot-tasks.mjs */
import { setTimeout as sleep } from 'node:timers/promises'
import { mkdirSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const CDP = process.env.CDP_URL || 'http://127.0.0.1:9400'
const PAGE = process.env.PAGE_URL || new URL('../index.html', import.meta.url).href
const OUT = fileURLToPath(new URL('../shots', import.meta.url))
mkdirSync(OUT, { recursive: true })
async function target() {
  for (let i = 0; i < 60; i++) {
    try {
      const list = await (await fetch(`${CDP}/json/list`)).json()
      const t = list.find(x => x.type === 'page' && x.webSocketDebuggerUrl)
      if (t) return t
    } catch {}
    await sleep(250)
  }
  throw new Error('no CDP page target')
}
const t = await target()
const ws = new WebSocket(t.webSocketDebuggerUrl)
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej })
let id = 0
const pending = new Map()
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) } }
const send = (method, params = {}) => { const mid = ++id; ws.send(JSON.stringify({ id: mid, method, params })); return new Promise((res) => pending.set(mid, res)) }
const evaluate = async (fn) => send('Runtime.evaluate', { expression: `(${fn.toString()})()`, awaitPromise: true, returnByValue: true })
await send('Page.enable'); await send('Runtime.enable')
await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true })
await send('Page.navigate', { url: PAGE }); await sleep(1500)

async function capture(name) {
  const r = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })
  writeFileSync(`${OUT}/${name}`, Buffer.from(r.result.data, 'base64'))
  console.log(`saved ${name}`)
}
const run = (fn) => evaluate(fn)

/* 对话 dock:目标 + 任务清单(展开) */
await run(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms))
  const T = window.Takeovers
  while (T.pending) T.dequeue()
  await sleep(400)
  document.querySelector('[data-act="todo-toggle"]').click()
  await sleep(300)
})
await capture('20-dock-goal-todo.png')

/* 抽屉底栏(5 项) */
await run(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms))
  document.querySelector('[data-act="todo-toggle"]').click(); await sleep(150)
  document.querySelector('[data-act="drawer-open"]').click(); await sleep(500)
})
await capture('21-drawer-foot.png')

/* 自动化任务:列表 */
await run(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms))
  document.querySelector('[data-act="tasks-open"]').click(); await sleep(550)
})
await capture('22-tasks-list.png')

/* 已开启任务详情(可编辑) */
await run(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms))
  document.querySelector('.task-row[data-status="active"]').click(); await sleep(500)
  const n = document.querySelector('#taskName')
  n.value = '每日构建巡检（含夜间重试）'
  n.dispatchEvent(new Event('input', { bubbles: true }))
  await sleep(250)
})
await capture('23-tasks-detail.png')

/* 已结束任务详情(只读) */
await run(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms))
  document.querySelector('[data-act="task-detail-close"]').click(); await sleep(420)
  document.querySelector('.task-row[data-status="inactive"]').click(); await sleep(500)
})
await capture('24-tasks-detail-readonly.png')

/* 删除确认 */
await run(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms))
  document.querySelector('[data-act="task-delete"]').click(); await sleep(520)
})
await capture('25-tasks-delete-confirm.png')

/* 搜索空态 */
await run(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms))
  document.querySelector('.sheet-scrim').click(); await sleep(420)
  document.querySelector('[data-act="task-detail-close"]').click(); await sleep(420)
  const si = document.querySelector('#tasksSearch')
  si.value = 'zzz-不存在'
  si.dispatchEvent(new Event('input', { bubbles: true }))
  await sleep(300)
})
await capture('26-tasks-empty.png')

ws.close()
