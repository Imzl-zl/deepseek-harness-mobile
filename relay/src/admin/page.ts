/**
 * 管理面页面：**单文件、内联、无外链**（中转没有构建步骤，见 `relay/Dockerfile`）。
 *
 * ## 它是一套独立产品的控制台，不是宿主的插件页
 *
 * 中转是独立服务（`node src/main.ts`），与 DSH 的 UI 没有共享运行时、也不该借它的
 * 视觉 token。所以这套配色与排版是**自成一体的**：深色海军底 + 青绿强调色，
 * 左边一列分区导航（概览 / 连接器 / 通道 / 用量 / 令牌），右边是内容区。
 * 跟随系统亮暗（两套变量），图标是内联 SVG，没有任何外部资源。
 *
 * ## 两屏，不是一屏
 *
 * 1. **登录屏**：一张卡 + 一个令牌输入。拿到令牌前**不渲染任何看板**。
 * 2. **控制台**：令牌有效才出现；2 s 轮询；任何一次 401 退回登录屏。
 *
 * 不做用户名：中转只有一个管理身份（`admin.id`），多一个填了也校验不了的格子只让人猜。
 *
 * ## 曲线是真数据
 *
 * 概览里那条 60 分钟曲线来自 `metering.traffic()` —— 服务端按分钟累计的真实转发
 * 字节（60 个整数，滚动窗口），不是抽样也不是估算。
 *
 * ## 凭据怎么带
 *
 * 令牌存 `sessionStorage`，每次 `fetch` 放进 `Authorization` 头 —— 不设 cookie，
 * 浏览器不会自动带凭据，CSRF 无从谈起；页面没有外链脚本可读它。
 *
 * Note: 为什么轮询而不是 WS/SSE、为什么独立凭据 —— 见
 * `.agents/notes/implemented/2026-10-30-relay-admin-panel.md`
 */
export const ADMIN_PAGE = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DSH 中转 · 控制台</title>
<style>
:root{
  --bg:#0a0d12; --panel:#10141b; --panel2:#151a23; --line:#1e2530; --line2:#2a3341;
  --ink:#e9eef6; --ink2:#b7c1cf; --ink3:#8592a6; --cap:#68758a;
  --accent:#2dd4bf; --accent-ink:#06231f; --accent-soft:rgba(45,212,191,.12);
  --ok:#34d399; --warn:#fbbf24; --bad:#fb7185;
  --shadow:0 18px 40px rgba(0,0,0,.35);
}
@media (prefers-color-scheme:light){
  :root{
    --bg:#f5f7fa; --panel:#ffffff; --panel2:#f0f3f7; --line:#e4e9f0; --line2:#cbd5e1;
    --ink:#0f172a; --ink2:#334155; --ink3:#64748b; --cap:#94a3b8;
    --accent:#0d9488; --accent-ink:#ffffff; --accent-soft:rgba(13,148,136,.10);
    --ok:#059669; --warn:#d97706; --bad:#e11d48;
    --shadow:0 10px 30px rgba(15,23,42,.08);
  }
}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--ink);
  font:14px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans SC",sans-serif;
  -webkit-font-smoothing:antialiased}
button{font:inherit;color:inherit;cursor:pointer;background:none;border:0}
input{font:inherit}
[hidden]{display:none!important}
a{color:inherit;text-decoration:none}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:6px}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px}
.num{font-variant-numeric:tabular-nums}
.cap{font-size:12px;color:var(--cap)}

/* ---------------- 登录 ---------------- */
.login{min-height:100%;display:grid;place-items:center;padding:24px;
  background:
    radial-gradient(760px 420px at 18% 0%,var(--accent-soft),transparent 70%),
    radial-gradient(600px 360px at 92% 108%,rgba(124,140,255,.12),transparent 70%),
    var(--bg)}
.login-card{width:min(400px,100%);background:var(--panel);border:1px solid var(--line);
  border-radius:18px;padding:32px 30px 26px;box-shadow:var(--shadow)}
.mark{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;
  background:var(--accent-soft);border:1px solid color-mix(in srgb,var(--accent) 35%,transparent)}
.mark svg{width:22px;height:22px;stroke:var(--accent)}
.login-card h1{font-size:20px;margin:18px 0 6px;letter-spacing:.2px;font-weight:660}
.login-card .sub{margin:0 0 22px;color:var(--cap);font-size:13px}
.field{display:block;margin:0 0 16px}
.field span{display:block;font-size:12px;color:var(--ink3);margin:0 0 7px}
.field input{width:100%;padding:11px 13px;border:1px solid var(--line2);border-radius:10px;
  background:var(--bg);color:var(--ink);outline:none;transition:border-color .12s,box-shadow .12s}
.field input::placeholder{color:var(--cap)}
.field input:focus{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
.primary{width:100%;padding:11px 13px;border-radius:10px;background:var(--accent);
  color:var(--accent-ink);font-weight:650;transition:filter .12s}
.primary:hover{filter:brightness(1.05)}
.error{margin:14px 0 0;padding:9px 11px;border-radius:9px;font-size:13px;
  background:color-mix(in srgb,var(--bad) 14%,transparent);
  border:1px solid color-mix(in srgb,var(--bad) 35%,transparent);color:var(--bad)}
.hint{margin:18px 0 0;color:var(--cap);font-size:12px;line-height:1.7}
.hint code{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11.5px;
  background:var(--panel2);border:1px solid var(--line);border-radius:5px;padding:1px 5px}

/* ---------------- 控制台骨架 ---------------- */
.app{display:flex;min-height:100%}
.side{width:232px;flex:none;display:flex;flex-direction:column;gap:18px;
  padding:20px 14px;background:var(--panel);border-right:1px solid var(--line);
  position:sticky;top:0;height:100vh}
.brand{display:flex;align-items:center;gap:10px;padding:0 6px}
.brand .mark{width:30px;height:30px;border-radius:9px}
.brand .mark svg{width:18px;height:18px}
.brand b{display:block;font-size:14px;letter-spacing:.2px}
.brand span{display:block;font-size:11px;color:var(--cap);letter-spacing:.06em;text-transform:uppercase}
nav{display:flex;flex-direction:column;gap:2px}
nav a{display:flex;align-items:center;gap:10px;padding:8px 10px;border-radius:9px;
  color:var(--ink2);font-size:13.5px;transition:background .12s,color .12s}
nav a:hover{background:var(--panel2)}
nav a.active{background:var(--accent-soft);color:var(--accent);font-weight:600}
nav em{margin-left:auto;font-style:normal;font-size:11px;color:var(--cap);
  font-variant-numeric:tabular-nums}
.sidefoot{margin-top:auto;display:flex;flex-direction:column;gap:8px;padding:0 6px}
.pill{display:inline-flex;align-items:center;gap:7px;height:26px;padding:0 10px;border-radius:999px;
  border:1px solid var(--line2);background:var(--panel2);font-size:11.5px;color:var(--ink3);
  align-self:flex-start}
.dot{width:7px;height:7px;border-radius:50%;background:var(--cap);flex:none}
.pill.ok .dot{background:var(--ok);box-shadow:0 0 0 3px color-mix(in srgb,var(--ok) 18%,transparent)}
.pill.bad .dot{background:var(--bad);box-shadow:0 0 0 3px color-mix(in srgb,var(--bad) 18%,transparent)}
.sidefoot .cap{font-size:11px;line-height:1.6}

.main{flex:1;min-width:0;display:flex;flex-direction:column}
.topbar{position:sticky;top:0;z-index:9;display:flex;align-items:center;gap:12px;
  padding:16px 24px;background:color-mix(in srgb,var(--bg) 86%,transparent);
  backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.topbar h1{margin:0;font-size:17px;font-weight:650;letter-spacing:.2px}
.topbar p{margin:2px 0 0;font-size:12px;color:var(--cap)}
.grow{flex:1}
.ghost{height:30px;padding:0 12px;border:1px solid var(--line2);border-radius:9px;
  font-size:12.5px;color:var(--ink2);background:var(--panel);
  transition:border-color .12s,color .12s}
.ghost:hover{border-color:var(--accent);color:var(--accent)}
.content{padding:24px;max-width:1180px;width:100%;margin:0 auto;display:flex;
  flex-direction:column;gap:16px}

/* ---------------- 组件 ---------------- */
.kpis{display:grid;gap:14px;grid-template-columns:repeat(4,minmax(0,1fr))}
.kpi{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:14px 16px}
.kpi .v{font-size:26px;font-weight:660;letter-spacing:.2px;font-variant-numeric:tabular-nums}
.kpi .k{margin-top:2px;font-size:12px;color:var(--cap)}
.kpi.accent .v{color:var(--accent)}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;min-width:0;overflow:hidden}
.card > header{display:flex;align-items:baseline;gap:10px;padding:15px 18px 10px}
.card h2{margin:0;font-size:12.5px;font-weight:600;color:var(--ink3);letter-spacing:.05em}
.card .meta{margin-left:auto;font-size:11.5px;color:var(--cap);font-variant-numeric:tabular-nums}
.card .body{padding:0 18px 16px}
.chart{padding:2px 0 0}
.spark{width:100%;height:96px;display:block}
.spark .line{fill:none;stroke:var(--accent);stroke-width:2;vector-effect:non-scaling-stroke;
  stroke-linejoin:round;stroke-linecap:round}
.spark .area{fill:color-mix(in srgb,var(--accent) 16%,transparent);stroke:none}
.chart-foot{display:flex;gap:16px;margin-top:8px;font-size:12px;color:var(--cap)}
.chart-foot b{color:var(--ink2);font-weight:600;font-variant-numeric:tabular-nums}

table{width:100%;border-collapse:collapse}
th{font-size:11px;font-weight:500;letter-spacing:.06em;color:var(--cap);text-align:left;
  padding:0 10px 8px;border-bottom:1px solid var(--line);white-space:nowrap}
td{padding:10px;border-bottom:1px solid var(--line);white-space:nowrap;color:var(--ink2)}
tbody tr:last-child td{border-bottom:0}
tbody tr{transition:background .12s}
tbody tr:hover td{background:var(--panel2)}
th.r,td.r{text-align:right}
td.id{color:var(--ink)}
.empty{padding:28px 10px;text-align:center;color:var(--cap);font-size:12.5px}
.bar{display:inline-block;vertical-align:middle;width:92px;height:4px;border-radius:999px;
  background:var(--line2);overflow:hidden}
.bar i{display:block;height:100%;background:var(--accent)}
.bar i.warn{background:var(--warn)}
.bar i.bad{background:var(--bad)}
.btn{height:26px;padding:0 10px;border:1px solid var(--line2);border-radius:7px;font-size:12px;
  color:var(--ink2);background:transparent;transition:border-color .12s,color .12s,background .12s}
.btn:hover{border-color:var(--accent);color:var(--accent);background:var(--accent-soft)}
.btn.danger:hover{border-color:var(--bad);color:var(--bad);
  background:color-mix(in srgb,var(--bad) 12%,transparent)}
.btn + .btn{margin-left:6px}
.tag{display:inline-flex;align-items:center;gap:6px;height:22px;padding:0 9px;border-radius:999px;
  font-size:11.5px;border:1px solid var(--line2);color:var(--ink3)}
.tag.ok{color:var(--ok);border-color:color-mix(in srgb,var(--ok) 38%,transparent);
  background:color-mix(in srgb,var(--ok) 10%,transparent)}
.tag.bad{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 38%,transparent);
  background:color-mix(in srgb,var(--bad) 10%,transparent)}
.two{display:grid;gap:16px;grid-template-columns:repeat(2,minmax(0,1fr))}
.kv{display:flex;flex-direction:column;gap:8px;font-size:13px;color:var(--ink2)}
.kv .row{display:flex;gap:10px}
.kv .row span:first-child{color:var(--cap);min-width:64px}
.hintline{margin:10px 0 0;font-size:12px;color:var(--cap);line-height:1.6}
@media (max-width:1080px){ .kpis{grid-template-columns:repeat(2,minmax(0,1fr))} .two{grid-template-columns:1fr} }
@media (max-width:860px){
  .app{flex-direction:column}
  .side{width:auto;height:auto;position:static;flex-direction:row;align-items:center;
    gap:12px;padding:10px 14px;overflow-x:auto}
  .brand span{display:none}
  nav{flex-direction:row;gap:4px}
  nav a{padding:6px 9px;font-size:13px}
  nav em{display:none}
  .sidefoot{display:none}
  .topbar{padding:12px 14px}
  .content{padding:14px}
  .card .body{overflow-x:auto}
}
@media (prefers-reduced-motion:reduce){ *{transition:none!important} }
</style>
</head>
<body>

<div id="login" class="login">
  <form id="login-form" class="login-card" autocomplete="on">
    <div class="mark">
      <svg viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round">
        <rect x="3" y="4" width="6" height="6" rx="1.6"/><rect x="15" y="14" width="6" height="6" rx="1.6"/>
        <path d="M9 7h4a2 2 0 0 1 2 2v1"/><path d="M15 17h-4a2 2 0 0 1-2-2v-1"/>
      </svg>
    </div>
    <h1>DSH 中转</h1>
    <p class="sub">控制台 · 需要管理令牌</p>
    <label class="field">
      <span>管理令牌</span>
      <input id="token" type="password" name="token" autocomplete="current-password"
             placeholder="粘贴签发时那串 22 位令牌" spellcheck="false">
    </label>
    <button id="login-btn" class="primary" type="submit">登录</button>
    <p id="login-error" class="error" hidden></p>
    <p class="hint">服务器上用 <code>--issue-admin &lt;id&gt;</code> 签发的令牌，只显示一次；
      服务器只存它的 sha256 —— 丢了就重签一串，旧的立即失效。</p>
  </form>
</div>

<div id="app" class="app" hidden>
  <aside class="side">
    <div class="brand">
      <div class="mark">
        <svg viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round">
          <rect x="3" y="4" width="6" height="6" rx="1.6"/><rect x="15" y="14" width="6" height="6" rx="1.6"/>
          <path d="M9 7h4a2 2 0 0 1 2 2v1"/><path d="M15 17h-4a2 2 0 0 1-2-2v-1"/>
        </svg>
      </div>
      <div><b>DSH 中转</b><span>relay console</span></div>
    </div>
    <nav id="nav">
      <a href="#/overview" data-view="overview">概览<em id="n-overview"></em></a>
      <a href="#/connectors" data-view="connectors">连接器<em id="n-connectors"></em></a>
      <a href="#/channels" data-view="channels">通道<em id="n-channels"></em></a>
      <a href="#/usage" data-view="usage">用量<em id="n-usage"></em></a>
      <a href="#/tokens" data-view="tokens">令牌<em id="n-tokens"></em></a>
      <a href="#/events" data-view="events">动态<em id="n-events"></em></a>
    </nav>
    <div class="sidefoot">
      <span id="pill" class="pill"><i class="dot"></i><span id="pill-text">连接中…</span></span>
      <div class="cap" id="uptime">—</div>
    </div>
  </aside>
  <div class="main">
    <header class="topbar">
      <div>
        <h1 id="view-title">概览</h1>
        <p id="view-sub"></p>
      </div>
      <div class="grow"></div>
      <button id="refresh" class="ghost" type="button">刷新</button>
      <button id="logout" class="ghost" type="button">退出</button>
    </header>
    <div class="content" id="view"></div>
  </div>
</div>

<script>
(function () {
  var TOKEN_KEY = 'dsh.admin.token'
  var NS = 'http://www.w3.org/2000/svg'
  var loginEl = document.getElementById('login')
  var appEl = document.getElementById('app')
  var tokenInput = document.getElementById('token')
  var errorEl = document.getElementById('login-error')
  var pill = document.getElementById('pill')
  var pillText = document.getElementById('pill-text')
  var viewEl = document.getElementById('view')
  var titleEl = document.getElementById('view-title')
  var subEl = document.getElementById('view-sub')
  var uptimeEl = document.getElementById('uptime')
  var timer = null
  var lastState = null

  var VIEWS = {
    overview: ['概览', '这台中转此刻在做什么'],
    connectors: ['连接器', '已连上来的电脑（控制面）'],
    channels: ['通道', '正在转发的一对一连接'],
    usage: ['用量', '按人（或按电脑）的流量与本周期上限'],
    tokens: ['令牌', '谁能连这台中转'],
    events: ['动态', '最近发生在这台中转上的事（只记元数据）']
  }

  var EVENT_LABELS = {
    'connector.open': '电脑连上',
    'connector.close': '电脑断开',
    'connector.id-mismatch': '身份不一致',
    'connector.error': '控制面错误',
    'roster.applied': '名册更新',
    'roster.refused': '名册被拒',
    'ticket.issued': '换票',
    'ticket.rejected': '换票被拒',
    'channel.open': '通道建立',
    'channel.close': '通道关闭',
    'admission.rejected': '准入拒绝',
    'channel.error': '通道错误',
    'delivery.failed': '投递失败',
    'quota.rejected': '超限',
    'admin.action': '管理操作'
  }

  function describe(detail) {
    var parts = []
    if (detail.connectorId) parts.push(detail.connectorId)
    if (detail.deviceId) parts.push(detail.deviceId)
    if (detail.subject) parts.push(detail.subject)
    if (detail.action) parts.push(detail.action)
    if (detail.code) parts.push('关闭码 ' + detail.code)
    if (detail.reason) parts.push(detail.reason)
    if (detail.used !== undefined && detail.limit !== undefined) parts.push(bytes(detail.used) + ' / ' + bytes(detail.limit))
    else if (detail.bytes) parts.push(bytes(detail.bytes))
    if (detail.actor) parts.push('操作人 ' + detail.actor)
    return parts.join(' · ')
  }

  function viewOf() {
    var hash = (location.hash || '').replace('#/', '')
    return VIEWS[hash] ? hash : 'overview'
  }
  function token() { return sessionStorage.getItem(TOKEN_KEY) || '' }
  function headers() {
    var value = token()
    return value === '' ? {} : { authorization: 'Bearer ' + value }
  }
  function el(tag, text, className) {
    var node = document.createElement(tag)
    if (text !== undefined) node.textContent = text
    if (className) node.className = className
    return node
  }
  function svgEl(tag, attrs) {
    var node = document.createElementNS(NS, tag)
    Object.keys(attrs).forEach(function (key) { node.setAttribute(key, attrs[key]) })
    return node
  }
  function btn(text, onClick, danger) {
    var node = el('button', text, 'btn' + (danger ? ' danger' : ''))
    node.type = 'button'
    node.addEventListener('click', onClick)
    return node
  }
  function table(headers2, rows, emptyText) {
    if (rows.length === 0) return el('div', emptyText || '暂无数据', 'empty')
    var table = el('table')
    var head = el('tr')
    headers2.forEach(function (name) {
      var numeric = typeof name === 'string' && name.charAt(0) === '#'
      head.appendChild(el('th', numeric ? name.slice(1) : name, numeric ? 'r' : ''))
    })
    var thead = el('thead'); thead.appendChild(head); table.appendChild(thead)
    var tbody = el('tbody')
    rows.forEach(function (cells) {
      var row = el('tr')
      cells.forEach(function (value, index) {
        var numeric = headers2[index] && headers2[index].charAt(0) === '#'
        var td = el('td', undefined, numeric ? 'r num' : '')
        if (headers2[index] === 'id') td.className = 'id mono'
        if (value instanceof Node) td.appendChild(value)
        else td.textContent = value
        row.appendChild(td)
      })
      tbody.appendChild(row)
    })
    table.appendChild(tbody)
    return table
  }
  function bytes(n) {
    if (typeof n !== 'number') return '—'
    if (n >= 1073741824) return (n / 1073741824).toFixed(1) + ' GB'
    if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB'
    if (n >= 1024) return (n / 1024).toFixed(1) + ' KB'
    return n + ' B'
  }
  function duration(ms) {
    var seconds = Math.max(0, Math.round(ms / 1000))
    if (seconds < 90) return seconds + ' 秒'
    if (seconds < 5400) return Math.round(seconds / 60) + ' 分'
    if (seconds < 172800) return Math.round(seconds / 3600) + ' 小时'
    return Math.round(seconds / 86400) + ' 天'
  }
  function ago(ts) { return duration(Date.now() - ts) + '前' }
  function setPill(state, text) {
    pill.className = 'pill' + (state === 'ok' ? ' ok' : state === 'bad' ? ' bad' : '')
    pillText.textContent = text
  }
  function post(path, body) {
    return fetch(path, {
      method: 'POST',
      headers: Object.assign({ 'content-type': 'application/json' }, headers()),
      body: JSON.stringify(body || {})
    }).then(function (response) {
      if (response.status === 401) { toLogin('登录已失效，请重新输入令牌'); return null }
      return response.json().catch(function () { return {} }).then(function (data) {
        if (!response.ok) { alert((data && data.error) || ('操作失败 HTTP ' + response.status)); return null }
        return data
      })
    }).catch(function () { toLogin('连不上中转'); return null })
  }

  function toLogin(message) {
    if (timer !== null) { clearInterval(timer); timer = null }
    appEl.hidden = true
    loginEl.hidden = false
    errorEl.textContent = message || ''
    errorEl.hidden = !message
    if (document.activeElement !== tokenInput) tokenInput.focus()
  }
  function toApp() {
    loginEl.hidden = true
    appEl.hidden = false
    if (timer === null) timer = setInterval(refresh, 2000)
  }
  function refresh() {
    fetch('/admin/api/state', { headers: headers() }).then(function (response) {
      if (response.status === 401) { toLogin('令牌无效或已过期'); return null }
      if (!response.ok) { setPill('bad', 'HTTP ' + response.status); return null }
      return response.json()
    }).then(function (state) {
      if (!state) return
      toApp()
      setPill('ok', '已连接')
      lastState = state
      render(state)
    }).catch(function () { setPill('bad', '连不上中转') })
  }

  function sparkline(values) {
    var width = 600
    var height = 90
    var max = Math.max.apply(null, values.concat([1]))
    var points = []
    for (var index = 0; index < values.length; index += 1) {
      var x = values.length === 1 ? 0 : index * width / (values.length - 1)
      var y = height - 3 - values[index] / max * (height - 8)
      points.push(x.toFixed(1) + ',' + y.toFixed(1))
    }
    var svg = svgEl('svg', { viewBox: '0 0 ' + width + ' ' + height, preserveAspectRatio: 'none', class: 'spark' })
    svg.appendChild(svgEl('path', { class: 'area', d: 'M0,' + height + ' L' + points.join(' L') + ' L' + width + ',' + height + ' Z' }))
    svg.appendChild(svgEl('polyline', { class: 'line', points: points.join(' ') }))
    return svg
  }

  function render(state) {
    var activeTokens = state.tokens.filter(function (row) { return !row.revokedAt }).length
    var view = viewOf()
    document.querySelectorAll('#nav a').forEach(function (link) {
      link.className = link.getAttribute('data-view') === view ? 'active' : ''
    })
    titleEl.textContent = VIEWS[view][0]
    subEl.textContent = VIEWS[view][1]
    uptimeEl.textContent = '运行 ' + duration(state.uptimeMs) + ' · 每 2 秒刷新'
    document.getElementById('n-overview').textContent = ''
    document.getElementById('n-connectors').textContent = String(state.totals.connectors)
    document.getElementById('n-channels').textContent = String(state.totals.channels)
    document.getElementById('n-usage').textContent = state.quota ? String(state.quota.rows.length) : ''
    document.getElementById('n-tokens').textContent = String(activeTokens)
    document.getElementById('n-events').textContent = String(state.events.length)
    viewEl.textContent = ''

    if (view === 'overview') {
      var kpis = el('div', undefined, 'kpis')
      ;[
        ['在线连接器', state.totals.connectors, ''],
        ['活跃通道', state.totals.channels, ''],
        ['名册行数', state.roster.devices, ''],
        ['有效令牌', activeTokens + ' / ' + state.tokens.length, 'accent']
      ].forEach(function (item) {
        var box = el('div', undefined, 'kpi ' + item[2])
        box.appendChild(el('div', String(item[1]), 'v'))
        box.appendChild(el('div', item[0], 'k'))
        kpis.appendChild(box)
      })
      viewEl.appendChild(kpis)

      var chartCard = el('section', undefined, 'card')
      var chartHead = el('header')
      chartHead.appendChild(el('h2', '近 60 分钟转发'))
      chartHead.appendChild(el('span', '共 ' + bytes(state.traffic.total), 'meta'))
      chartCard.appendChild(chartHead)
      var chartBody = el('div', undefined, 'body chart')
      chartBody.appendChild(sparkline(state.traffic.perMinute))
      var foot = el('div', undefined, 'chart-foot')
      var peak = Math.max.apply(null, state.traffic.perMinute.concat([0]))
      var peakLine = el('span'); peakLine.appendChild(document.createTextNode('峰值 ')); peakLine.appendChild(el('b', bytes(peak))); foot.appendChild(peakLine)
      var last = state.traffic.perMinute[state.traffic.perMinute.length - 1] || 0
      var lastLine = el('span'); lastLine.appendChild(document.createTextNode('这一分钟 ')); lastLine.appendChild(el('b', bytes(last))); foot.appendChild(lastLine)
      chartBody.appendChild(foot)
      chartCard.appendChild(chartBody)
      viewEl.appendChild(chartCard)

      var two = el('div', undefined, 'two')
      var online = el('section', undefined, 'card')
      var onlineHead = el('header'); onlineHead.appendChild(el('h2', '在线的电脑')); onlineHead.appendChild(el('span', String(state.totals.connectors), 'meta')); online.appendChild(onlineHead)
      var onlineBody = el('div', undefined, 'body')
      onlineBody.appendChild(table(['连接器', '#连接时长', '#最后心跳'], state.connectors.map(function (row) {
        return [row.connectorId, duration(Date.now() - row.since), ago(row.lastPongAt)]
      }), '还没有电脑连上来 — DSH 一开就会自己连'))
      online.appendChild(onlineBody)
      two.appendChild(online)

      var summary = el('section', undefined, 'card')
      var sumHead = el('header'); sumHead.appendChild(el('h2', '名册与令牌')); summary.appendChild(sumHead)
      var sumBody = el('div', undefined, 'body')
      var kv = el('div', undefined, 'kv')
      ;[
        ['名册', state.roster.devices + ' 行（有归属 ' + state.roster.bound + ' 行）'],
        ['每台电脑', Object.keys(state.roster.published).length === 0 ? '还没有报名册'
          : Object.keys(state.roster.published).map(function (id) { return id + ' ' + state.roster.published[id] + ' 行' }).join('，')],
        ['令牌', '有效 ' + activeTokens + ' / 共 ' + state.tokens.length],
        ['上限策略', state.quota ? (state.quota.enforce === 'cut' ? '超限即断开' : state.quota.enforce === 'block' ? '超限只拒新建' : '只记账') : '—']
      ].forEach(function (pair) {
        var row = el('div', undefined, 'row')
        row.appendChild(el('span', pair[0]))
        row.appendChild(el('span', pair[1]))
        kv.appendChild(row)
      })
      sumBody.appendChild(kv)
      summary.appendChild(sumBody)
      two.appendChild(summary)
      viewEl.appendChild(two)
      return
    }

    if (view === 'connectors') {
      var card = el('section', undefined, 'card')
      var head = el('header'); head.appendChild(el('h2', '在线连接器')); head.appendChild(el('span', '共 ' + state.totals.connectors + ' 台', 'meta')); card.appendChild(head)
      var body = el('div', undefined, 'body')
      body.appendChild(table(['连接器', '所属人', '#连接时长', '#最后心跳', '#通道', ''], state.connectors.map(function (row) {
        return [row.connectorId, row.owner || '—', duration(Date.now() - row.since), ago(row.lastPongAt), String(row.channels),
          btn('断开', function () {
            if (!confirm('断开连接器 ' + row.connectorId + '？它的通道会一起关掉')) return
            post('/admin/api/disconnect', { connectorId: row.connectorId }).then(refresh)
          }, true)]
      }), '还没有连接器连上来 — 电脑上的 DSH 一开就会自己连'))
      card.appendChild(body)
      viewEl.appendChild(card)
      return
    }

    if (view === 'channels') {
      var channels = el('section', undefined, 'card')
      var chHead = el('header'); chHead.appendChild(el('h2', '活跃通道')); chHead.appendChild(el('span', '共 ' + state.totals.channels + ' 条', 'meta')); channels.appendChild(chHead)
      var chBody = el('div', undefined, 'body')
      chBody.appendChild(table(['电脑', '手机', '用途', '#已转发', '#起于', ''], state.channels.map(function (row) {
        return [row.connectorId, row.deviceId, el('span', row.purpose === 'paired' ? '业务' : '配对', 'tag'), bytes(row.forwardedBytes), duration(Date.now() - row.startedAt),
          btn('断开', function () {
            if (!confirm('断开这条通道？')) return
            post('/admin/api/disconnect', { connectorId: row.connectorId, deviceId: row.deviceId }).then(refresh)
          }, true)]
      }), '没有正在使用的通道'))
      channels.appendChild(chBody)
      viewEl.appendChild(channels)
      return
    }

    if (view === 'usage') {
      var usage = el('section', undefined, 'card')
      var uHead = el('header'); uHead.appendChild(el('h2', '用量与上限')); uHead.appendChild(el('span', state.quota ? (state.quota.period === 'month' ? '按月' : state.quota.period === 'day' ? '按天' : '不重置') : '', 'meta')); usage.appendChild(uHead)
      var uBody = el('div', undefined, 'body')
      var rows = state.quota ? state.quota.rows : []
      uBody.appendChild(table(['主体', '已用', '上限', ''], rows.map(function (row) {
        var used = el('span', bytes(row.used), 'num')
        if (row.limit !== null && row.used >= row.limit) used.style.color = 'var(--bad)'
        var limitCell = el('span')
        limitCell.appendChild(el('span', row.limit === null ? '不限制' : bytes(row.limit)))
        if (row.limit !== null) {
          var bar = el('span', undefined, 'bar')
          var fill = el('i')
          var ratio = Math.min(100, Math.round(row.used * 100 / row.limit))
          fill.style.width = ratio + '%'
          if (ratio >= 100) fill.className = 'bad'
          else if (ratio >= 80) fill.className = 'warn'
          bar.appendChild(fill)
          limitCell.appendChild(document.createTextNode(' '))
          limitCell.appendChild(bar)
        }
        var actions = el('span')
        actions.appendChild(btn(row.limit === null ? '设上限' : '改上限', function () {
          var next = prompt('上限（字节）；留空 = 取消上限', row.limit === null ? '' : String(row.limit))
          if (next === null) return
          var trimmed = next.trim()
          if (trimmed === '') { post('/admin/api/quota', { subject: row.subject, bytes: null }).then(refresh); return }
          var value = parseInt(trimmed, 10)
          if (!isFinite(value) || value <= 0) { alert('要一个正整数（字节），或留空取消'); return }
          post('/admin/api/quota', { subject: row.subject, bytes: value }).then(refresh)
        }))
        actions.appendChild(btn('重置', function () {
          if (!confirm('把 ' + row.subject + ' 的本期用量归零？')) return
          post('/admin/api/quota/reset', { subject: row.subject }).then(refresh)
        }))
        return [row.subject, used, limitCell, actions]
      }), '还没有人用过 — 默认不限制，谁都没有上限'))
      var note = el('p', '默认不限制：计入用量只用于观察；给某人设了上限才会挡住他。按人算（owner）—— 没配 owner 就按电脑算。', 'hintline')
      uBody.appendChild(note)
      usage.appendChild(uBody)
      viewEl.appendChild(usage)
      return
    }

    if (view === 'events') {
      var eventsCard = el('section', undefined, 'card')
      var eHead = el('header'); eHead.appendChild(el('h2', '最近事件')); eHead.appendChild(el('span', String(state.events.length) + ' 条（最多留 100）', 'meta')); eventsCard.appendChild(eHead)
      var eBody = el('div', undefined, 'body')
      eBody.appendChild(table(['时间', '事件', '对象与细节'], state.events.map(function (row) {
        var label = EVENT_LABELS[row.evt] || row.evt
        var tag = el('span', label, 'tag' + (row.level === 'warn' || row.level === 'error' ? ' bad' : ''))
        return [new Date(row.at).toLocaleTimeString(), tag, describe(row.detail || {})]
      }), '还没有事件 — 有人连上来就会有'))
      eventsCard.appendChild(eBody)
      viewEl.appendChild(eventsCard)
      return
    }

    var tokens = el('section', undefined, 'card')
    var tHead = el('header'); tHead.appendChild(el('h2', '连接器令牌')); tHead.appendChild(el('span', '有效 ' + activeTokens + ' / ' + state.tokens.length, 'meta')); tokens.appendChild(tHead)
    var tBody = el('div', undefined, 'body')
    tBody.appendChild(table(['id', '所属人', '状态', ''], state.tokens.map(function (row) {
      var actions = el('span')
      if (row.revokedAt) {
        actions.appendChild(btn('恢复', function () {
          if (!confirm('恢复令牌 ' + row.id + '？') ) return
          post('/admin/api/tokens/restore', { id: row.id }).then(refresh)
        }))
        actions.appendChild(btn('删除', function () {
          if (!confirm('永久删除 ' + row.id + ' 的令牌记录？删了就查不到了（不可恢复）')) return
          post('/admin/api/tokens/remove', { id: row.id }).then(refresh)
        }, true))
      } else {
        actions.appendChild(btn('吊销', function () {
          if (!confirm('吊销令牌 ' + row.id + '？吊销后它立刻下线；要彻底删掉，先吊销再删除')) return
          post('/admin/api/tokens/revoke', { id: row.id }).then(refresh)
        }, true))
      }
      return [row.id, row.owner || '—', el('span', row.revokedAt ? '已吊销' : '有效', 'tag ' + (row.revokedAt ? 'bad' : 'ok')), actions]
    }), '还没有连接器令牌'))
    tokens.appendChild(tBody)
    viewEl.appendChild(tokens)
  }

  document.getElementById('login-form').addEventListener('submit', function (event) {
    event.preventDefault()
    var value = tokenInput.value.trim()
    if (value === '') { errorEl.textContent = '请输入管理令牌'; errorEl.hidden = false; return }
    sessionStorage.setItem(TOKEN_KEY, value)
    errorEl.hidden = true
    refresh()
  })
  document.getElementById('logout').addEventListener('click', function () {
    sessionStorage.removeItem(TOKEN_KEY)
    tokenInput.value = ''
    toLogin(null)
  })
  document.getElementById('refresh').addEventListener('click', refresh)
  window.addEventListener('hashchange', function () { if (lastState) render(lastState) })

  if (token() === '') toLogin(null)
  else refresh()
})()
</script>
</body>
</html>`
