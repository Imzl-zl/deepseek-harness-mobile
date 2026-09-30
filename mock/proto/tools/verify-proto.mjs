/* 无头验证:不开 devtools MCP,直接用 CDP 跑一遍关键路径(布局与交互)。
   用法:
     pwsh -File mock/proto/tools/cdp.ps1            # 另开一个终端,拿到端口
     $env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'
     node mock/proto/tools/verify-proto.mjs
   注意:不要用 9222 —— 本机该端口常被日常 Chrome 占用,探测会返回 404。 */
import { setTimeout as sleep } from 'node:timers/promises'

const CDP = process.env.CDP_URL || 'http://127.0.0.1:9400'
const PAGE = process.env.PAGE_URL || 'file:///C:/sudy/myproject/dsh-mobile/mock/proto/index.html'

async function target() {
  for (let i = 0; i < 80; i++) {
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
ws.onmessage = (e) => {
  const m = JSON.parse(e.data)
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) }
}
function send(method, params = {}) {
  const mid = ++id
  ws.send(JSON.stringify({ id: mid, method, params }))
  return new Promise((res) => pending.set(mid, res))
}
async function evalJs(fn, ...args) {
  const r = await send('Runtime.evaluate', {
    expression: `(${fn.toString()})(${args.map(a => JSON.stringify(a)).join(',')})`,
    awaitPromise: true, returnByValue: true,
  })
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails))
  return r.result?.result?.value
}

await send('Page.enable')
await send('Runtime.enable')
await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true })
await send('Page.navigate', { url: PAGE })
await sleep(1400)

const out = await evalJs(async () => {
  const sleep = (ms) => new Promise(r => setTimeout(r, ms))
  const q = (s) => document.querySelector(s)
  const res = { errors: [] }
  window.addEventListener('error', e => res.errors.push(e.message))
  const T = window.Takeovers
  while (T.pending) T.dequeue()
  await sleep(400)

  const rect = (el) => { const b = el.getBoundingClientRect(); return { top: Math.round(b.top), left: Math.round(b.left), right: Math.round(b.right), h: Math.round(b.height) } }

  // 1) 布局顺序:takeover → composer → dock(stats)
  res.order = [...q('.foot').children].map(c => c.id || c.className)
  res.dockBelowComposer = rect(q('.stats')).top >= rect(q('.composer')).top + rect(q('.composer')).h - 2

  // 2) 控制行(手机主流):左边一组 ＋/模型/权限,右边只有发送
  res.tools = [...q('.ctools').children].map(c => c.id || c.className)
  const sendR = rect(q('#send'))
  const composerR = rect(q('.composer'))
  const toolsR = rect(q('.ctools'))
  res.sendIsOnlyRightControl = q('.ctools').nextElementSibling && q('.ctools').nextElementSibling.id === 'send'
  res.sendRightmost = sendR.right >= composerR.right - 12
  res.modelOnLeft = toolsR.left <= composerR.left + 16
  res.noOverflow = toolsR.right <= sendR.left + 1

  // 3) 抽屉搜索:真输入框 + 过滤
  const si = q('#drawerSearch')
  res.searchIsInput = si && si.tagName === 'INPUT'
  const rowsBefore = [...document.querySelectorAll('.drow-wrap')].filter(w => !w.hidden).length
  si.value = 'bridge'; si.dispatchEvent(new Event('input', { bubbles: true })); await sleep(200)
  const rowsAfter = [...document.querySelectorAll('.drow-wrap')].filter(w => !w.hidden).length
  const secsVisible = [...document.querySelectorAll('.dsec')].filter(s => !s.hidden).length
  si.value = 'zzzz-no-such'; si.dispatchEvent(new Event('input', { bubbles: true })); await sleep(200)
  const emptyShown = !q('#drawerEmpty').hidden
  si.value = ''; si.dispatchEvent(new Event('input', { bubbles: true })); await sleep(200)
  const rowsRestored = [...document.querySelectorAll('.drow-wrap')].filter(w => !w.hidden).length
  res.search = { rowsBefore, rowsAfter, secsVisible, emptyShown, rowsRestored }

  // 4) 权限:图标在位 + 风险门能打开(此前的返回栈 bug)
  res.permIcon = !!q('#chipPerm svg')
  q('#chipPerm').click(); await sleep(450)
  const permSheet = q('.sheet-h') ? q('.sheet-h').textContent.trim() : null
  document.querySelector('[data-perm="danger-full-access"]').click(); await sleep(700)
  res.gate = { permSheet, gateTitle: q('.sheet-h') ? q('.sheet-h').textContent.trim() : null, ack: !!q('[data-gate="ack"]') }
  if (q('.sheet')) { q('.sheet-scrim').click(); await sleep(400) }

  // 5) 侧抽屉:过渡 + 遮罩 + 关闭
  const cs = getComputedStyle(q('#pageSide'))
  q('#statusPill').click(); await sleep(60)
  const mid = getComputedStyle(q('#pageSide')).transform
  await sleep(500)
  res.side = {
    transition: cs.transitionProperty + ' ' + cs.transitionDuration,
    animatedMidway: mid !== 'none' && mid !== '',
    scrimOn: q('#sideScrim').classList.contains('is-on'),
    panels: [...document.querySelectorAll('.stab')].map(s => s.dataset.panel),
  }
  q('#sideScrim').click(); await sleep(450)
  res.side.closedByScrim = !q('#pageSide').classList.contains('is-in')

  res.layers = PROTO.layers
  return res
})

console.log(JSON.stringify(out, null, 2))
ws.close()
