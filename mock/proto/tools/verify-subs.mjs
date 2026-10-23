/* 右抽屉「子智能体」面板 —— **目录树**回归(2026-10-23)。
   用法:
     pwsh -File mock/proto/tools/cdp.ps1 -Port 9400     # 另开一个终端
     $env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'
     node mock/proto/tools/verify-subs.mjs
   覆盖(docs/subsystems/subagent-page.md §2 / §3 / §3.1):
     - 面板 root 只有**直接子级**;孙级要点 disclosure 才出现(展开才读)
     - 三态各一句话:加载中 / 失败+重试 / 读到空
     - 已知空叶没有展开钮;external 不可进入、也不可展开
     - 行 = 活动点 + label + 第二行(title · mode · activity · 时长)+ 右列 token
           + 行尾 44×44 展开钮
     - 收起连带收起整枝;再展开只回到第一层
     - 点行 = 进入(收起抽屉),不是展开
   出处:packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:190-408
   与 SubagentHeaderLineage.module.css。 */
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
  if (r.result?.exceptionDetails) {
    throw new Error(r.result.exceptionDetails.exception?.description || 'runtime exception')
  }
  return r.result?.result?.value
}

await send('Page.enable')
await send('Runtime.enable')
await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true })
await send('Page.navigate', { url: PAGE })
await sleep(1500)

const out = await evalJs(async () => {
  const sleep = (ms) => new Promise(r => setTimeout(r, ms))
  const q = (s) => document.querySelector(s)
  const qa = (s) => [...document.querySelectorAll(s)]
  const out = { checks: [], errors: [] }
  window.addEventListener('error', e => out.errors.push(e.message))
  /* 逐项记 pass/fail:末尾打印的项数必须是真数,不是手写的 */
  const pass = (name, value, detail = '') => out.checks.push({
    name, pass: !!value, detail: detail === '' ? (value === true ? '' : String(value)) : detail,
  })
  const rect = (el) => { const b = el.getBoundingClientRect(); return { w: Math.round(b.width), h: Math.round(b.height), right: Math.round(b.right), left: Math.round(b.left) } }

  /* 目录树里的一行(跨层级,id 唯一) */
  const rows = () => qa('#subsList .sub-row')
  const rowOf = (id) => q(`#subsList [data-sub-row="${id}"]`)
  const l2Of = (id) => rowOf(id).querySelector('.sub-l2').textContent.trim()
  const tokOf = (id) => {
    const el = rowOf(id) && rowOf(id).querySelector('.sub-tok')
    return el ? el.textContent.trim() : null
  }
  const toggleOf = (id) => q(`#subsList [data-sub-toggle="${id}"]`)
  /* 三态各自那句话:加载中 / 失败 / 读到空 */
  const notes = () => qa('#subsList .sub-note, #subsList .sub-err, #subsList .sub-empty')
    .map(n => n.textContent.replace(/\s+/g, ' ').trim())

  /* ---------------------------------------------------------- 打开面板 */
  const chip = q('.livechip[data-act="subs-all"]')
  /* 全文本照 DSH 的 `count.running`(ui-subagent/src/client/locales.ts:38-39):
     `{count} 个子智能体，正在运行` —— 全角逗号,别写成半角 */
  pass('顶栏计数 chip 的全文本是 DSH 原文(在跑那一档)',
    chip && /^\d+ 个子智能体，正在运行$/.test(chip.getAttribute('aria-label') || ''),
    chip && chip.getAttribute('aria-label'))
  chip.click(); await sleep(450)
  pass('点 chip 打开右抽屉并落在子智能体面板',
    q('#pageSide').classList.contains('is-in') && q('#panelSubs').classList.contains('is-on') && PROTO.layers.join('>') === 'side',
    `layers=${PROTO.layers.join('>')}`)

  /* ---------------------------------------------------------- root 只有直接子级 */
  pass('root 只有直接子级(4 行,孙级不在里面)',
    rows().length === 4 && !q('#subsList').textContent.includes('核对图标几何'),
    rows().map(r => r.dataset.subRow).join(','))
  pass('默认全收起(没有任何子级容器)', qa('#subsList .sub-kids').length === 0)
  pass('抬头只有标题「子智能体」,不摆副标题(App 的 SideHeader 同一条)',
    q('#sideTitle').textContent.trim() === '子智能体' && q('#sideSub').textContent.trim() === '',
    `${q('#sideTitle').textContent.trim()} / ${q('#sideSub').textContent.trim()}`)

  /* ---------------------------------------------------------- 行规格 */
  pass('每行都有活动点', rows().every(r => !!r.querySelector('.sub-dot')))
  pass('活动点三态齐全(在跑转圈 / 正常完成绿 / 其余灰)',
    !!q('[data-sub-row="sub-icon"] .spin-arc')
      && q('[data-sub-row="sub-empty"] .sdot').dataset.state === 'done'
      && q('[data-sub-row="sub-broken"] .sdot').dataset.state === 'idle')
  /* 第二行 = `title · mode · activity · 时长`(Web 的 :257-259 + 挪进来的时长)。
     时长在走,所以只钉形状,不钉数字。 */
  pass('第二行 = title · mode · activity · 时长',
    /^图标链路 · 可继续 · 正在运行 · \d+分\d{2}秒$/.test(l2Of('sub-icon')), l2Of('sub-icon'))
  pass('一次性行的 mode 与活动态用 DSH 的词',
    /^独立模式调研 · 一次性 · 已完成 · 5分34秒$/.test(l2Of('sub-empty')), l2Of('sub-empty'))
  pass('外部任务行**没有** activity 段',
    l2Of('sub-ext') === '跨仓库回归 · 外部任务', l2Of('sub-ext'))
  pass('没给 token 的行不摆数字(四桶全零 = 还没用,不写 0 tok)',
    l2Of('sub-broken') === '抽屉手势 · 可继续 · 当前未运行 · 12秒' && tokOf('sub-broken') === null,
    `${l2Of('sub-broken')} / tok=${tokOf('sub-broken')}`)
  pass('右列只放 token 一个数',
    tokOf('sub-icon') === '41.7K tok' && tokOf('sub-empty') === '12.3K tok',
    `${tokOf('sub-icon')} / ${tokOf('sub-empty')}`)
  pass('时长并进第二行,行里没有第二个时长格',
    !q('#subsList .sub-tm') && !/[秒分]/.test(tokOf('sub-icon') || ''))

  /* ---------------------------------------------------------- 行尾 44×44 */
  const exp = qa('#subsList .sub-exp')
  pass('可展开的两行各有一枚展开钮(空叶与 external 没有)',
    exp.length === 2 && !!toggleOf('sub-icon') && !!toggleOf('sub-broken') && !toggleOf('sub-empty') && !toggleOf('sub-ext'),
    String(exp.length))
  pass('展开钮的可点区 = 44×44',
    exp.every(b => rect(b).w === 44 && rect(b).h === 44), exp.map(b => `${rect(b).w}×${rect(b).h}`).join(','))
  pass('展开钮贴行尾(右缘与行右缘齐)',
    exp.every(b => rect(b).right === rect(rowOf(b.dataset.subToggle)).right),
    exp.map(b => `${rect(b).right}/${rect(rowOf(b.dataset.subToggle)).right}`).join(','))
  pass('展开钮的无障碍名照 DSH(locales.ts:34-35)',
    toggleOf('sub-icon').getAttribute('aria-label') === '展开 抽取 DSH 图标路径 的下级子智能体',
    toggleOf('sub-icon').getAttribute('aria-label'))

  /* ---------------------------------------------------------- 展开才读(加载态) */
  toggleOf('sub-icon').click(); await sleep(90)
  pass('展开先读到「正在加载子智能体…」(还没读到 ≠ 没有)',
    notes().join('|') === '正在加载子智能体…', notes().join('|'))
  await sleep(700)
  pass('读到后孙级出现在它下面', !!rowOf('sub-icon-grand') && rows().length === 5,
    rows().map(r => r.dataset.subRow).join(','))
  pass('展开后展开钮转 90°(aria-expanded + is-open)',
    toggleOf('sub-icon').getAttribute('aria-expanded') === 'true' && toggleOf('sub-icon').classList.contains('is-open'))
  pass('展开后无障碍名换成「收起」',
    (toggleOf('sub-icon').getAttribute('aria-label') || '').startsWith('收起 '),
    toggleOf('sub-icon').getAttribute('aria-label'))

  /* ---------------------------------------------------------- 孙级 / 收起整枝 */
  toggleOf('sub-icon-grand').click(); await sleep(90)
  pass('孙级自己也能展开(再读一层)',
    notes().join('|') === '正在加载子智能体…', notes().join('|'))
  await sleep(700)
  pass('曾孙出现(三层各缩进一级)',
    !!rowOf('sub-icon-great') && rows().length === 6 && rect(rowOf('sub-icon-great')).left > rect(rowOf('sub-icon-grand')).left,
    `${rect(rowOf('sub-icon-grand')).left} -> ${rect(rowOf('sub-icon-great')).left}`)
  /* 一整行**什么都没给**时:第二行只剩 mode · activity,右列与时长整格不出现
     (不拿本地时钟凑,也不摆 0) */
  pass('什么都没给的行:第二行只剩 mode · activity,右列整格不出现',
    l2Of('sub-icon-great') === '可继续 · 当前未运行' && tokOf('sub-icon-great') === null,
    `${l2Of('sub-icon-great')} / tok=${tokOf('sub-icon-great')}`)
  toggleOf('sub-icon').click(); await sleep(150)
  pass('收起 sub-icon 连带收起整枝(孙级与曾孙一起消失)',
    !rowOf('sub-icon-grand') && !rowOf('sub-icon-great') && rows().length === 4)
  toggleOf('sub-icon').click(); await sleep(700)
  pass('再展开只回到第一层(深层不自己冒出来)',
    !!rowOf('sub-icon-grand') && !rowOf('sub-icon-great'))
  toggleOf('sub-icon').click(); await sleep(150) // 收起来,给"点行 = 进入"一个干净起点

  /* ---------------------------------------------------------- 失败态 + 重试 */
  toggleOf('sub-broken').click(); await sleep(90)
  pass('读失败那一层也是先「正在加载」', notes().join('|') === '正在加载子智能体…', notes().join('|'))
  await sleep(700)
  pass('失败 = 「无法加载子智能体」+「重试」',
    /^无法加载子智能体 ?重试$/.test(notes().join('|')) && !!q('#subsList [data-sub-retry="sub-broken"]'),
    notes().join('|'))
  q('#subsList [data-sub-retry="sub-broken"]').click(); await sleep(90)
  pass('点重试重读**那一层**(不是重开抽屉)',
    notes().join('|') === '正在加载子智能体…' && q('#panelSubs').classList.contains('is-on'), notes().join('|'))
  await sleep(700)
  pass('重试仍失败就如实再报一次(不假装成功)',
    /^无法加载子智能体 ?重试$/.test(notes().join('|')), notes().join('|'))

  /* ---------------------------------------------------------- 已知空叶 / external */
  pass('已知空叶没有展开钮(读到空才敢说它没有下级)',
    !!rowOf('sub-empty') && !toggleOf('sub-empty'))
  pass('external 行既不可展开也不可进入',
    !toggleOf('sub-ext') && !rowOf('sub-ext').hasAttribute('data-sub-enter')
      && rowOf('sub-ext').getAttribute('aria-disabled') === 'true')

  /* ---------------------------------------------------------- 点行 = 进入 */
  const before = rows().length
  rowOf('sub-icon').querySelector('.sub-l1').click(); await sleep(450)
  pass('点行 = 进入:抽屉收起、层栈清空',
    !q('#pageSide').classList.contains('is-in') && PROTO.layers.length === 0, `layers=${PROTO.layers.join('>')}`)
  pass('点行 = 进入:给一句提示(原型没有子会话内容)',
    (q('.toast') || {}).textContent === '进入子智能体 · 抽取 DSH 图标路径' && !!q('.toast.is-on'),
    (q('.toast') || {}).textContent)
  pass('点行不是展开:那一行仍收起、也没有多出孙级',
    !rowOf('sub-icon-grand') && rows().length === before && toggleOf('sub-icon').getAttribute('aria-expanded') === 'false')
  q('.livechip[data-act="subs-all"]').click(); await sleep(450)
  pass('重新打开面板:那一行仍是收起态(进入没有顺手展开)',
    toggleOf('sub-icon').getAttribute('aria-expanded') === 'false' && !rowOf('sub-icon-grand'))
  q('[data-act="side-close"]').click(); await sleep(450)
  pass('收起面板后层栈干净(不留幽灵层)',
    PROTO.layers.length === 0 && !q('#pageSide').classList.contains('is-in'), PROTO.layers.join('>'))

  /* ---------------------------------------------------------- 读到空(根级空态) */
  PROTO.openDrawerByEdge(); await sleep(520)
  q('[data-sid="sess-auth"]').click(); await sleep(220)
  pass('切到没有子级的会话:顶栏不再有子智能体 chip',
    qa('.livechip[data-act="subs-all"]').length === 0)
  q('#scrim').click(); await sleep(520)
  PROTO.openSideByEdge(); await sleep(520)
  q('[data-panel="subs"]').click(); await sleep(320)
  pass('那一层读到空 = 「没有子智能体。」(不是"正在加载")',
    notes().join('|') === '没有子智能体。' && rows().length === 0, notes().join('|'))
  pass('读到空时表头不变(仍是「子智能体」,不写"没有子智能体"进抬头)',
    q('#sideTitle').textContent.trim() === '子智能体' && q('#sideSub').textContent.trim() === '',
    `${q('#sideTitle').textContent.trim()} / ${q('#sideSub').textContent.trim()}`)
  q('[data-act="side-close"]').click(); await sleep(320)

  pass('无运行期错误', out.errors.length === 0, out.errors.join(' | '))
  return out
})

/* 项数由脚本数出来,不手写:末尾那行 "共 N 项" 必须等于实际跑过的条数 */
const failed = out.checks.filter(c => !c.pass)
console.log(JSON.stringify({ checks: out.checks, failed: failed.length }, null, 2))
console.log(`失败 ${failed.length} 项 / 共 ${out.checks.length} 项`)
ws.close()
process.exit(failed.length === 0 ? 0 : 1)
