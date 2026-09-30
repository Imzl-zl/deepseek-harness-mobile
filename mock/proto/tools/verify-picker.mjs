/* 验证模型/等级列表的列对齐:勾选不会把其它列顶走。
   用法: CDP_URL=http://127.0.0.1:9400 node mock/proto/tools/verify-picker.mjs */
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
  throw new Error('no CDP page target')
}
const t = await target()
const ws = new WebSocket(t.webSocketDebuggerUrl)
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej })
let id = 0
const pending = new Map()
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) } }
const send = (m, p = {}) => { const mid = ++id; ws.send(JSON.stringify({ id: mid, method: m, params: p })); return new Promise(r => pending.set(mid, r)) }

await send('Page.enable'); await send('Runtime.enable')
await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true })
await send('Page.navigate', { url: PAGE }); await sleep(1500)

const expr = `(async () => {
  const q = s => document.querySelector(s);
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const T = window.Takeovers; while (T.pending) T.dequeue(); await sleep(400);

  const cols = () => [...document.querySelectorAll('.prow')].map(r => {
    const nm = r.querySelector('.nm').getBoundingClientRect();
    const ck = r.querySelector('.ck').getBoundingClientRect();
    const tags = r.querySelector('.tags');
    const tagBox = tags ? tags.getBoundingClientRect() : null;
    return {
      name: r.querySelector('.nm').textContent,
      checked: !!r.querySelector('.ck svg'),
      nameLeft: Math.round(nm.left),
      nameRight: Math.round(nm.right),
      ckLeft: Math.round(ck.left),
      ckW: Math.round(ck.width),
      tagsOnSecondLine: tagBox ? Math.round(tagBox.top) >= Math.round(nm.bottom) - 2 : null,
    };
  });

  // 打开模型面板
  q('[data-act="pick-model"]').click(); await sleep(500);
  document.querySelector('[data-pk="model"]').click(); await sleep(400);
  const modelCols = cols();

  // 换一个选中项(第一个 → 第三个),看列是否移动
  const rows = [...document.querySelectorAll('.prow[data-pm]')];
  rows[2].click(); await sleep(400);
  document.querySelector('[data-pk="model"]').click(); await sleep(400);
  const modelCols2 = cols();

  // 等级面板
  document.querySelector('[data-pk="root"]')?.click(); await sleep(300);
  document.querySelector('[data-pk="effort"]').click(); await sleep(400);
  const effortCols = cols();

  const colStable = (a, b) => a.length === b.length && a.every((r, i) =>
    r.nameRight === b[i].nameRight && r.ckLeft === b[i].ckLeft);

  return {
    modelCols, modelCols2, effortCols,
    nameAndCheckStableAcrossSelection: colStable(modelCols, modelCols2),
    checkSlotAlwaysPresent: modelCols.every(r => r.ckW > 0),
    checkSlotSameX: new Set(modelCols.map(r => r.ckLeft)).size === 1,
    nameRightSameX: new Set(modelCols.map(r => r.nameRight)).size === 1,
    tagsSitOnSecondLine: modelCols.filter(r => r.tagsOnSecondLine !== null).every(r => r.tagsOnSecondLine),
    effortCheckSameX: new Set(effortCols.map(r => r.ckLeft)).size === 1,
  };
})()`

const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
const v = r.result?.result?.value
if (!v) { console.error(JSON.stringify(r.result, null, 2)); process.exit(1) }
console.log(JSON.stringify(v, null, 2))
const ok = v.nameAndCheckStableAcrossSelection && v.checkSlotAlwaysPresent && v.checkSlotSameX && v.nameRightSameX && v.tagsSitOnSecondLine && v.effortCheckSameX
console.log(ok ? '\nPASS 名称/勾位不因选中移动,标签在第二行' : '\nFAIL 行内布局仍有位移')
ws.close()
process.exit(ok ? 0 : 1)
