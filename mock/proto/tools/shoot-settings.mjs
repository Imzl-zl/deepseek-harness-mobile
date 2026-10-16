/* 设置页截图:首页 + 通用 + 模型 + 插件。
   用法:先 pwsh -File mock/proto/tools/cdp.ps1 -Port 9410,
   再 CDP_URL=http://127.0.0.1:9410 node mock/proto/tools/shoot-settings.mjs */
import { setTimeout as sleep } from 'node:timers/promises'
import { mkdirSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const CDP = process.env.CDP_URL || 'http://127.0.0.1:9410'
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
async function openSettings() {
  await evaluate(async () => {
    const sleep = ms => new Promise(r => setTimeout(r, ms))
    // 顶栏的 ☰ 在 2026-10-16 去掉了：左抽屉走左缘侧滑（PROTO 里那条就是真实手势）。
    PROTO.openDrawerByEdge(); await sleep(350)
    document.querySelector('[data-act="settings-open"]').click(); await sleep(500)
  })
}
async function capture(name) {
  const r = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })
  writeFileSync(`${OUT}/${name}`, Buffer.from(r.result.data, 'base64'))
  console.log(`saved ${name}`)
}
await openSettings()
await capture('16-settings-home.png')
await evaluate(async () => { const sleep = ms => new Promise(r => setTimeout(r, ms)); document.querySelector('[data-section="general"]').click(); await sleep(350) })
await capture('17-settings-general.png')
await evaluate(async () => { const sleep = ms => new Promise(r => setTimeout(r, ms)); document.querySelector('[data-act="settings-back"]').click(); await sleep(250); document.querySelector('[data-section="models"]').click(); await sleep(350) })
await capture('18-settings-models.png')
await evaluate(async () => { const sleep = ms => new Promise(r => setTimeout(r, ms)); document.querySelector('[data-act="settings-back"]').click(); await sleep(250); document.querySelector('[data-section="plugins"]').click(); await sleep(350) })
await capture('19-settings-plugins.png')
ws.close()
