/* 无头验证:不开 devtools MCP,直接用 CDP 跑一遍关键路径(布局与交互)。
   用法:
     pwsh -File mock/proto/tools/cdp.ps1            # 另开一个终端,拿到端口
     $env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'
     node mock/proto/tools/verify-proto.mjs
   注意:不要用 9222 —— 本机该端口常被日常 Chrome 占用,探测会返回 404。 */
import { setTimeout as sleep } from 'node:timers/promises'

const CDP = process.env.CDP_URL || 'http://127.0.0.1:9400'
const PAGE = process.env.PAGE_URL || new URL('../index.html', import.meta.url).href

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

  // 5) 顶栏:● 连接状态点 → 先弹「连接操作」sheet(表头含"连接");关掉 sheet 后
  //    走**右缘把手**(上半屏往左划)一步开右抽屉。原侧抽屉断言(过渡/遮罩/面板集合/关闭)一条不少。
  const cs = getComputedStyle(q('#pageSide'))
  q('#statusDot').click(); await sleep(320)
  const connSheet = q('.sheet')
  const connSheetOpen = !!connSheet && !!(q('.sheet-h') && q('.sheet-h').textContent.includes('连接'))
  const openSideBtn = connSheet ? [...connSheet.querySelectorAll('.sitem')].find(b => b.textContent.includes('打开侧面板')) : null
  if (q('.sheet-scrim')) { q('.sheet-scrim').click(); await sleep(400) }   // 关掉连接 sheet
  PROTO.openSideByEdge(); await sleep(60)
  const mid = getComputedStyle(q('#pageSide')).transform
  await sleep(500)
  res.side = {
    connSheetOpen,
    // 连接 sheet 顶部的「当前连接」行(连接方式选择器第 1 步,2026-10-16):
    // 一眼能看"走的哪条",不用进设置。
    connSheetShowsCurrent: connSheet ? connSheet.textContent.includes('当前连接') : false,
    sheetHasOpenSide: !!openSideBtn,
    openedByRightEdge: q('#pageSide').classList.contains('is-in'),
    // 右抽屉开着 → 右边那条手势带与"棒棒"整条收起(用户:"侧滑之后棒要消失")。
    edgeHiddenWhileOpen: getComputedStyle(q('#edgeSide')).display === 'none',
    transition: cs.transitionProperty + ' ' + cs.transitionDuration,
    animatedMidway: mid !== 'none' && mid !== '',
    scrimOn: q('#sideScrim').classList.contains('is-on'),
    panels: [...document.querySelectorAll('.stab')].map(s => s.dataset.panel),
  }
  q('#sideScrim').click(); await sleep(450)
  res.side.closedByScrim = !q('#pageSide').classList.contains('is-in')
  res.side.edgeBackAfterClose = getComputedStyle(q('#edgeSide')).display !== 'none'

  // 6) 顶栏限宽 + 计数 chip 行(2026-10-16):标题 ≤ 220px(照 DSH 的 .crumb),
  //    chip 行有才显示,文案与计数口径照 DSH(子智能体报总数、后台任务报在跑数)。
  res.topbar = {
    titleWidth: Math.round(q('.appbar .ttl').getBoundingClientRect().width),
    // 顶栏:左侧 ☰(抽屉入口) / ● 连接状态点 / ⊕ 新建;两边手势带贴最边缘、上半屏 192。
    appbarButtons: [...q('.appbar').querySelectorAll('button')].map(b => b.dataset.act || b.className),
    edgeBands: ['#edgeOpen', '#edgeSide'].map(sel => {
      const e = q(sel)
      const r = e.getBoundingClientRect()
      return {
        sel,
        width: Math.round(r.width),
        height: Math.round(r.height),
        left: Math.round(r.left),
        stick: !!e.querySelector('.edge-stick'),
      }
    }),
    chipsHidden: q('#liveChips').hidden,
    chips: [...q('#liveChips').querySelectorAll('.livechip')].map(b => ({
      text: b.textContent.trim(),
      aria: b.getAttribute('aria-label'),
      spinning: !!b.querySelector('.livechip-dot'),
      opens: b.dataset.act,
    })),
  }

  // 7) 代码块工具条(2026-10-16):默认自动换行,点开关才横滚 ——
  //    照 DSH 的 CodeBlock(`CodeBlock.tsx:157` 的 `useState(true)`)。
  const codeBox = q('#sampleCode')
  const wrapBtn = q('#codeWrap')
  if (codeBox && wrapBtn) {
    codeBox.classList.remove('is-nowrap')
    const wrappedDefault = getComputedStyle(codeBox.querySelector('pre')).whiteSpace
    wrapBtn.click(); await sleep(120)
    res.codeBlock = {
      wrappedDefault,
      togglesToNowrap: codeBox.classList.contains('is-nowrap'),
      wrapLabelAfter: wrapBtn.getAttribute('aria-label'),
    }
    wrapBtn.click(); await sleep(120)   // 还原:下次跑时状态不残留
  }

  res.layers = PROTO.layers
  return res
})

console.log(JSON.stringify(out, null, 2))
ws.close()
