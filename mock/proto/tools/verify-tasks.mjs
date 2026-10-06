/* 对话 dock(目标 / 任务清单)与自动化任务页回归。
   用法:
     pwsh -File mock/proto/tools/cdp.ps1 -Port 9400     # 另开一个终端
     $env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'
     node mock/proto/tools/verify-tasks.mjs
   覆盖:
     - 目标:暂停 / 恢复 / 内联编辑(空值被拒)/ 清除 / 再显示;动作都如实标注需 bridge
     - 任务清单:只读(无逐项停止删除)、默认收起、进度计数、三态
     - 自动化任务页:入口、筛选三档、搜索与三种空态、行内频率与下次计划时间、
       详情可编辑(名称/内容)、已结束整块只读、删除确认文案与取消/确认
     - 抽屉底栏在 320px 下不溢出(新增第 5 个入口后的回归点)
   依据:DSH `ui-goal/src/client/GoalBar.tsx`、`ui-conversation/src/client/skeleton/TodoPanel.tsx`、
   `ui-schedule/src/client/TaskManagerPage.tsx` / `TaskDetail.tsx` / `task-manager-locales.ts`。 */
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
async function evalJs(fn) {
  const r = await send('Runtime.evaluate', {
    expression: `(${fn.toString()})()`,
    awaitPromise: true, returnByValue: true,
  })
  if (r.result?.exceptionDetails) throw new Error(r.result.exceptionDetails.exception?.description || 'runtime exception')
  return r.result?.result?.value
}
const viewport = (width, height) => send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 3, mobile: true })

await send('Page.enable')
await send('Runtime.enable')
await viewport(390, 844)
await send('Page.navigate', { url: PAGE })
await sleep(1500)

const main = await evalJs(async () => {
  const sleep = (ms) => new Promise(r => setTimeout(r, ms))
  const q = (s) => document.querySelector(s)
  const out = { checks: [], errors: [] }
  window.addEventListener('error', e => out.errors.push(e.message))
  const pass = (name, value, detail = '') => out.checks.push({ name, pass: !!value, detail: detail === '' ? (value === true ? '' : String(value)) : detail })
  const toastText = () => (q('.toast') ? q('.toast').textContent.trim() : '')
  const rows = () => [...document.querySelectorAll('.task-row')]
  const sheetBtns = () => [...document.querySelectorAll('.sheet [data-sheet-act]')]
  const activeRow = () => rows().find(r => r.dataset.status === 'active')
  const inactiveRow = () => rows().find(r => r.dataset.status === 'inactive')
  /* 逐项数标签行数:换行后不横向溢出,只测 scrollWidth 会静默放过 */
  const labelLines = (el) => {
    const node = [...el.childNodes].find(n => n.nodeType === 3 && n.textContent.trim())
    if (!node) return 0
    const range = document.createRange()
    range.selectNodeContents(node)
    return range.getClientRects().length
  }

  const T = window.Takeovers
  while (T.pending) T.dequeue()
  await sleep(400)

  /* ---------------------------------------------------------- 目标 dock */
  pass('目标 dock 挂在输入区上方', !!q('#goalDock .goal-dock'))
  pass('目标显示"进行中的目标"', q('#goalDock .goal-state').textContent.trim() === '进行中的目标')
  q('[data-act="goal-pause"]').click(); await sleep(160)
  pass('目标可暂停且标注需 bridge',
    q('#goalDock .goal-state').textContent.trim() === '已暂停的目标' && /bridge goals\.pause/.test(toastText()), toastText())
  q('[data-act="goal-resume"]').click(); await sleep(160)
  pass('目标可恢复且标注需 bridge',
    q('#goalDock .goal-state').textContent.trim() === '进行中的目标' && /bridge goals\.resume/.test(toastText()), toastText())
  q('[data-act="goal-edit"]').click(); await sleep(160)
  pass('目标可进入内联编辑', !!q('#goalEditInput'))
  q('#goalEditInput').value = ''
  q('[data-act="goal-edit-save"]').click(); await sleep(160)
  pass('空目标被拒且留在编辑态', !!q('#goalEditInput') && toastText() === '目标内容不能为空', toastText())
  q('#goalEditInput').value = '手机端设置页与自动化任务收尾'
  q('[data-act="goal-edit-save"]').click(); await sleep(160)
  pass('目标可编辑保存',
    q('#goalDock .goal-objective').textContent.trim() === '手机端设置页与自动化任务收尾' && !q('#goalEditInput'))
  q('[data-act="goal-clear"]').click(); await sleep(160)
  pass('目标可清除', /没有目标/.test(q('#goalDock').textContent) && !q('#goalDock .goal-actions'))
  q('[data-act="goal-reopen"]').click(); await sleep(160)
  pass('清除后可重新显示', !!q('#goalDock .goal-actions'))

  /* ---------------------------------------------------------- 任务清单 */
  pass('任务清单默认收起', !!q('#todoDock .todo-head') && !q('#todoDock .todo-list'))
  pass('任务清单进度计数',
    q('#todoDock .todo-progress').textContent.replace(/\s+/g, ' ').trim() === '1 完成 · 1 进行中 · 1 待办',
    q('#todoDock .todo-progress').textContent.trim())
  q('[data-act="todo-toggle"]').click(); await sleep(160)
  const items = [...document.querySelectorAll('#todoDock .todo-item')]
  pass('任务清单可展开', items.length === 3, String(items.length))
  pass('任务清单三态齐全',
    ['completed', 'in_progress', 'pending'].every(s => items.some(i => i.dataset.status === s)))
  pass('任务清单是只读进度(无逐项停止/删除)', items.every(i => !i.querySelector('button')))
  q('[data-act="todo-toggle"]').click(); await sleep(160)
  pass('任务清单可收起', !q('#todoDock .todo-list'))

  /* ---------------------------------------------------------- 入口 + 列表 */
  q('[data-act="drawer-open"]').click(); await sleep(460)
  const foot = q('.drawer-foot')
  const footItems = [...foot.children]
  pass('左抽屉有自动化任务入口', !!q('.drawer-foot [data-act="tasks-open"]'))
  pass('入口用 DSH 的时钟轮廓图标', !!q('.drawer-foot [data-act="tasks-open"] svg'))
  pass('抽屉底栏 5 项不溢出且不换行',
    foot.scrollWidth <= foot.clientWidth + 1 && footItems.every(b => b.getBoundingClientRect().height <= 60),
    `scroll=${foot.scrollWidth} client=${foot.clientWidth} h=${footItems.map(b => Math.round(b.getBoundingClientRect().height)).join(',')}`)

  q('[data-act="tasks-open"]').click(); await sleep(560)
  pass('自动化任务页打开且压入一层', q('#pageTasks').classList.contains('is-in') && PROTO.layers.join('>') === 'tasks', PROTO.layers.join('>'))
  pass('切页时左抽屉已收起(不留幽灵层)',
    PROTO.drawer.p === 0 && !q('#app').classList.contains('drawer-open') && !PROTO.layers.includes('drawer'),
    `p=${PROTO.drawer.p} layers=${PROTO.layers.join('>')}`)
  pass('页面标题为"自动化任务"', q('#pageTasks h1').textContent.trim() === '自动化任务')
  pass('筛选三档文案照 DSH',
    [...document.querySelectorAll('.tasks-filter')].map(b => b.textContent.trim()).join('/') === '全部/已开启/已结束')
  const topbar = q('.tasks-topbar')
  const newBtn = q('.tasks-new')
  pass('筛选行不换行、"新建"不被撑高、整行不溢出',
    [...document.querySelectorAll('.tasks-filter')].every(b => labelLines(b) === 1)
      && newBtn.getBoundingClientRect().height <= 40
      && topbar.scrollWidth <= topbar.clientWidth + 1,
    `lines=${[...document.querySelectorAll('.tasks-filter')].map(labelLines).join(',')} newH=${Math.round(newBtn.getBoundingClientRect().height)} scroll=${topbar.scrollWidth}/${topbar.clientWidth}`)
  pass('列表三行且已结束排在前', rows().length === 3 && rows()[0].dataset.status === 'inactive', rows().map(r => r.dataset.status).join(','))
  pass('已开启行显示下次计划时间与相对距离',
    /下次计划时间：/.test(activeRow().textContent) && /\(\d+[天小时分钟秒]+后\)|\(现在到期\)/.test(activeRow().textContent),
    activeRow().querySelector('.task-meta').textContent.replace(/\s+/g, ' ').trim())
  pass('已结束行显示徽标且不显示下次时间',
    /已结束/.test(inactiveRow().textContent) && !/下次计划时间/.test(inactiveRow().textContent))

  q('[data-filter="inactive"]').click(); await sleep(220)
  pass('筛选已结束', rows().length === 1 && rows()[0].dataset.status === 'inactive')
  q('[data-filter="active"]').click(); await sleep(220)
  pass('筛选已开启', rows().length === 2 && rows().every(r => r.dataset.status === 'active'))
  q('[data-filter="all"]').click(); await sleep(220)

  const si = q('#tasksSearch')
  si.value = '构建巡检'; si.dispatchEvent(new Event('input', { bubbles: true })); await sleep(220)
  pass('搜索命中任务名', rows().length === 1 && /每日构建巡检/.test(rows()[0].textContent))
  si.value = 'zzz-不存在'; si.dispatchEvent(new Event('input', { bubbles: true })); await sleep(220)
  pass('无命中给出空态与新建动作',
    q('.tasks-empty h2').textContent.trim() === '没有匹配的自动化任务' && q('.tasks-empty .btn').textContent.trim() === '新建自动化任务')
  pass('有搜索词时显示清空键', !q('#tasksSearchClear').hidden)
  q('#tasksSearchClear').click(); await sleep(220)
  pass('清空搜索恢复三行', rows().length === 3 && q('#tasksSearch').value === '')

  /* ---------------------------------------------------------- 详情:可编辑 */
  activeRow().click(); await sleep(460)
  pass('详情打开', !q('#tasksDetail').hidden && q('#tasksDetail h2').textContent.trim() === '任务详情')
  pass('未修改时不出现保存栏', !!q('#taskName') && !!q('#taskPrompt') && q('#taskSave').hidden)
  q('#taskName').value = '改名后的任务'
  q('#taskName').dispatchEvent(new Event('input', { bubbles: true })); await sleep(160)
  pass('修改后出现未保存提示与保存键',
    !q('#taskSave').hidden && q('.save-notice').textContent.trim() === '有未保存的修改')
  q('#taskName').value = ''
  q('#taskName').dispatchEvent(new Event('input', { bubbles: true })); await sleep(160)
  q('[data-act="task-draft-save"]').click(); await sleep(220)
  pass('空名称被拒并给出 DSH 文案', toastText() === '请输入不超过 120 个字符的任务名称', toastText())
  q('#taskName').value = '改名后的任务'
  q('#taskName').dispatchEvent(new Event('input', { bubbles: true })); await sleep(160)
  q('[data-act="task-draft-save"]').click(); await sleep(260)
  pass('保存后列表行名同步更新', rows().some(r => /改名后的任务/.test(r.textContent)) && q('#taskSave').hidden)
  q('#taskName').value = '又改了一次'
  q('#taskName').dispatchEvent(new Event('input', { bubbles: true })); await sleep(160)
  q('[data-act="task-draft-cancel"]').click(); await sleep(220)
  pass('取消草稿回到已保存值', q('#taskName').value === '改名后的任务' && q('#taskSave').hidden)

  /* ---------------------------------------------------------- 详情:已结束只读 */
  q('[data-act="task-detail-close"]').click(); await sleep(420)
  inactiveRow().click(); await sleep(460)
  pass('已结束任务整块只读',
    !q('#taskName') && !q('#taskPrompt') && !q('#taskSave') && !!q('.tasks-readonly'))
  pass('已结束任务说明只读原因', q('#tasksDetail').textContent.includes('已结束的任务为只读'))

  /* ---------------------------------------------------------- 删除确认 */
  q('[data-act="task-delete"]').click(); await sleep(520)
  pass('删除确认标题照 DSH', q('.sheet-h').textContent.trim() === '删除此任务？', q('.sheet-h').textContent.trim())
  pass('删除确认说明保留原会话',
    q('.sheet-b').textContent.includes('原会话及其消息仍然保留；已排队的消息不会被撤回'))
  pass('删除确认有取消与确认删除', sheetBtns().map(b => b.textContent.trim()).join('/') === '取消/确认删除', sheetBtns().map(b => b.textContent.trim()).join('/'))
  q('.sheet-scrim').click(); await sleep(420)
  pass('取消删除不改动目录', rows().length === 3 && !q('.sheet'), String(rows().length))

  q('[data-act="task-delete"]').click(); await sleep(520)
  sheetBtns()[1].click(); await sleep(560)
  pass('确认删除后目录少一行', rows().length === 2, String(rows().length))
  pass('删除后自动关闭详情', q('#tasksDetail').hidden)
  pass('删除提示标注需 bridge', /bridge schedule\.delete/.test(toastText()), toastText())

  /* ---------------------------------------------------------- 已结束专属空态 */
  PROTO.resetDemoTasks(); await sleep(160)
  q('[data-filter="inactive"]').click(); await sleep(240)
  inactiveRow().click(); await sleep(440)
  q('[data-act="task-delete"]').click(); await sleep(500)
  sheetBtns()[1].click(); await sleep(560)
  pass('已结束清空后给出专属空态',
    q('.tasks-empty h2').textContent.trim() === '没有已结束的自动化任务', q('.tasks-empty h2').textContent.trim())

  /* ---------------------------------------------------------- 返回栈 */
  q('[data-filter="all"]').click(); await sleep(200)
  q('[data-act="tasks-close"]').click(); await sleep(560)
  pass('关闭页面回到聊天且层栈清空',
    !q('#pageTasks').classList.contains('is-in') && PROTO.layers.length === 0, PROTO.layers.join('>'))
  q('[data-act="drawer-open"]').click(); await sleep(520)
  pass('左抽屉仍可正常打开', PROTO.layers.join('>') === 'drawer' && PROTO.drawer.p === 1, PROTO.layers.join('>'))
  q('#scrim').click(); await sleep(560)
  pass('收起抽屉后层栈清空', PROTO.layers.length === 0 && PROTO.drawer.p === 0, PROTO.layers.join('>'))
  pass('无运行期错误', out.errors.length === 0, out.errors.join(' | '))

  out.failed = out.checks.filter(c => !c.pass).length
  return out
})

/* 窄屏回归:新增第 5 个底栏入口后,320px 不能溢出或换行 */
await viewport(320, 568)
await send('Page.navigate', { url: PAGE })
await sleep(1400)
const narrow = await evalJs(async () => {
  const sleep = (ms) => new Promise(r => setTimeout(r, ms))
  const q = (s) => document.querySelector(s)
  /* 逐项数标签行数:scrollWidth 测不出换行(换行后并不横向溢出),会被静默放过 */
  const labelLines = (el) => {
    const node = [...el.childNodes].find(n => n.nodeType === 3 && n.textContent.trim())
    if (!node) return 0
    const range = document.createRange()
    range.selectNodeContents(node)
    return range.getClientRects().length
  }
  q('[data-act="drawer-open"]').click(); await sleep(500)
  const foot = q('.drawer-foot')
  const items = [...foot.children]
  return {
    viewport: window.innerWidth,
    overflow: foot.scrollWidth <= foot.clientWidth + 1,
    scrollWidth: foot.scrollWidth,
    clientWidth: foot.clientWidth,
    footHeight: Math.round(foot.getBoundingClientRect().height),
    heights: items.map(b => Math.round(b.getBoundingClientRect().height)),
    labels: items.map(b => b.textContent.trim()),
    labelLines: items.map(labelLines),
  }
})

const checks = [...main.checks, {
  name: '320px 底栏 5 项不溢出、不换行、高度不变',
  pass: narrow.overflow && narrow.labelLines.every(n => n === 1) && narrow.heights.every(h => h <= 56),
  detail: JSON.stringify(narrow),
}]
const failed = checks.filter(c => !c.pass)

console.log(JSON.stringify({ checks, failed: failed.length }, null, 2))
console.log(`失败 ${failed.length} 项 / 共 ${checks.length} 项`)
ws.close()
process.exit(failed.length === 0 ? 0 : 1)
