/* 设置页验证:入口、首页顺序、二级页、真实排列与返回栈。
   用法:先 pwsh -File mock/proto/tools/cdp.ps1 -Port 9400,
   再 CDP_URL=http://127.0.0.1:9400 NO_PROXY=127.0.0.1,localhost node mock/proto/tools/verify-settings.mjs
   排列依据:DSH `settings.section` 的 order(账号 -10 / 通用 0 / 模型 10 / 内置插件 15 / Agent 预设 20)
   与 `settings.general.item` 的 order(docs/settings-porting-notes.md:33 已核实到行号)。 */
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
  throw new Error('no CDP page target')
}
const t = await target()
const ws = new WebSocket(t.webSocketDebuggerUrl)
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej })
let id = 0
const pending = new Map()
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) } }
const send = (method, params = {}) => { const mid = ++id; ws.send(JSON.stringify({ id: mid, method, params })); return new Promise((res) => pending.set(mid, res)) }
const evaluate = async (fn) => {
  const r = await send('Runtime.evaluate', { expression: `(${fn.toString()})()`, awaitPromise: true, returnByValue: true })
  if (r.result?.exceptionDetails) throw new Error(r.result.exceptionDetails.exception?.description || 'Runtime exception')
  return r.result?.result?.value
}
await send('Page.enable'); await send('Runtime.enable')
await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true })
await send('Page.navigate', { url: PAGE }); await sleep(1500)

const result = await evaluate(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms))
  const q = s => document.querySelector(s)
  const out = { errors: [], checks: [] }
  window.addEventListener('error', e => out.errors.push(e.message))
  const pass = (name, value, detail = '') => out.checks.push({ name, pass: !!value, detail: detail === '' ? (value === true ? '' : String(value)) : detail })
  const rowTitles = () => [...document.querySelectorAll('#settingsDetail .settings-control .control-title')].map(e => e.textContent.trim())
  const toastText = () => (q('.toast') ? q('.toast').textContent.trim() : '')
  const sheetBtns = () => [...document.querySelectorAll('.sheet [data-sheet-act]')]

  const T = window.Takeovers
  while (T.pending) T.dequeue()
  await sleep(300)
  try {

  // 顶栏的 ☰ 在 2026-10-16 去掉了：左抽屉走左缘侧滑（PROTO 里那条就是真实手势）。
  PROTO.openDrawerByEdge(); await sleep(450)
  q('[data-act="settings-open"]').click(); await sleep(520)
  pass('设置页打开', q('#pageSettings').classList.contains('is-in'))
  pass('首页标题', q('#settingsTitle').textContent.trim() === '设置')

  const homeSections = [...document.querySelectorAll('#settingsHome [data-section]')].map(b => b.dataset.section)
  pass('首页分组按 DSH settings.section 的 order',
    homeSections.join('>') === 'account>general>models>plugins>agent-presets>about', homeSections.join('>'))
  pass('权限不再是顶层设置组(DSH 注册在 settings.general.item)',
    !homeSections.includes('permission') && !q('#settingsHome [data-section="permission"]'))
  pass('首页文案含"按 DSH 排列"与 bridge 边界',
    document.body.textContent.includes('账号与余额') && document.body.textContent.includes('中转在线') && document.body.textContent.includes('需 bridge'))

  /* 通用设置:权限组 + settings.general.item 的真实顺序 */
  q('[data-section="general"]').click(); await sleep(380)
  pass('通用二级页', q('#settingsTitle').textContent.trim() === '通用设置')
  pass('通用页含权限组(默认权限 + 当前会话权限)',
    document.body.textContent.includes('新会话默认权限') && document.body.textContent.includes('当前会话权限') && !!q('[data-act="pick-default-perm"]'))
  pass('通用页行顺序照 settings.general.item 的 order',
    rowTitles().join('>') === [
      '新会话默认权限', '当前会话权限', '语言', '外观', '字号大小', '工作步骤展示',
      '工作步骤收起时机', '显示代码工作视图', '网页链接打开方式', '繁忙时的发送行为',
      '性能与用量', '在使用官方模型 API 时上传 Session Log',
    ].join('>'), rowTitles().join('>'))
  pass('通用页不搬快捷键(手机无物理键盘)',
    !rowTitles().some(x => /快捷键/.test(x)) && (q('#settingsDetail').textContent.includes('快捷键')))

  const appearance = q('[data-setting="appearance"]')
  const before = appearance.classList.contains('is-on')
  appearance.click(); await sleep(120)
  pass('开关可交互', appearance.classList.contains('is-on') !== before)
  appearance.click(); await sleep(120)

  /* 默认权限:Auto review 不在默认可选里;完全权限走同一条风险门 */
  q('[data-act="pick-default-perm"]').click(); await sleep(460)
  const permItems = [...document.querySelectorAll('.sheet [data-perm]')].map(b => b.dataset.perm)
  pass('默认权限选择器打开', q('.sheet-h')?.textContent.trim() === '新会话默认权限', q('.sheet-h')?.textContent.trim())
  pass('默认可选不含 Auto review', !permItems.includes('auto') && permItems.length === 3, permItems.join(','))
  q('.sheet [data-perm="danger-full-access"]').click(); await sleep(460)
  pass('完全权限仍需风险确认门',
    q('.sheet-h')?.textContent.trim() === '确认启用完全权限?' && !!q('[data-gate="ack"]'), q('.sheet-h')?.textContent.trim())
  q('.sheet-scrim').click(); await sleep(520)
  pass('取消后默认权限不变且 sheet 已关',
    q('[data-act="pick-default-perm"]').textContent.trim() === '工作区内修改' && !q('.sheet'),
    q('[data-act="pick-default-perm"]').textContent.trim() + ' sheet=' + !!q('.sheet'))

  q('[data-act="settings-back"]').click(); await sleep(380)
  pass('二级页返回首页', q('#settingsTitle').textContent.trim() === '设置' && q('#settingsDetail').hidden)

  q('[data-section="models"]').click(); await sleep(380)
  pass('模型页', q('#settingsTitle').textContent.trim() === '模型与服务商')
  pass('模型页不显示密钥值', document.body.textContent.includes('API 密钥') && document.body.textContent.includes('值不会回传手机') && !document.body.textContent.includes('sk-'))
  q('[data-act="settings-back"]').click(); await sleep(320)

  q('[data-section="plugins"]').click(); await sleep(380)
  pass('内置插件页', q('#settingsTitle').textContent.trim() === '内置插件')
  pass('插件页表达加载/不可用状态', document.body.textContent.includes('运行中') && document.body.textContent.includes('unavailable') && document.body.textContent.includes('电脑端编辑'))
  pass('插件管理不再是设置二级页(属独立主面板)', !q('#settingsHome [data-section="plugin-manager"]'))
  q('[data-act="settings-back"]').click(); await sleep(320)

  q('[data-section="agent-presets"]').click(); await sleep(380)
  pass('Agent 预设页', q('#settingsTitle').textContent.trim() === 'Agent 预设')
  pass('预设页有当前与只读说明', document.body.textContent.includes('当前') && document.body.textContent.includes('只读'))
  q('[data-act="settings-back"]').click(); await sleep(320)

  q('[data-section="account"]').click(); await sleep(380)
  pass('账号与余额页只读', q('#settingsTitle').textContent.trim() === '账号与余额' && document.body.textContent.includes('只读'))
  q('[data-act="settings-back"]').click(); await sleep(320)

  q('[data-section="about"]').click(); await sleep(380)
  pass('关于连接页', q('#settingsTitle').textContent.trim() === '关于与连接')
  pass('关于页版本行区分两端版本',
    document.body.textContent.includes('当前版本') && document.body.textContent.includes('电脑端 DSH 版本需 bridge'))
  // 连接方式(端点选择器,2026-10-16):两条端点都在 —— 直连(当前/首选)与中转(保底)。
  // **两条都显示是定案的**:它们是两种配置,而"当前正走的那条"必须出现在列表里,
  // 否则自动回落中转时用户管不着自己正在用的端点(决策笔记见 implemented/2026-10-16)。
  pass('关于页含连接方式两组端点(直连当前 / 中转保底)',
    document.body.textContent.includes('连接方式')
    && document.body.textContent.includes('ws://192.168.2.43:8790')
    && document.body.textContent.includes('保底通道')
    && document.body.textContent.includes('换端点不重扫码'))
  q('[data-act="settings-close"]').click(); await sleep(520)
  pass('关闭设置回到聊天', !q('#pageSettings').classList.contains('is-in') && !PROTO.layers.includes('settings'))
  pass('无运行期错误', out.errors.length === 0, out.errors.join(' | '))
  } catch (e) {
    /* 断言失败要报"哪一步断了",而不是只丢一个行号 */
    out.checks.push({ name: '脚本执行到结尾', pass: false, detail: e.message })
  }
  out.failed = out.checks.filter(x => !x.pass).length
  return out
})
console.log(JSON.stringify(result, null, 2))
console.log(`失败 ${result.failed} 项 / 共 ${result.checks.length} 项`)
ws.close()
process.exit(result.failed === 0 ? 0 : 1)
