/* 会话流的**轮组**(turn 分组 + 可折叠过程)回归 —— 2026-10-23。
   用法:
     pwsh -File mock/proto/tools/cdp.ps1 -Port 9400     # 另开一个终端
     $env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'
     node mock/proto/tools/verify-turns.mjs
   判据的**唯一出处**:docs/subsystems/turn-groups.md
     §1 分组边界(未归属组永不折叠) / §2 折叠藏什么 / §2.1 一个 turn 只有一个助手头 /
     §3 什么时候可折(运行中的一轮没有组头) / §5 收起时机两档。
   口径同 verify-subs.mjs:项数由脚本自己数出来,失败打印 JSON 并退 1。 */
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
  const qa = (s, r = document) => [...r.querySelectorAll(s)]
  const out = { checks: [], errors: [] }
  window.addEventListener('error', e => out.errors.push(e.message))
  /* 逐项记 pass/fail:末尾打印的项数必须是真数,不是手写的 */
  const pass = (name, value, detail = '') => out.checks.push({
    name, pass: !!value, detail: detail === '' ? (value === true ? '' : String(value)) : detail,
  })
  /* 可见 = 有布局盒;`display:none`(含被 `.tgrp.is-folded` 藏掉的)一律没有 */
  const vis = (el) => !!el && el.getClientRects().length > 0
  const rect = (el) => el.getBoundingClientRect()
  const groups = () => qa('#msgs .tgrp')
  const groupOf = (turn) => q(`#msgs .tgrp[data-turn="${turn}"]`)
  const headOf = (g) => g.querySelector('.tgrp-head')
  const tglOf = (g) => g.querySelector('.tgrp-tgl')
  const cvOf = (g) => (tglOf(g) ? tglOf(g).querySelector('.tgrp-cv') : null)
  const pillOf = (g, act) => g.querySelector(`.tgrp-pill[data-act="${act}"]`)
  const toastText = () => (q('.toast') ? q('.toast').textContent.trim() : '')
  const sheetTitle = () => ((q('.sheet-h') || {}).textContent || '').trim()
  const titles = () => qa('#settingsDetail .settings-control .control-title').map(e => e.textContent.trim())
  const sendPrompt = async (text) => {
    const input = q('#input')
    input.value = text
    input.dispatchEvent(new Event('input'))
    q('#send').click()
    await sleep(160)
  }

  /* 首屏有审批 / 提问 / 计划三组演示接管,会把输入栏占住 —— 先清空 */
  const T = window.Takeovers
  while (T.pending) T.dequeue()
  await sleep(300)

  /* ---------------------------------------------------------- §1 未归属组 */
  const orphan = groups()[0]
  pass('第一组没有轮号(历史窗口没加载到这一轮的 turn/start)',
    !orphan.dataset.turn, orphan.dataset.turn)
  pass('未归属组没有组头、也没有折叠箭头', !headOf(orphan) && !tglOf(orphan))
  pass('未归属组里的过程条目**始终可见**(永不折叠)',
    !!orphan.querySelector('.tool') && vis(orphan.querySelector('.tool')))
  pass('未归属组只有一个助手头', orphan.querySelectorAll('.a-head').length === 1,
    String(orphan.querySelectorAll('.a-head').length))
  pass('上下文注入算助手侧、系统提示词不算:头在系统提示词下面、第一条上下文注入上面',
    rect(orphan.querySelector('.note--sys')).bottom <= rect(orphan.querySelector('.a-head')).top
      && rect(orphan.querySelector('.a-head')).bottom <= rect(orphan.querySelector('.note--ctx')).top,
    `${Math.round(rect(orphan.querySelector('.note--sys')).bottom)}/${Math.round(rect(orphan.querySelector('.a-head')).top)}/${Math.round(rect(orphan.querySelector('.note--ctx')).top)}`)
  pass('每个已收口的轮都有组头,未归属组没有',
    groups().filter(g => g.dataset.turn).every(g => !!headOf(g)) && !headOf(orphan))

  /* ---------------------------------------------------------- §5 默认档:收口后收起 */
  const t1 = groupOf(1)
  pass('第 1 轮有组头(收口行)', !!headOf(t1))
  pass('组头落在**轮次末尾**(有意偏离 DSH 的轮次开头,§4)', t1.lastElementChild === headOf(t1))
  pass('默认收起(completion 档)', t1.classList.contains('is-folded'))
  pass('收起时用户消息仍在', vis(t1.querySelector('.turn--u')))
  pass('收起时助手正文仍在', vis(t1.querySelector('.md')))
  pass('收起时工具卡不在', !vis(t1.querySelector('.tool')))
  pass('收起时内联 diff 不在', !vis(t1.querySelector('.idiff')))
  pass('收起时变更文件与图片都不在',
    !vis(t1.querySelector('.files')) && !vis(t1.querySelector('.imgs')))
  pass('收起时思考行不在(它也是过程)', !vis(t1.querySelector('.think')))
  pass('收起时箭头朝下(DSH 的 chevronDown)',
    cvOf(t1).dataset.icon === 'chevronDown' && !cvOf(t1).hidden, cvOf(t1).dataset.icon)
  pass('组头的 aria:展开第 1 轮的过程',
    tglOf(t1).getAttribute('aria-expanded') === 'false'
      && tglOf(t1).getAttribute('aria-label') === '展开第 1 轮的过程',
    `${tglOf(t1).getAttribute('aria-expanded')} / ${tglOf(t1).getAttribute('aria-label')}`)

  /* ---------------------------------------------------------- 组头文案(§4 + 落地端 TurnProcessRow) */
  pass('组头标题 = 第 1 轮', t1.querySelector('.tgrp-n').textContent.trim() === '第 1 轮',
    t1.querySelector('.tgrp-n').textContent.trim())
  pass('统计三段 = 2 分 36 秒 · 1 条消息 · 1 次工具',
    t1.querySelector('.tgrp-st').textContent.trim() === '2 分 36 秒 · 1 条消息 · 1 次工具',
    t1.querySelector('.tgrp-st').textContent.trim())
  pass('用量 pill 的数是**算出来的**(8240 + 10540000 + 52000 = 10.6M)',
    !!pillOf(t1, 'turn-usage') && pillOf(t1, 'turn-usage').textContent.trim() === '用量 10.6M tok',
    pillOf(t1, 'turn-usage') && pillOf(t1, 'turn-usage').textContent.trim())
  pass('没有用量的轮不摆 0 tok(第 2 轮没有用量 pill)', !pillOf(groupOf(2), 'turn-usage'))
  pass('每一轮都有复制 pill(有正文才摆)',
    !!pillOf(t1, 'turn-copy') && !!pillOf(groupOf(3), 'turn-copy'))

  /* ---------------------------------------------------------- 点组头展开 / 再收起(§3) */
  tglOf(t1).click(); await sleep(120)
  pass('点组头展开:过程条目回来',
    !t1.classList.contains('is-folded')
      && vis(t1.querySelector('.think'))
      && vis(t1.querySelector('.tool'))
      && vis(t1.querySelector('.idiff')))
  pass('展开后箭头朝上、aria-expanded=true',
    cvOf(t1).dataset.icon === 'chevronUp' && tglOf(t1).getAttribute('aria-expanded') === 'true',
    `${cvOf(t1).dataset.icon} / ${tglOf(t1).getAttribute('aria-expanded')}`)

  /* ---------------------------------------------------------- §2.1 一个 turn 只有一个助手头 */
  pass('第 1 轮只有一个助手头', t1.querySelectorAll('.a-head').length === 1,
    String(t1.querySelectorAll('.a-head').length))
  pass('第 1 轮的助手头在轮次开头(思考行上方)',
    rect(t1.querySelector('.a-head')).bottom <= rect(t1.querySelector('.think')).top)
  pass('第 1 轮的助手头在正文上方', rect(t1.querySelector('.a-head')).bottom <= rect(t1.querySelector('.md')).top)

  tglOf(t1).click(); await sleep(120)
  pass('再点收起:工具卡不在',
    t1.classList.contains('is-folded') && !vis(t1.querySelector('.tool')))
  pass('收起后助手头仍在(按折叠后仍可见的条目算,§2.1)',
    vis(t1.querySelector('.a-head')) && rect(t1.querySelector('.a-head')).bottom <= rect(t1.querySelector('.md')).top)

  /* ---------------------------------------------------------- 命令卡 / 压缩卡不拿头(§2.1) */
  const t3 = groupOf(3)
  tglOf(t3).click(); await sleep(120)
  pass('第 3 轮:命令卡与压缩卡不拿头(头在它们下面、工具卡上面)',
    t3.querySelectorAll('.a-head').length === 1
      && rect(t3.querySelector('.cmd')).bottom <= rect(t3.querySelector('.a-head')).top
      && rect(t3.querySelector('.cmp')).bottom <= rect(t3.querySelector('.a-head')).top
      && rect(t3.querySelector('.a-head')).bottom <= rect(t3.querySelector('.tool')).top)
  tglOf(t3).click(); await sleep(120)
  pass('第 3 轮收起时助手头仍在正文上方(不随过程消失)',
    vis(t3.querySelector('.a-head')) && rect(t3.querySelector('.a-head')).bottom <= rect(t3.querySelector('.md')).top)

  /* ---------------------------------------------------------- §2 审批与提问卡不随收起 */
  const t2 = groupOf(2)
  pass('第 2 轮收起时审批与提问卡仍在',
    t2.classList.contains('is-folded')
      && vis(t2.querySelector('[data-act="reopen-approval"]'))
      && vis(t2.querySelector('[data-act="reopen-question"]')))
  pass('第 2 轮的思考行确实收起了', !vis(t2.querySelector('.think')))

  /* ---------------------------------------------------------- 用量 / 复制(组头上的两枚 pill) */
  pillOf(t1, 'turn-usage').click(); await sleep(420)
  pass('用量 pill 打开「第 1 轮用量」', sheetTitle() === '第 1 轮用量', sheetTitle())
  pass('明细合计 = 10,600,240(与 pill 的 10.6M 同源,不是另写一个数)',
    qa('.sheet .kv').some(k => k.textContent.includes('合计') && k.textContent.includes('10,600,240')),
    qa('.sheet .kv').map(k => k.textContent.replace(/\s+/g, ' ').trim()).join(' | '))
  q('.sheet-scrim').click(); await sleep(420)
  pillOf(t1, 'turn-copy').click(); await sleep(160)
  pass('点复制给出反馈', toastText() === '已复制这一轮的回复', toastText())

  /* ---------------------------------------------------------- §3 运行中的一轮 */
  await sendPrompt('再跑一轮')
  const live = groups()[groups().length - 1]
  pass('发送后出现新的一组(第 4 轮),还没收口',
    live.dataset.turn === '4' && !live.dataset.closed,
    `${live.dataset.turn} / closed=${live.dataset.closed}`)
  pass('运行中的一轮**没有组头**、也没有折叠箭头', !headOf(live) && !tglOf(live))
  pass('运行中的过程条目可见(边跑边看是主场景)',
    vis(live.querySelector('.think')) && vis(live.querySelector('.tool')))
  pass('运行中的一轮不可折(没有 is-folded)', !live.classList.contains('is-folded'))
  PROTO.finishTurn(); await sleep(160)
  pass('收口后组头出现', !!headOf(live))
  pass('收口后默认收起(completion):过程条目不可见',
    live.classList.contains('is-folded') && !vis(live.querySelector('.tool')))
  pass('收口后统计三段(不到 1 秒 · 1 条消息 · 1 次工具)',
    live.querySelector('.tgrp-st').textContent.trim() === '不到 1 秒 · 1 条消息 · 1 次工具',
    live.querySelector('.tgrp-st').textContent.trim())
  pass('收口后用户消息与助手正文仍在',
    vis(live.querySelector('.turn--u')) && vis(live.querySelector('.md')))

  /* ---------------------------------------------------------- §5 「工作步骤收起时机」两档 */
  PROTO.openDrawerByEdge(); await sleep(450)
  q('[data-act="settings-open"]').click(); await sleep(520)
  q('[data-section="general"]').click(); await sleep(380)
  const rowTitles = titles()
  pass('通用页有「工作步骤收起时机」一行,紧跟「工作步骤展示」',
    rowTitles.indexOf('工作步骤收起时机') === rowTitles.indexOf('工作步骤展示') + 1,
    rowTitles.join('>'))
  const badge = () => q('[data-act="pick-collapse-timing"]')
  pass('默认档 = 回答结束后', badge() && badge().textContent.trim() === '回答结束后',
    badge() && badge().textContent.trim())
  badge().click(); await sleep(420)
  pass('sheet 标题是「工作步骤收起时机」', sheetTitle() === '工作步骤收起时机', sheetTitle())
  const opts = qa('.sheet [data-timing]').map(b => b.dataset.timing)
  pass('两档都在(completion / next-input)', opts.join(',') === 'completion,next-input', opts.join(','))
  q('.sheet [data-timing="next-input"]').click(); await sleep(420)
  pass('选「下次有新消息时」后 badge 变了', badge().textContent.trim() === '下次有新消息时',
    badge().textContent.trim())
  pass('选完 sheet 已关', !q('.sheet'))
  q('[data-act="settings-back"]').click(); await sleep(320)
  q('[data-act="settings-close"]').click(); await sleep(520)
  pass('关闭设置回到聊天', !q('#pageSettings').classList.contains('is-in') && PROTO.layers.length === 0,
    PROTO.layers.join('>'))

  pass('next-input:最新一轮(第 4 轮)默认展开',
    !live.classList.contains('is-folded') && vis(live.querySelector('.tool')))
  pass('next-input:上一轮(第 1 轮)仍收起', t1.classList.contains('is-folded'))

  await sendPrompt('再跑一轮二')
  const live2 = groups()[groups().length - 1]
  pass('发出下一句 ⇒ 上一轮(第 4 轮)不再是最后一组 ⇒ 收起',
    live2.dataset.turn === '5' && live.classList.contains('is-folded')
      && !vis(live.querySelector('.tool')),
    `${live2.dataset.turn} / folded=${live.classList.contains('is-folded')}`)
  PROTO.finishTurn(); await sleep(160)
  pass('收口后第 5 轮是最新一组 ⇒ 展开',
    !live2.classList.contains('is-folded') && vis(live2.querySelector('.tool')))
  pass('第 4 轮仍是收起', live.classList.contains('is-folded'))

  /* 三档优先的第一档:用户手动点过 ⇒ 听用户的,不再受偏好影响 */
  tglOf(t1).click(); await sleep(120)
  PROTO.setCollapseTiming('completion'); await sleep(120)
  pass('手动展开优先于偏好:切回 completion 后第 1 轮仍展开',
    !t1.classList.contains('is-folded') && vis(t1.querySelector('.tool')))

  /* 打断也是收口:不然那一组永远停在"运行中"的样子(组头只在收口后出现,§3) */
  await sendPrompt('打断这一轮')
  const live3 = groups()[groups().length - 1]
  pass('打断前:新一轮没有组头', !headOf(live3) && !tglOf(live3))
  q('#send').click(); await sleep(220)
  pass('打断 = 收口:组头出现,统计只有「已停止」(不摆计数)',
    !!headOf(live3) && live3.querySelector('.tgrp-st').textContent.trim() === '已停止',
    live3.querySelector('.tgrp-st') && live3.querySelector('.tgrp-st').textContent.trim())

  pass('无运行期错误', out.errors.length === 0, out.errors.join(' | '))
  return out
})

/* 项数由脚本数出来,不手写:末尾那行必须等于实际跑过的条数 */
const failed = out.checks.filter(c => !c.pass)
console.log(JSON.stringify({ checks: out.checks, failed: failed.length }, null, 2))
console.log(`失败 ${failed.length} 项 / 共 ${out.checks.length} 项`)
ws.close()
process.exit(failed.length === 0 ? 0 : 1)
