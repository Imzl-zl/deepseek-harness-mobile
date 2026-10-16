/* 截图:用 CDP 拍当前原型的关键状态,存到 mock/proto/shots/。
   用法: node mock/proto/tools/shoot.mjs
   前置: 一个 --remote-debugging-port=9340 的 headless Chrome。 */
import { setTimeout as sleep } from 'node:timers/promises'
import { writeFileSync, mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const CDP = process.env.CDP_URL || 'http://127.0.0.1:9400'
const PAGE = process.env.PAGE_URL || new URL('../index.html', import.meta.url).href
const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', 'shots')
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
  throw new Error('no CDP page target on ' + CDP)
}
const t = await target()
const ws = new WebSocket(t.webSocketDebuggerUrl)
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej })
let id = 0
const pending = new Map()
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) } }
const send = (method, params = {}) => { const mid = ++id; ws.send(JSON.stringify({ id: mid, method, params })); return new Promise((res) => pending.set(mid, res)) }
const evalJs = async (fn) => (await send('Runtime.evaluate', { expression: `(${fn.toString()})()`, awaitPromise: true, returnByValue: true })).result?.result?.value

await send('Page.enable'); await send('Runtime.enable')
async function viewport(w, h, landscape = false) {
  await send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 3, mobile: true, screenOrientation: { type: landscape ? 'landscapePrimary' : 'portraitPrimary', angle: landscape ? 90 : 0 } })
}
async function shot(name) {
  const r = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })
  writeFileSync(join(OUT, name), Buffer.from(r.result.data, 'base64'))
  console.log('saved', name)
}
async function load() {
  await send('Page.navigate', { url: PAGE })
  await sleep(1500)
}

await viewport(390, 844)
await load()

/* 1 对话页:输入区(控制行 + dock) */
await evalJs(async () => {
  const T = window.Takeovers
  while (T.pending) T.dequeue()
  T.setPermission('workspace-write')
  await new Promise(r => setTimeout(r, 300))
  document.querySelector('#msgs').scrollTop = document.querySelector('#msgs').scrollHeight
  await new Promise(r => setTimeout(r, 300))
})
await shot('01-chat-composer.png')

/* 2 输入区带附件 */
await evalJs(async () => {
  const q = s => document.querySelector(s)
  q('[data-act="attach"]').click(); await new Promise(r => setTimeout(r, 350))
  document.querySelector('[data-att="image"]').click(); await new Promise(r => setTimeout(r, 400))
  q('[data-act="attach"]').click(); await new Promise(r => setTimeout(r, 350))
  document.querySelector('[data-att="file"]').click(); await new Promise(r => setTimeout(r, 300))
  q('#input').value = '把这两个附件一起看一下'
  q('#input').dispatchEvent(new Event('input', { bubbles: true }))
  q('#msgs').scrollTop = q('#msgs').scrollHeight
  await new Promise(r => setTimeout(r, 400))
})
await shot('02-composer-attachments.png')

/* 3 左抽屉:真搜索框 + 过滤 */
await evalJs(async () => {
  const q = s => document.querySelector(s)
  q('#attachRail').innerHTML = ''; q('#attachRail').hidden = true
  q('#input').value = ''; q('#input').dispatchEvent(new Event('input', { bubbles: true }))
  const mk = (el, t, x, y) => el.dispatchEvent(new PointerEvent(t, { pointerId: 7, pointerType: 'touch', isPrimary: true, bubbles: true, cancelable: true, clientX: x, clientY: y, buttons: t === 'pointerup' ? 0 : 1 }))
  const edge = q('#edgeOpen')
  mk(edge, 'pointerdown', 10, 400); await new Promise(r => setTimeout(r, 14))
  for (let i = 1; i <= 8; i++) { mk(edge, 'pointermove', 10 + 280 * i / 8, 400); await new Promise(r => setTimeout(r, 14)) }
  mk(edge, 'pointerup', 290, 400)
  await new Promise(r => setTimeout(r, 500))
})
await shot('03-drawer-search.png')

/* 4 右抽屉:任务面板 */
await evalJs(async () => {
  const q = s => document.querySelector(s)
  q('#scrim').click(); await new Promise(r => setTimeout(r, 450))
  // 顶栏 ▷ 右抽屉按钮一步进入(2026-10-16 起右抽屉入口是自己的按钮,
  // 连接状态点只弹「连接操作」sheet —— 见 app.js 的 side-open / status-open)
  q('#sideOpen').click(); await new Promise(r => setTimeout(r, 500))
  const tab = q('.stab[data-panel="jobs"]'); if (tab && !tab.classList.contains('is-on')) { tab.click(); await new Promise(r => setTimeout(r, 400)) }
})
await shot('04-side-jobs.png')

/* 5 审批接管卡 */
await evalJs(async () => {
  const q = s => document.querySelector(s)
  q('#sideScrim').click(); await new Promise(r => setTimeout(r, 450))
  const T = window.Takeovers
  while (T.pending) T.dequeue()
  T.enqueue({ kind: 'approval', toolName: 'bash', detailHtml: '<div class="tk-cmd"><span class="dim">$</span> rm -rf build/ && flutter clean\n<span class="dim">cwd</span> D:\\\\sudy\\\\myproject\\\\dsh-mobile\\\\app</div>' })
  await new Promise(r => setTimeout(r, 500))
})
await shot('05-approval-takeover.png')

/* 6 提问向导(多选态) */
await evalJs(async () => {
  const T = window.Takeovers
  while (T.pending) T.dequeue()
  T.demo.question(); await new Promise(r => setTimeout(r, 400))
  const q = s => document.querySelector(s)
  q('[data-tk="skip"]').click(); await new Promise(r => setTimeout(r, 300))
  q('.opt[data-opt]').click(); await new Promise(r => setTimeout(r, 200))
  document.querySelectorAll('.opt[data-opt]')[2].click(); await new Promise(r => setTimeout(r, 300))
})
await shot('06-question-wizard.png')

/* 7 权限风险门 */
await evalJs(async () => {
  const T = window.Takeovers
  while (T.pending) T.dequeue()
  await new Promise(r => setTimeout(r, 300))
  const q = s => document.querySelector(s)
  q('#chipPerm').click(); await new Promise(r => setTimeout(r, 450))
  q('[data-perm="danger-full-access"]').click(); await new Promise(r => setTimeout(r, 700))
})
await shot('07-permission-gate.png')

/* 8 横屏:右抽屉里的 diff */
await evalJs(async () => { const q = s => document.querySelector(s); if (q('.sheet')) { q('.sheet-scrim').click(); await new Promise(r => setTimeout(r, 400)) } })
await viewport(844, 390, true)
await load()
await evalJs(async () => {
  const T = window.Takeovers
  while (T.pending) T.dequeue()
  await new Promise(r => setTimeout(r, 300))
  window.PROTO.openFile('app/lib/ui/chat_page.dart')
  await new Promise(r => setTimeout(r, 600))
})
await shot('08-landscape-diff.png')

ws.close()
console.log('done ->', OUT)
