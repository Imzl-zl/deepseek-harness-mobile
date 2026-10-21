/* 会话抽屉的行动作回归（2026-10-21）：
   - 行上只剩「归档」一个左滑动作（DSH 没有删除会话的方法）；
   - 长按开菜单：置顶 / 上移 / 下移 / 归档；
   - 置顶项排在本分组最前，取消置顶回到普通块；
   - 上移/下移不跨置顶分区（与 Web 拖动门禁同一条）。

   用法同 verify-proto.mjs：
     pwsh -File mock/proto/tools/cdp.ps1 -Port 9400
     $env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'
     node mock/proto/tools/verify-drawer.mjs */
import assert from 'node:assert/strict'
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
  /* 页面里没有 node:assert —— 用最小替身，断言失败会以异常回到 Node 侧。 */
  const assert = {
    ok(v, m) { if (!v) throw new Error(m || 'assert.ok failed') },
    equal(a, b, m) { if (a !== b) throw new Error(`${m || 'assert.equal'}: ${a} !== ${b}`) },
  }
  const sleep = (ms) => new Promise(r => setTimeout(r, ms))
  const q = (s) => document.querySelector(s)
  const qa = (s) => [...document.querySelectorAll(s)]
  const res = { errors: [] }
  window.addEventListener('error', e => res.errors.push(e.message))

  const drawerBtn = q('[data-act="drawer-open"]')
  if (drawerBtn) { drawerBtn.click(); await sleep(350) }
  const visibleRows = () => qa('.drow-wrap').filter(w => !w.hidden && w.offsetParent !== null)
  const rowOf = (wrap) => wrap.querySelector('.drow')
  const titleOf = (wrap) => rowOf(wrap).querySelector('.t').textContent
  const pinned = (wrap) => rowOf(wrap).dataset.pinned === '1'
  const order = () => visibleRows().map(titleOf)
  /* 真机上一次长按 = pointerdown → 计时 → pointerup，然后**浏览器还会补一个 click**。
     那个 click 必须被吞掉（app.js 的 `data-longPressed` 守卫）；不模拟它，
     "长按会不会顺带打开会话"这条就永远测不到。 */
  const longPress = async (wrap) => {
    const row = rowOf(wrap)
    row.dispatchEvent(new PointerEvent('pointerdown', { pointerId: 1, clientX: 20, clientY: 20, pointerType: 'touch', bubbles: true }))
    await sleep(520)
    row.dispatchEvent(new PointerEvent('pointerup', { pointerId: 1, clientX: 20, clientY: 20, pointerType: 'touch', bubbles: true }))
    row.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await sleep(120)
  }
  /* 页面内的断言计数：脚本末尾打印的"N 项"必须是真数，不是手写的。 */
  let checks = 0
  const check = (cond, msg) => { checks++; if (!cond) throw new Error(msg) }
  /* 某一行的分区里、按 DOM 顺序的所有行（跨 `.dsec` 不算同一组）。 */
  const sectionRowsOf = (wrap) => {
    let sec = wrap.previousElementSibling
    while (sec && !sec.classList.contains('dsec')) sec = sec.previousElementSibling
    const rows = []
    for (let n = sec && sec.nextElementSibling; n && !n.classList.contains('dsec'); n = n.nextElementSibling) {
      if (n.classList.contains('drow-wrap') && !n.hidden) rows.push(n)
    }
    return rows
  }
  const menuLabels = () => qa('.sheet [data-row-act]').map(b => b.querySelector('.m').textContent.trim())
  const menuButton = (act) => qa('.sheet [data-row-act]').find(b => b.dataset.rowAct === act)
  const closeSheet = async () => {
    const scrim = q('.sheet-scrim')
    if (scrim) scrim.click()
    await sleep(400)
  }

  res.rowActions = [...new Set(qa('.drow-actions button').map(b => b.textContent.trim()))]
  res.hasDeleteAction = qa('.drow-actions .del').length > 0
  res.pinnedAtRest = visibleRows().filter(pinned).map(titleOf)
  res.pinMarkAtRest = qa('.drow .drow-pin').length

  const rows0 = visibleRows()
  const firstPinned = rows0.find(pinned)
  // 上移边界：它是普通块第一条，上一条是置顶。
  const boundaryRow = rows0.find((w, i) => i > 0 && !pinned(w) && pinned(rows0[i - 1]))
  // 下移：同一个分区里必须有下一条普通会话（跨 `.dsec` 不算同组）。
  const sections = qa('.dsec').map((sec) => {
    const rows = []
    let n = sec.nextElementSibling
    while (n && !n.classList.contains('dsec')) {
      if (n.classList.contains('drow-wrap') && !n.hidden) rows.push(n)
      n = n.nextElementSibling
    }
    return rows
  })
  const pairSection = sections.find(s => s.filter(w => !pinned(w)).length >= 2)
  const moveRow = pairSection && pairSection.find(w => !pinned(w))
  check(!!firstPinned, '演示数据里要有一条已置顶会话')
  check(!!boundaryRow, '演示数据里要有"置顶块之后的普通行"')
  check(!!moveRow, '演示数据里要有一个含两条普通会话的分区')

  // 1) 普通行上移：上一条是置顶 —— 跨分区，菜单项存在但**不可用**。
  //    断言落在 `disabled`（行为）而不是内联 opacity（样式）：灰只是一个样子，
  //    "点了不会动"才是这一条要守的东西。
  await longPress(boundaryRow)
  check(!!q('.sheet'), '长按应打开菜单')
  res.menu = menuLabels()
  res.upDisabledAtPinnedBoundary = menuButton('up')?.disabled === true
  check(res.upDisabledAtPinnedBoundary, '跨置顶分区的「上移」必须是 disabled')
  const orderAtBoundary = order()
  await menuButton('up').click()
  await sleep(300)
  check(
    JSON.stringify(order()) === JSON.stringify(orderAtBoundary),
    '点了不可用的「上移」，顺序必须一条不动',
  )
  await closeSheet()

  // 2) 下移：普通行之间可以移动。
  const before = order()
  const i0 = before.indexOf(titleOf(moveRow))
  await longPress(moveRow)
  await menuButton('down').click()
  await sleep(400)
  const after = order()
  res.moveDown = {
    before: before.slice(Math.max(0, i0 - 1), i0 + 2),
    after: after.slice(Math.max(0, i0 - 1), i0 + 2),
    changed: after.indexOf(titleOf(moveRow)) > i0,
  }
  assert.ok(res.moveDown.changed, '下移后这条应排到原下一条之后')

  // 3) 置顶：标记出现，且排到本分组最前（但仍在置顶块里，按 Host 顺序）。
  await longPress(moveRow)
  await menuButton('pin').click()
  await sleep(400)
  {
    // **位置**也要断言，不只是"置顶了"：它必须落在本分组的置顶块里
    // （最后一个置顶行之后就是第一个普通行）。
    const rowsNow = sectionRowsOf(moveRow)
    const idx = rowsNow.indexOf(moveRow)
    const firstUnpinned = rowsNow.findIndex(w => !pinned(w))
    res.pin = {
      pinned: pinned(moveRow),
      mark: !!rowOf(moveRow).querySelector('.drow-pin'),
      indexInSection: idx,
      firstUnpinnedIndex: firstUnpinned,
      sectionTitles: rowsNow.map(titleOf),
    }
    check(res.pin.pinned, '置顶后 data-pinned 应为 1')
    check(res.pin.mark, '置顶后行尾应出现图钉')
    check(idx >= 0 && idx < firstUnpinned, '置顶行必须排在本分组的置顶块里（所有普通行之前）')
  }

  // 4) 取消置顶：标记消失，回到普通块（不再是置顶分区的第一段）。
  await longPress(moveRow)
  await menuButton('pin').click()
  await sleep(400)
  res.unpin = {
    pinned: pinned(moveRow),
    mark: !!rowOf(moveRow).querySelector('.drow-pin'),
    firstRowIsPinned: pinned(visibleRows()[0]),
  }
  check(res.unpin.pinned === false, '取消置顶后 data-pinned 应为 0')
  check(res.unpin.mark === false, '取消置顶后图钉必须消失')
  check(res.unpin.firstRowIsPinned, '取消置顶后第一行仍是原来的置顶项')

  // 5) 归档：行被移出列表。
  const archiveTarget = visibleRows()[1]
  const archiveTitle = titleOf(archiveTarget)
  await longPress(archiveTarget)
  await menuButton('archive').click()
  await sleep(500)
  res.archive = {
    title: archiveTitle,
    gone: !order().includes(archiveTitle),
    count: visibleRows().length,
  }
  check(res.archive.gone, '归档后这一行应从列表消失')

  // 6) 长按的尾巴（合成的 click）不能被当成"打开会话"；
  //    普通单击仍然要能打开。判据用 `body.is-blank`（新会话页开/关的那一档）。
  q('[data-act="new-session"]').click()
  await sleep(200)
  check(document.body.classList.contains('is-blank'), '按 ⊕ 应落到新会话页（blank）')
  const alive = visibleRows().find(w => !pinned(w)) || visibleRows()[0]
  await longPress(alive)
  res.longPressKeptBlank = document.body.classList.contains('is-blank')
  check(res.longPressKeptBlank, '长按后合成的 click 不得把 blank 关掉（等于打开了会话）')
  await closeSheet()
  /* 换一行点：长按那一行的 `data-longPressed` 守卫有 700ms 窗口，
     在窗口内点**同一行**本来就该被吞掉（那正是它的作用）。 */
  const other = visibleRows().find(w => w !== alive)
  rowOf(other || alive).click()
  await sleep(200)
  res.singleClickOpened = !document.body.classList.contains('is-blank')
  check(res.singleClickOpened, '普通单击仍要能打开会话')

  res.checks = checks
  return res
})

let nodeChecks = 0
const check = (cond, msg) => {
  nodeChecks++
  assert.ok(cond, msg)
}
check(
  JSON.stringify(out.rowActions) === JSON.stringify(['归档']),
  '行上只剩「归档」：没有删除会话的 Host 方法',
)
check(
  JSON.stringify(out.menu) === JSON.stringify(['置顶会话', '上移', '下移', '归档']),
  `菜单四项且顺序固定，实际 ${JSON.stringify(out.menu)}`,
)
check(out.hasDeleteAction === false, '左滑不再有「删除」')
check(out.pinnedAtRest.length >= 1, '演示数据里要有一条已置顶会话（否则置顶块没有起点）')
check(out.pin.mark === true && out.pin.pinned === true, '置顶标记与状态都要落')
check(out.unpin.pinned === false && out.unpin.mark === false, '取消置顶要回到普通块')
check(out.longPressKeptBlank === true, '长按的合成 click 被吞掉')
check(out.singleClickOpened === true, '普通单击仍能打开会话')
check(out.errors.length === 0, `页面报错：${out.errors.join('; ')}`)

const total = out.checks + nodeChecks
console.log(JSON.stringify(out, null, 2))
console.log(`\nALL CHECKS PASSED — 抽屉行动作 ${total} 项`)
ws.close()
