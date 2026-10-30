/**
 * 管理面页面：**单文件、内联、无外链**（中转没有构建步骤，见 `relay/Dockerfile`）。
 *
 * ## 视觉基线 = DSH 自己的深色 token
 *
 * 颜色不是"看着还行"，而是照 `app/lib/theme/dsh_colors.dart`（抽自 DSH
 * `ui-theme` 的 design-platform.css）抄过来的那一套：底色 `#151517`、
 * 卡片 `#232324`、抬升 `#2C2C2E`、发丝边白 6%/12%、文字四档
 * `#F9FAFB/#CFD3D6/#ADB2B8/#81858C`、强调 `#5686FE`、
 * 状态 `#22C55E/#F59E0B/#F25A5A`。面板与手机端/DSH 是同一套语言，不是自创一套。
 *
 * **只有深色**：DSH 的默认套就是深色，运维面板又常年待在终端/服务器场景；
 * 做两套主题会让这张单文件的每一处颜色都要写两遍，收益只是"眼缘"。
 *
 * ## 两屏
 *
 * 1. **登录屏**：一张卡、一个令牌输入。拿到令牌前**不渲染任何看板**
 *    ——"打开 URL 就看到一半界面"会让人以为这东西没登录。
 * 2. **看板**：令牌有效才出现；2 s 轮询；任何一次 401 退回登录屏。
 *
 * 不做用户名：中转只有一个管理身份（`admin.id`），多一个填了也校验不了的格子只让人猜。
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
<meta name="color-scheme" content="dark">
<title>DSH 中转 · 管理</title>
<style>
:root{
  --bg:#151517; --rail:#1b1b1c; --layer1:#232324; --layer2:#2c2c2e; --layer3:#353638;
  --line1:rgba(255,255,255,.06); --line2:rgba(255,255,255,.12); --line3:rgba(255,255,255,.16);
  --ink:#f9fafb; --ink2:#cfd3d6; --ink3:#adb2b8; --cap:#81858c;
  --accent:#5686fe; --accent-soft:rgba(86,134,254,.14);
  --ok:#22c55e; --warn:#f59e0b; --bad:#f25a5a;
  --r:12px; --dur:120ms;
}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--ink);
  font:14px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans SC",sans-serif;
  -webkit-font-smoothing:antialiased}
::selection{background:var(--accent-soft)}
button{font:inherit;color:inherit;cursor:pointer;background:none;border:0}
input{font:inherit}
[hidden]{display:none!important}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:6px}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace;font-size:12.5px}
.num{font-variant-numeric:tabular-nums}
.cap{font-size:12px;color:var(--cap)}

/* ---------------- 登录 ---------------- */
.login{min-height:100%;display:grid;place-items:center;padding:24px;
  background:
    radial-gradient(900px 480px at 50% -10%,rgba(86,134,254,.16),transparent 70%),
    radial-gradient(700px 400px at 90% 110%,rgba(86,134,254,.06),transparent 70%),
    var(--bg)}
.login-card{width:min(400px,100%);background:var(--layer1);border:1px solid var(--line2);
  border-radius:16px;padding:32px 28px 26px;box-shadow:0 24px 60px rgba(0,0,0,.45)}
.brandmark{width:34px;height:34px;border-radius:9px;display:grid;place-items:center;
  background:var(--accent-soft);border:1px solid rgba(86,134,254,.35);color:var(--accent);
  font-weight:700;font-size:15px;margin-bottom:18px}
.login-card h1{font-size:19px;margin:0 0 6px;letter-spacing:.2px;font-weight:650}
.login-card .sub{margin:0 0 22px;color:var(--cap);font-size:13px}
.field{display:block;margin:0 0 16px}
.field span{display:block;font-size:12px;color:var(--ink3);margin:0 0 7px}
.field input{width:100%;padding:11px 13px;border:1px solid var(--line2);border-radius:10px;
  background:var(--rail);color:var(--ink);outline:none;transition:border-color var(--dur),box-shadow var(--dur)}
.field input::placeholder{color:#5c6068}
.field input:focus{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
.primary{width:100%;padding:11px 13px;border-radius:10px;background:var(--accent);
  color:#0f1115;font-weight:650;transition:filter var(--dur)}
.primary:hover{filter:brightness(1.06)}
.primary:disabled{opacity:.55}
.error{margin:14px 0 0;padding:9px 11px;border-radius:9px;font-size:13px;
  background:rgba(242,90,90,.12);border:1px solid rgba(242,90,90,.3);color:#ffb4b4}
.hint{margin:18px 0 0;color:var(--cap);font-size:12px;line-height:1.7}
.hint code{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11.5px;
  background:var(--layer2);border:1px solid var(--line1);border-radius:5px;padding:1px 5px}

/* ---------------- 看板 ---------------- */
.topbar{position:sticky;top:0;z-index:9;display:flex;align-items:center;gap:14px;
  height:56px;padding:0 22px;background:color-mix(in srgb,var(--bg) 86%,transparent);
  backdrop-filter:blur(10px);border-bottom:1px solid var(--line1)}
.topbar .brandmark{width:24px;height:24px;border-radius:7px;font-size:12px;margin:0}
.title{font-weight:650;letter-spacing:.2px}
.title .sep{color:var(--line3);margin:0 8px}
.title .cap{font-size:12.5px}
.grow{flex:1}
.pill{display:inline-flex;align-items:center;gap:7px;height:26px;padding:0 11px;border-radius:999px;
  border:1px solid var(--line2);background:var(--layer1);font-size:12px;color:var(--ink3)}
.dot{width:7px;height:7px;border-radius:50%;background:var(--cap);flex:none}
.pill.ok .dot{background:var(--ok);box-shadow:0 0 0 3px rgba(34,197,94,.15)}
.pill.bad .dot{background:var(--bad);box-shadow:0 0 0 3px rgba(242,90,90,.15)}
.ghost{height:28px;padding:0 12px;border:1px solid var(--line2);border-radius:8px;
  font-size:12.5px;color:var(--ink2);background:var(--layer1);transition:border-color var(--dur),color var(--dur)}
.ghost:hover{border-color:var(--accent);color:var(--accent)}

main{max-width:1320px;margin:0 auto;padding:22px;display:grid;gap:14px;
  grid-template-columns:repeat(12,minmax(0,1fr))}
.card{grid-column:span 6;background:var(--layer1);border:1px solid var(--line1);
  border-radius:var(--r);min-width:0;overflow:hidden}
.card.wide{grid-column:span 12}
.card header{display:flex;align-items:baseline;gap:10px;padding:15px 18px 11px}
.card h2{margin:0;font-size:12.5px;font-weight:600;color:var(--ink3);letter-spacing:.04em}
.card .meta{margin-left:auto;font-size:11.5px;color:var(--cap);font-variant-numeric:tabular-nums}
.card .body{padding:0 18px 16px}

.kpis{grid-column:span 12;display:grid;gap:14px;grid-template-columns:repeat(4,minmax(0,1fr))}
.kpi{background:var(--layer1);border:1px solid var(--line1);border-radius:var(--r);padding:14px 16px}
.kpi .v{font-size:24px;font-weight:650;letter-spacing:.2px;font-variant-numeric:tabular-nums}
.kpi .k{margin-top:2px;font-size:12px;color:var(--cap)}

table{width:100%;border-collapse:collapse}
th{font-size:11px;font-weight:500;letter-spacing:.06em;color:var(--cap);text-align:left;
  padding:0 10px 8px;border-bottom:1px solid var(--line1);white-space:nowrap}
td{padding:9px 10px;border-bottom:1px solid var(--line1);white-space:nowrap;color:var(--ink2)}
tbody tr:last-child td{border-bottom:0}
tbody tr{transition:background var(--dur)}
tbody tr:hover td{background:rgba(255,255,255,.03)}
th.r,td.r{text-align:right}
td.id{color:var(--ink)}
.empty{padding:26px 10px;text-align:center;color:var(--cap);font-size:12.5px}
.bar{display:inline-block;vertical-align:middle;width:96px;height:4px;border-radius:999px;
  background:var(--line2);overflow:hidden}
.bar i{display:block;height:100%;background:var(--accent)}
.bar i.warn{background:var(--warn)}
.bar i.bad{background:var(--bad)}
.btn{height:26px;padding:0 10px;border:1px solid var(--line2);border-radius:7px;font-size:12px;
  color:var(--ink2);background:transparent;transition:border-color var(--dur),color var(--dur),background var(--dur)}
.btn:hover{border-color:var(--accent);color:var(--accent);background:var(--accent-soft)}
.btn.danger:hover{border-color:var(--bad);color:#ffb4b4;background:rgba(242,90,90,.12)}
.btn + .btn{margin-left:6px}
.tag{display:inline-flex;align-items:center;gap:6px;height:22px;padding:0 9px;border-radius:999px;
  font-size:11.5px;border:1px solid var(--line2);color:var(--ink3)}
.tag.ok{color:#9be8b8;border-color:rgba(34,197,94,.35);background:rgba(34,197,94,.1)}
.tag.bad{color:#ffb4b4;border-color:rgba(242,90,90,.35);background:rgba(242,90,90,.1)}
.roster{display:flex;flex-direction:column;gap:6px;color:var(--ink2);font-size:13px}
.roster .per{color:var(--cap);font-size:12px}

@media (max-width:1100px){ .kpis{grid-template-columns:repeat(2,minmax(0,1fr))} }
@media (max-width:860px){
  main{padding:14px;gap:12px}
  .card,.card.wide{grid-column:span 12}
  .kpis{grid-template-columns:repeat(2,minmax(0,1fr))}
  .topbar{padding:0 14px;gap:10px}
  .title .sep,.title .cap{display:none}
  .card .body{overflow-x:auto}
}
@media (prefers-reduced-motion:reduce){ *{transition:none!important} }
</style>
</head>
<body>

<div id="login" class="login">
  <form id="login-form" class="login-card" autocomplete="on">
    <div class="brandmark">D</div>
    <h1>DSH 中转</h1>
    <p class="sub">管理面板 · 需要管理令牌</p>
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

<div id="app" hidden>
  <div class="topbar">
    <div class="brandmark">D</div>
    <div class="title">DSH 中转<span class="sep">/</span><span class="cap">管理面板</span></div>
    <div class="grow"></div>
    <span id="pill" class="pill"><i class="dot"></i><span id="pill-text">连接中…</span></span>
    <button id="logout" class="ghost" type="button">退出</button>
  </div>
  <main>
    <div class="kpis" id="kpis"></div>
    <section class="card wide">
      <header><h2>在线连接器</h2><span class="meta" id="meta-connectors"></span></header>
      <div class="body" id="connectors"></div>
    </section>
    <section class="card wide">
      <header><h2>活跃通道</h2><span class="meta" id="meta-channels"></span></header>
      <div class="body" id="channels"></div>
    </section>
    <section class="card">
      <header><h2>用量与上限</h2><span class="meta" id="meta-quota"></span></header>
      <div class="body" id="quota"></div>
    </section>
    <section class="card">
      <header><h2>名册</h2></header>
      <div class="body" id="roster"></div>
    </section>
    <section class="card wide">
      <header><h2>连接器令牌</h2><span class="meta" id="meta-tokens"></span></header>
      <div class="body" id="tokens"></div>
    </section>
  </main>
</div>

<script>
(function () {
  var TOKEN_KEY = 'dsh.admin.token'
  var loginEl = document.getElementById('login')
  var appEl = document.getElementById('app')
  var tokenInput = document.getElementById('token')
  var errorEl = document.getElementById('login-error')
  var pill = document.getElementById('pill')
  var pillText = document.getElementById('pill-text')
  var timer = null

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
  function btn(text, onClick, danger) {
    var node = el('button', text, 'btn' + (danger ? ' danger' : ''))
    node.type = 'button'
    node.addEventListener('click', onClick)
    return node
  }
  function table(headers, rows, emptyText) {
    if (rows.length === 0) return el('div', emptyText || '暂无数据', 'empty')
    var table = el('table')
    var head = el('tr')
    headers.forEach(function (name, index) {
      var numeric = typeof name === 'string' && name.charAt(0) === '#'
      var th = el('th', numeric ? name.slice(1) : name, numeric ? 'r' : '')
      head.appendChild(th)
    })
    var thead = el('thead'); thead.appendChild(head); table.appendChild(thead)
    var tbody = el('tbody')
    rows.forEach(function (cells) {
      var row = el('tr')
      cells.forEach(function (value, index) {
        var numeric = headers[index] && headers[index].charAt(0) === '#'
        var td = el('td', undefined, numeric ? 'r num' : '')
        if (headers[index] === 'id') td.className = 'id mono'
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
  function ago(ts) {
    var seconds = Math.max(0, Math.round((Date.now() - ts) / 1000))
    if (seconds < 90) return seconds + ' 秒'
    if (seconds < 5400) return Math.round(seconds / 60) + ' 分'
    return Math.round(seconds / 3600) + ' 小时'
  }
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
      setPill('ok', '已连接 · ' + new Date().toLocaleTimeString())
      render(state)
    }).catch(function () { setPill('bad', '连不上中转') })
  }

  function render(state) {
    var activeTokens = state.tokens.filter(function (row) { return !row.revokedAt }).length
    var kpis = [
      ['在线连接器', state.totals.connectors],
      ['活跃通道', state.totals.channels],
      ['名册行数', state.roster.devices],
      ['有效令牌', activeTokens + ' / ' + state.tokens.length]
    ]
    var kpiBox = document.getElementById('kpis')
    kpiBox.textContent = ''
    kpis.forEach(function (pair) {
      var box = el('div', undefined, 'kpi')
      box.appendChild(el('div', String(pair[1]), 'v'))
      box.appendChild(el('div', pair[0], 'k'))
      kpiBox.appendChild(box)
    })

    document.getElementById('meta-connectors').textContent = '共 ' + state.totals.connectors + ' 台'
    document.getElementById('meta-channels').textContent = '共 ' + state.totals.channels + ' 条'
    document.getElementById('meta-tokens').textContent = '有效 ' + activeTokens + ' / ' + state.tokens.length
    document.getElementById('meta-quota').textContent = state.quota
      ? (state.quota.enforce === 'cut' ? '超限即断开' : state.quota.enforce === 'block' ? '超限只拒新建' : '只记账')
      : ''

    document.getElementById('connectors').replaceChildren(table(
      ['连接器', '所属人', '#连接时长', '#最后心跳', '#通道', ''],
      state.connectors.map(function (row) {
        return [row.connectorId, row.owner || '—', ago(row.since), ago(row.lastPongAt) + '前', String(row.channels),
          btn('断开', function () {
            if (!confirm('断开连接器 ' + row.connectorId + '？它的通道会一起关掉')) return
            post('/admin/api/disconnect', { connectorId: row.connectorId }).then(refresh)
          }, true)]
      }),
      '还没有连接器连上来 —— 电脑上的 DSH 一开就会自己连'
    ))

    document.getElementById('channels').replaceChildren(table(
      ['电脑', '手机', '用途', '#已转发', '#起于', ''],
      state.channels.map(function (row) {
        var purpose = el('span', row.purpose === 'paired' ? '业务' : '配对', 'tag')
        return [row.connectorId, row.deviceId, purpose, bytes(row.forwardedBytes), ago(row.startedAt),
          btn('断开', function () {
            if (!confirm('断开这条通道？')) return
            post('/admin/api/disconnect', { connectorId: row.connectorId, deviceId: row.deviceId }).then(refresh)
          }, true)]
      }),
      '没有正在使用的通道'
    ))

    var quotaRows = state.quota ? state.quota.rows : []
    document.getElementById('quota').replaceChildren(table(
      ['主体', '已用', '上限', ''],
      quotaRows.map(function (row) {
        var used = el('span', bytes(row.used), 'num')
        if (row.limit !== null && row.used >= row.limit) used.style.color = 'var(--bad)'
        var bar = el('span', undefined, 'bar')
        var fill = el('i')
        var ratio = row.limit === null ? 0 : Math.min(100, Math.round(row.used * 100 / row.limit))
        fill.style.width = ratio + '%'
        if (ratio >= 100) fill.className = 'bad'
        else if (ratio >= 80) fill.className = 'warn'
        bar.appendChild(fill)
        var limitCell = el('span')
        limitCell.appendChild(el('span', row.limit === null ? '不限制' : bytes(row.limit)))
        if (row.limit !== null) { limitCell.appendChild(document.createTextNode(' ')); limitCell.appendChild(bar) }
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
      }),
      '还没有人用过 —— 默认不限制，谁都没有上限'
    ))

    var roster = state.roster
    var per = Object.keys(roster.published).map(function (id) { return id + '：' + roster.published[id] + ' 行' })
    var rosterBox = document.getElementById('roster')
    rosterBox.textContent = ''
    var box = el('div', undefined, 'roster')
    box.appendChild(el('div', '共 ' + roster.devices + ' 行 · 有归属 ' + roster.bound + ' 行'))
    box.appendChild(el('div', per.length === 0 ? '还没有连接器报名册' : per.join('　'), 'per'))
    rosterBox.appendChild(box)

    document.getElementById('tokens').replaceChildren(table(
      ['id', '所属人', '状态', ''],
      state.tokens.map(function (row) {
        var status = el('span', row.revokedAt ? '已吊销' : '有效',
          'tag ' + (row.revokedAt ? 'bad' : 'ok'))
        return [row.id, row.owner || '—', status,
          btn(row.revokedAt ? '恢复' : '吊销', function () {
            if (!confirm((row.revokedAt ? '恢复' : '吊销') + '令牌 ' + row.id + '？')) return
            post(row.revokedAt ? '/admin/api/tokens/restore' : '/admin/api/tokens/revoke', { id: row.id }).then(refresh)
          }, !row.revokedAt)]
      }),
      '还没有连接器令牌'
    ))
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

  if (token() === '') toLogin(null)
  else refresh()
})()
</script>
</body>
</html>`
