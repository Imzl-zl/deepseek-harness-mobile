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

  // 6) 顶栏**一行**(2026-10-17):标题 ≤ 140px / 13px(形态同 DSH 的 .crumb,
  //    手机收窄一档),计数 chip **与标题同一行**(DSH 的 header actions band,
  //    ConversationSession.tsx:127-129),只显"图标 + 计数"、全文本退进 aria/title,
  //    有才显示。计数口径照 DSH:子智能体报总数、后台任务报在跑数。
  const ttl = q('.appbar .ttl')
  const ttlRect = ttl.getBoundingClientRect()
  const chipRects = [...q('#liveChips').querySelectorAll('.livechip')]
    .map(b => b.getBoundingClientRect())
  res.topbar = {
    titleWidth: Math.round(ttlRect.width),
    titleFontSize: getComputedStyle(ttl).fontSize,
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
    chipsInAppBar: !!q('.appbar #liveChips'),
    // "同一行"的判据是**纵向中心对齐**（顶栏 `align-items: center`）——
    // 不用"落在标题的矩形里"：标题是一行 13px 文字（约 16px 高），
    // 而 chip 是 28px 的胶囊，包含关系永远不成立。
    chipsSameRowAsTitle: chipRects.every(r =>
      Math.abs((r.top + r.bottom) / 2 - (ttlRect.top + ttlRect.bottom) / 2) <= 4),
    chips: [...q('#liveChips').querySelectorAll('.livechip')].map(b => ({
      text: b.textContent.trim(),
      aria: b.getAttribute('aria-label'),
      spinning: !!b.querySelector('.livechip-dot'),
      opens: b.dataset.act,
    })),
  }

  // 6b) 统计条:单行 + 横向滚动(2026-10-17 定案)。
  //     不滚的 Row 会把末项**整块裁掉**(2026-10-17 前"上下文百分比不显示"就是这么来的),
  //     换行又让"哪一项掉到第二行"随数字漂;横滚时读数滑得到。
  const stats = q('.stats')
  const statRects = [...stats.querySelectorAll('.stat')].map(s => s.getBoundingClientRect())
  res.stats = {
    flexWrap: getComputedStyle(stats).flexWrap,
    overflowX: getComputedStyle(stats).overflowX,
    oneRow: statRects.every(r => Math.abs(r.top - statRects[0].top) < 1),
    allVisible: statRects.every(r => r.width > 0 && r.height > 0),
    overflows: stats.scrollWidth > stats.clientWidth,
    turnText: (q('#statTurn')?.textContent || '').trim(),
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

  // 8) 新会话页(blank)的 hero(2026-10-17 定案)。**放在最后**:它会把 `#msgs` 藏起来,
  //    而前面几段要量消息流里的东西。
  //    DSH 的"刚连上落到的第一屏"是**已有会话但它是 blank**
  //    (`ConversationMainPanel.tsx:41-43`),不是空态;手机端落到 blank 会话就显示 hero。
  const heroEl = q('#convHero')
  const hiddenByDefault = heroEl.hidden
  const normalPlaceholder = q('#input').placeholder
  q('[data-act="new-session"]').click()
  await sleep(220)
  const heroRect = heroEl.getBoundingClientRect()
  const composerRect = q('.composer').getBoundingClientRect()
  const hchips = [...heroEl.querySelectorAll('.hchip')].map(c => {
    const r = c.getBoundingClientRect()
    const fish = heroEl.querySelector('.hero-fish svg')
    return {
      label: (c.querySelector('.lbl') || {}).textContent?.trim(),
      height: Math.round(r.height),
      top: Math.round(r.top),
      left: Math.round(r.left),
      opens: c.dataset.act,
      _fish: fish ? fish.getBoundingClientRect().width : 0,
    }
  })
  const fishRect = heroEl.querySelector('.hero-fish svg')
  res.hero = {
    hiddenByDefault,
    visible: !heroEl.hidden,
    // blank 期没有内容区(DSH 的 `DefaultConversationViews.tsx:32` 直接 return null)
    msgsHidden: q('#msgs').hidden,
    placeholder: q('#input').placeholder,
    headline: (heroEl.querySelector('.hero-ttl') || {}).textContent?.trim(),
    badge: (heroEl.querySelector('.hero-badge') || {}).textContent?.trim(),
    fishWidth: fishRect ? Math.round(fishRect.getBoundingClientRect().width) : 0,
    titleFontSize: getComputedStyle(q('.hero-ttl')).fontSize,
    badgeFontFamily: getComputedStyle(q('.hero-badge')).fontFamily,
    chips: hchips.map(({ _fish, ...rest }) => rest),
    // 两枚 chip **同一行**(DSH 的 `.heroWorkspaceRow`,AgentPresetSeat 与它同形)
    chipsSameRow: hchips.length === 2 && Math.abs(hchips[0].top - hchips[1].top) <= 1,
    // hero 在输入卡片**上方** —— 与 DSH 的 composerStack(标题 → chip 行 → 卡片)同一个叠法
    aboveComposer: Math.round(heroRect.bottom) <= Math.round(composerRect.top) + 1,
  }
  // 两枚 chip 各自开一个选择器;选完名字要真的变(点了没反应 = 假入口)
  q('#heroPreset').click(); await sleep(200)
  const presetRows = [...document.querySelectorAll('.sitem[data-act="hero-preset-set"]')]
  res.hero.presetSheetRows = presetRows.map(b => b.querySelector('.m').firstChild.textContent.trim())
  if (presetRows.length > 1) { presetRows[presetRows.length - 1].click(); await sleep(220) }
  res.hero.presetLabelAfter = (q('#heroPresetLabel') || {}).textContent?.trim()
  q('#heroWorkspace').click(); await sleep(200)
  const wsRows = [...document.querySelectorAll('.sitem[data-act="hero-workspace-set"]')]
  res.hero.workspaceSheetRows = wsRows.map(b => b.querySelector('.m').firstChild.textContent.trim())
  if (wsRows.length > 1) { wsRows[wsRows.length - 1].click(); await sleep(220) }
  res.hero.workspaceLabelAfter = (q('#heroWorkspaceLabel') || {}).textContent?.trim()
  // 打开一行**有内容的**会话 = 离开 blank 那一屏(真机同理:hero 让位给消息流)
  const drawerBtn = q('[data-act="drawer-open"]')
  if (drawerBtn) { drawerBtn.click(); await sleep(300) }
  const drow = q('#dlist .drow')
  if (drow) { drow.click(); await sleep(300) }
  res.hero.placeholderAfterOpen = q('#input').placeholder
  res.hero.visibleAfterOpen = !q('#convHero').hidden
  res.hero.normalPlaceholder = normalPlaceholder

  res.layers = PROTO.layers
  return res
})

// 有断言的判据:探针跑完要**自己说不合格**,否则"跑过了"看起来永远像"没问题"。
// 断言口径与 app/test/{widget,topbar_chips,stats_bar_layout}_test.dart 同源。
const failures = []
const check = (ok, label) => { if (!ok) failures.push(label) }

check(out.errors.length === 0, `页面无 JS 错误（${out.errors.join(' / ')}）`)
check(out.topbar.titleWidth <= 140, `标题限宽 ≤140（实测 ${out.topbar.titleWidth}px）`)
check(out.topbar.titleFontSize === '13px', `标题字号 13px（实测 ${out.topbar.titleFontSize}）`)
check(out.topbar.chipsInAppBar, '计数 chip 在顶栏里（不是另起一行）')
check(out.topbar.chipsSameRowAsTitle, '计数 chip 与标题同一行')
check(out.topbar.chips.every(c => !/个(子智能体|后台任务)/.test(c.text)), 'chip 可见文案只有计数（全文本退进 aria）')
check(out.topbar.chips.every(c => /个(子智能体|后台任务)/.test(c.aria || '')), 'chip 的 aria 带 DSH 的全文本')
check(out.stats.flexWrap === 'nowrap', `统计条单行（flex-wrap: ${out.stats.flexWrap}）`)
check(out.stats.oneRow, '三项读数排在同一行')
check(out.stats.overflowX === 'auto', `统计条可横滚（overflow-x: ${out.stats.overflowX}）`)
check(out.stats.allVisible, '三项读数都渲染出来了（不是被裁成 0 宽）')
check(!/^第/.test(out.stats.turnText), `轮次格逐字照 DSH 的 stats.counts（实测 "${out.stats.turnText}"）`)

// 新会话页(blank)的 hero。口径与 app/test/conversation_hero_test.dart 同源。
check(out.hero.hiddenByDefault, '默认不显示 hero（演示会话是有内容的，blank 才显示）')
check(out.hero.visible, '按 ⊕ 新建 → 落到 blank 会话 → 显示 hero')
check(out.hero.msgsHidden, 'blank 期没有内容区（DSH DefaultConversationViews.tsx:32 返回 null）')
check(out.hero.placeholder === '描述你想要构建的内容, / 调用指令, @ 文件或对话',
  `占位符是 placeholder.hero 那句（实测 "${out.hero.placeholder}"）`)
check(out.hero.headline === '探索未至之境', `标题逐字照 hero.headline（实测 "${out.hero.headline}"）`)
check(out.hero.badge === '预览版', `徽标逐字照 hero.preview（实测 "${out.hero.badge}"）`)
check(Math.round(out.hero.fishWidth) === 34, `鱼宽 34（DSH EmptyHero.tsx:104-105，实测 ${out.hero.fishWidth}）`)
check(out.hero.titleFontSize === '24px', `标题 24px（触屏重算，实测 ${out.hero.titleFontSize}）`)
check(/mono|SF Mono/i.test(out.hero.badgeFontFamily), `徽标用等宽字体（实测 ${out.hero.badgeFontFamily}）`)
check(out.hero.chips.length === 2, `两枚 chip（工作区 + 模式，实测 ${out.hero.chips.length}）`)
check(out.hero.chips.every(c => c.height >= 44), `chip 高 ≥44（可点下限，实测 ${out.hero.chips.map(c => c.height).join('/')}）`)
check(out.hero.chipsSameRow, '两枚 chip 同一行（AgentPresetSeat 与 workspace 同形）')
check(out.hero.aboveComposer, 'hero 在输入卡片上方（DSH composerStack 的叠法）')
check(out.hero.presetSheetRows.length === 4, `预设选择器列出四档（实测 ${out.hero.presetSheetRows.join('/')}）`)
check(out.hero.presetLabelAfter === '创造模式', `选完预设 chip 的名字真的变（实测 "${out.hero.presetLabelAfter}"）`)
check(out.hero.workspaceLabelAfter === 'deepseek-harness', `选完工作区 chip 的名字真的变（实测 "${out.hero.workspaceLabelAfter}"）`)
check(out.hero.visibleAfterOpen === false, '打开有内容的会话 → 离开 blank 那一屏')
check(out.hero.placeholderAfterOpen === out.hero.normalPlaceholder, '离开 hero 后占位符换回普通那句')

console.log(JSON.stringify(out, null, 2))
ws.close()

if (failures.length) {
  console.error(`\nFAIL — ${failures.length} 条不合格:`)
  for (const f of failures) console.error('  ✗ ' + f)
  process.exit(1)
}
console.log(`\nALL CHECKS PASSED — 顶栏与统计条 ${13} 项 + 新会话页 hero ${18} 项`)

