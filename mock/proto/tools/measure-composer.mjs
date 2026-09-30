/* 量一下输入区控制行的实际几何:左侧组是否真的靠左、发送键是否独占右侧。
   用法: node mock/proto/tools/measure-composer.mjs */
import { setTimeout as sleep } from 'node:timers/promises'

const CDP = process.env.CDP_URL || 'http://127.0.0.1:9400'
const PAGE = process.env.PAGE_URL || 'file:///C:/sudy/myproject/dsh-mobile/mock/proto/index.html'

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

await send('Page.enable'); await send('Runtime.enable')
await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true })
await send('Page.navigate', { url: PAGE })
await sleep(1500)

const expr = `(async () => {
  const q = s => document.querySelector(s);
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const T = window.Takeovers; while (T.pending) T.dequeue(); await sleep(300);
  const R = el => { const b = el.getBoundingClientRect(); return { l: Math.round(b.left), r: Math.round(b.right), w: Math.round(b.width) }; };
  const c = R(q('.composer'));
  const mid = c.l + c.w / 2;
  const tools = [...q('.ctools').children].map(x => ({ id: x.id || x.className, ...R(x) }));
  const sendR = R(q('#send'));
  const rightMostTool = Math.max(...tools.map(x => x.r));
  return {
    composer: c,
    midpoint: Math.round(mid),
    tools,
    send: sendR,
    modelStartsLeftOfMid: R(q('#chipModel')).l < mid,
    toolsEndLeftOfMid: rightMostTool < mid,
    sendOnlyRightControl: q('.ctools').nextElementSibling.id === 'send',
    gapBetweenToolsAndSend: sendR.l - rightMostTool,
    noOverlap: sendR.l >= rightMostTool,
  };
})()`

const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
const v = r.result?.result?.value
if (!v) { console.error(JSON.stringify(r.result, null, 2)); process.exit(1) }
console.log(JSON.stringify(v, null, 2))
ws.close()
