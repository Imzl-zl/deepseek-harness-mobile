/* 授权矩阵验证:确认"没授权 → 绝不生效",以及"授权一次 ≠ 永久授权"。
   用法: node mock/proto/tools/verify-authz.mjs
   前置: 一个 --remote-debugging-port=9334 的 headless Chrome(见 cdp.ps1。 */
import { setTimeout as sleep } from 'node:timers/promises'

const CDP = process.env.CDP_URL || 'http://127.0.0.1:9400'
const PAGE = process.env.PAGE_URL || new URL('../index.html', import.meta.url).href

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
ws.onmessage = (e) => {
  const m = JSON.parse(e.data)
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) }
}
const send = (method, params = {}) => {
  const mid = ++id
  ws.send(JSON.stringify({ id: mid, method, params }))
  return new Promise((res) => pending.set(mid, res))
}
async function evalJs(fn) {
  const r = await send('Runtime.evaluate', { expression: `(${fn.toString()})()`, awaitPromise: true, returnByValue: true })
  const ex = r.result?.exceptionDetails
  if (ex) throw new Error(ex.exception?.description || JSON.stringify(ex))
  return r.result?.result?.value
}

await send('Page.enable'); await send('Runtime.enable')
await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true })
await send('Page.navigate', { url: PAGE })
await sleep(1500)

const out = await evalJs(async () => {
  const sleep = (ms) => new Promise(r => setTimeout(r, ms))
  const q = (s) => document.querySelector(s)
  const T = window.Takeovers
  const R = []
  const rec = (name, pass, detail) => R.push({ check: name, pass: !!pass, detail })
  const sheetActs = () => [...document.querySelectorAll('[data-sheet-act]')]
  const enableBtn = () => sheetActs()[sheetActs().length - 1]
  const gateOpen = () => !!(q('.sheet') && q('[data-gate="ack"]'))
  while (T.pending) T.dequeue()
  const reset = async (perm) => { T.setPermission(perm); await sleep(150); while (T.pending) T.dequeue(); await sleep(150) }

  /* 1) 未勾选风险确认 → 点"启用"必须无效 */
  await reset('workspace-write')
  q('#chipPerm').click(); await sleep(450)
  q('[data-perm="danger-full-access"]').click(); await sleep(650)
  rec('风险门能打开', gateOpen())
  enableBtn().click(); await sleep(500)
  rec('未勾选就点启用 → 权限不变', T.permission === 'workspace-write', T.permission)
  rec('未勾选就点启用 → 门仍开着', gateOpen())
  rec('未勾选就点启用 → sheet 层没被误关', PROTO.layers.join() === 'sheet', PROTO.layers.join())

  /* 2) 勾选后点"取消" → 必须无效 */
  q('[data-gate="ack"]').click(); await sleep(200)
  sheetActs()[0].click(); await sleep(600)
  rec('勾选后点取消 → 权限不变', T.permission === 'workspace-write', T.permission)
  rec('取消后 sheet 关闭', !q('.sheet'))

  /* 3) 勾选状态不得跨次残留 */
  q('#chipPerm').click(); await sleep(450)
  q('[data-perm="danger-full-access"]').click(); await sleep(650)
  const chk = q('[data-gate-chk]')
  rec('重新打开风险门 → 勾选态已重置', !chk.classList.contains('is-on'))
  enableBtn().click(); await sleep(400)
  rec('上一次的勾选不残留(点启用仍无效)', T.permission === 'workspace-write', T.permission)

  /* 4) 勾选 + 启用 → 才生效 */
  q('[data-gate="ack"]').click(); await sleep(200)
  enableBtn().click(); await sleep(650)
  rec('勾选并启用 → 权限生效', T.permission === 'danger-full-access', T.permission)
  rec('危险档图标有告警态', q('#chipPerm').classList.contains('is-warn'))

  /* 5) 完全权限下不再逐步确认(这是"已授权"的结果,不是绕过) */
  const a1 = T.enqueue({ kind: 'approval', toolName: 'bash', detailHtml: '' })
  rec('完全权限:审批不入队', a1 === false && T.pending === 0, 'accepted=' + a1 + ' pending=' + T.pending)

  /* 6) 回到安全档 → 越权调用必须重新要授权 */
  await reset('workspace-write')
  const a2 = T.enqueue({ kind: 'approval', toolName: 'bash', detailHtml: '' })
  rec('安全档:越权调用重新入队等审批', a2 === true && T.pending === 1, 'accepted=' + a2 + ' pending=' + T.pending)
  const rejectBtn = q('[data-tk="reject"]')
  rec('审批卡出现(拒绝/允许一次)', !!rejectBtn && !!q('[data-tk="allow"]'))
  rejectBtn.click(); await sleep(700)
  rec('拒绝后队列清空', T.pending === 0, 'pending=' + T.pending)
  rec('拒绝产生回执节点', [...document.querySelectorAll('.qreply')].some(n => n.textContent.includes('已拒绝')))

  /* 7) 允许一次 = 只对这一次,下一次仍要问 */
  const a3 = T.enqueue({ kind: 'approval', toolName: 'write', detailHtml: '' })
  q('[data-tk="allow"]').click(); await sleep(700)
  const a4 = T.enqueue({ kind: 'approval', toolName: 'write', detailHtml: '' })
  rec('"允许一次"后,下一次仍重新要授权', a3 === true && a4 === true && T.pending === 1, 'pending=' + T.pending)
  while (T.pending) T.dequeue(); await sleep(200)

  /* 8) 提问/计划:不回答就不推进 */
  await reset('workspace-write')
  T.demo.question(); await sleep(300)
  const before = T.pending
  rec('提问入队,未回答时队列不减', before === 1, 'pending=' + before)
  q('[data-tk="dismiss"]').click(); await sleep(400)
  rec('放弃整组问题后才出队', T.pending === 0)

  PROTO.closeSheet?.()
  return { checks: R, failed: R.filter(x => !x.pass).length, permission: T.permission, layers: PROTO.layers }
})

const pad = (s, n) => String(s).padEnd(n)
console.log('\n授权矩阵验证\n' + '='.repeat(78))
for (const c of out.checks) console.log(`${c.pass ? 'PASS' : 'FAIL'}  ${pad(c.check, 40)} ${c.detail ?? ''}`)
console.log('='.repeat(78))
console.log(`失败 ${out.failed} 项 / 共 ${out.checks.length} 项;残留 permission=${out.permission}, layers=[${out.layers}]`)
ws.close()
process.exit(out.failed === 0 ? 0 : 1)
