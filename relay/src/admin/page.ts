/**
 * 管理面页面：**单文件、内联、无外链**（中转没有构建步骤，见 `relay/Dockerfile`）。
 *
 * ## 两屏，不是一屏
 *
 * 1. **登录屏**：只有一张卡 + 一个令牌输入。拿到令牌之前**不渲染任何看板** ——
 *    "打开 URL 就看到一半界面"会让人以为这东西没登录。
 * 2. **看板**：令牌有效才出现；每 2 s 拉一次 `/admin/api/state`，
 *    任何一次 401 都退回登录屏（令牌被吊销/轮换时的正确表现）。
 *
 * 登录不做"用户名"：中转只有一个管理身份（`admin.id`），多一个填了也校验不了的格子
 * 只会让人猜。要多人/多角色，那是账号体系，不是这一批。
 *
 * ## 凭据怎么带
 *
 * 令牌存 `sessionStorage`，每次 `fetch` 放进 `Authorization` 头 —— **不设 cookie**，
 * 浏览器不会自动带凭据，CSRF 无从谈起；页面里也没有任何外链脚本能读它。
 *
 * Note: 为什么轮询而不是 WS/SSE、为什么独立凭据 —— 见
 * `.agents/notes/implemented/2026-10-30-relay-admin-panel.md`
 */
export const ADMIN_PAGE = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DSH 中转 · 管理</title>
<style>
:root{
  color-scheme:light dark;
  --bg:#f6f7f9; --panel:#ffffff; --line:#e6e8ec; --ink:#1b1f24; --mut:#6b7280;
  --accent:#2f6fed; --accent-ink:#ffffff; --warn:#c2410c; --ok:#15803d; --shadow:0 1px 2px rgba(16,24,40,.06),0 1px 3px rgba(16,24,40,.06);
}
@media (prefers-color-scheme:dark){
  :root{ --bg:#0f1115; --panel:#171a20; --line:#262b33; --ink:#e6e8ec; --mut:#9aa3af;
         --accent:#5b8def; --warn:#f97316; --ok:#4ade80; --shadow:none; }
}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--ink);
     font:14px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans SC",sans-serif;
     -webkit-font-smoothing:antialiased}
button{font:inherit;cursor:pointer}
input{font:inherit}
.num{font-variant-numeric:tabular-nums}
.muted{color:var(--mut)}
[hidden]{display:none!important}

/* ---------- 登录屏 ---------- */
.login{min-height:100%;display:grid;place-items:center;padding:24px}
.login-card{width:min(380px,100%);background:var(--panel);border:1px solid var(--line);
            border-radius:14px;padding:28px;box-shadow:var(--shadow)}
.login-card h1{font-size:18px;margin:0 0 4px;letter-spacing:.2px}
.login-card .sub{margin:0 0 20px;color:var(--mut);font-size:13px}
.field{display:block;margin:0 0 14px}
.field span{display:block;font-size:12px;color:var(--mut);margin:0 0 6px}
.field input{width:100%;padding:10px 12px;border:1px solid var(--line);border-radius:9px;
             background:var(--bg);color:var(--ink);outline:none}
.field input:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(47,111,237,.15)}
.primary{width:100%;padding:10px 12px;border:0;border-radius:9px;background:var(--accent);
         color:var(--accent-ink);font-weight:600}
.primary:disabled{opacity:.6;cursor:default}
.error{margin:12px 0 0;padding:8px 10px;border-radius:8px;background:rgba(194,65,12,.12);
       color:var(--warn);font-size:13px}
.hint{margin:16px 0 0;color:var(--mut);font-size:12px;line-height:1.6}

/* ---------- 看板 ---------- */
header{position:sticky;top:0;z-index:5;display:flex;align-items:center;gap:12px;
       padding:14px 20px;background:color-mix(in srgb,var(--bg) 88%,transparent);
       backdrop-filter:blur(8px);border-bottom:1px solid var(--line)}
.brand{font-weight:650;letter-spacing:.2px}
.brand .muted{font-weight:400;font-size:13px;margin-left:6px}
.spacer{flex:1}
.pill{display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--mut);
      border:1px solid var(--line);border-radius:999px;padding:3px 10px;background:var(--panel)}
.pill i{width:7px;height:7px;border-radius:50%;background:var(--mut);display:block}
.pill.ok i{background:var(--ok)}
.pill.bad i{background:var(--warn)}
.ghost{background:transparent;border:1px solid var(--line);color:var(--ink);
       border-radius:8px;padding:5px 10px;font-size:13px}
.ghost:hover{border-color:var(--accent);color:var(--accent)}
main{padding:20px;max-width:1280px;margin:0 auto;display:grid;gap:16px;
     grid-template-columns:repeat(2,minmax(0,1fr))}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;
      padding:16px 18px;box-shadow:var(--shadow);min-width:0}
.card.wide{grid-column:1/-1}
.card h2{margin:0 0 12px;font-size:13px;font-weight:600;color:var(--mut);
         text-transform:uppercase;letter-spacing:.6px}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);white-space:nowrap}
th{font-size:12px;font-weight:500;color:var(--mut)}
tr:last-child td{border-bottom:0}
tbody tr:hover td{background:color-mix(in srgb,var(--accent) 5%,transparent)}
td.r,th.r{text-align:right}
.empty{padding:18px 0;text-align:center;color:var(--mut);font-size:13px}
.bar{height:6px;border-radius:99px;background:var(--line);overflow:hidden;min-width:90px}
.bar i{display:block;height:100%;background:var(--accent)}
.bar i.warn{background:var(--warn)}
.rowbtn{background:transparent;border:1px solid var(--line);color:var(--ink);
        border-radius:7px;padding:3px 9px;font-size:12px;margin-right:6px}
.rowbtn:hover{border-color:var(--accent);color:var(--accent)}
.rowbtn.danger:hover{border-color:var(--warn);color:var(--warn)}
.tag{font-size:12px;padding:1px 7px;border-radius:999px;border:1px solid var(--line);color:var(--mut)}
.tag.ok{color:var(--ok);border-color:color-mix(in srgb,var(--ok) 40%,var(--line))}
.tag.bad{color:var(--warn);border-color:color-mix(in srgb,var(--warn) 40%,var(--line))}
@media (max-width:820px){ main{grid-template-columns:1fr} header{padding:12px 14px} main{padding:14px} }
</style>
</head>
<body>

<div id="login" class="login">
  <form id="login-form" class="login-card" autocomplete="on">
    <h1>DSH 中转</h1>
    <p class="sub">管理面板 · 需要管理令牌</p>
    <label class="field">
      <span>管理令牌</span>
      <input id="token" type="password" name="token" autocomplete="current-password"
             placeholder="粘贴签发时那串 22 位令牌" spellcheck="false">
    </label>
    <button id="login-btn" class="primary" type="submit">登录</button>
    <p id="login-error" class="error" hidden></p>
    <p class="hint">令牌在服务器上用 <span class="num">--issue-admin &lt;id&gt;</span> 签发，只显示一次；<br>
       服务器只存它的 sha256，丢了就重签一串（旧的立即失效）。</p>
  </form>
</div>

<div id="app" hidden>
  <header>
    <div class="brand">DSH 中转<span class="muted">管理面板</span></div>
    <div class="spacer"></div>
    <span id="pill" class="pill"><i></i><span id="pill-text">连接中…</span></span>
    <button id="logout" class="ghost" type="button">退出</button>
  </header>
  <main>
    <section class="card wide"><h2>在线连接器</h2><div id="connectors"></div></section>
    <section class="card wide"><h2>活跃通道</h2><div id="channels"></div></section>
    <section class="card"><h2>用量与上限</h2><div id="quota"></div></section>
    <section class="card"><h2>名册</h2><div id="roster"></div></section>
    <section class="card wide"><h2>连接器令牌</h2><div id="tokens"></div></section>
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
  function el(tag, text) {
    var node = document.createElement(tag)
    if (text !== undefined) node.textContent = text
    return node
  }
  function button(text, onClick, className) {
    var node = el('button', text)
    node.type = 'button'
    node.className = 'rowbtn' + (className ? ' ' + className : '')
    node.addEventListener('click', onClick)
    return node
  }
  function table(headers, rows) {
    if (rows.length === 0) { var empty = el('div', '暂无数据'); empty.className = 'empty'; return empty }
    var table = el('table')
    var thead = el('thead'); var head = el('tr')
    headers.forEach(function (name, index) {
      var th = el('th', name)
      if (index > 0 && typeof name === 'string' && name.charAt(0) === '#') {
        th.textContent = name.slice(1); th.className = 'r'
      }
      head.appendChild(th)
    })
    thead.appendChild(head); table.appendChild(thead)
    var tbody = el('tbody')
    rows.forEach(function (cells) {
      var row = el('tr')
      cells.forEach(function (value, index) {
        var td = el('td')
        if (index > 0 && headers[index] && headers[index].charAt(0) === '#') td.className = 'r num'
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
    if (message) { errorEl.textContent = message; errorEl.hidden = false }
    else { errorEl.hidden = true }
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
    document.getElementById('connectors').replaceChildren(table(
      ['连接器', '所属人', '#连接时长', '#最后心跳', '#通道', ''],
      state.connectors.map(function (row) {
        return [row.connectorId, row.owner || '—', ago(row.since), ago(row.lastPongAt) + '前', String(row.channels),
          button('断开', function () {
            if (!confirm('断开连接器 ' + row.connectorId + '？它的通道会一起关掉')) return
            post('/admin/api/disconnect', { connectorId: row.connectorId }).then(refresh)
          }, 'danger')]
      })
    ))

    document.getElementById('channels').replaceChildren(table(
      ['电脑', '手机', '用途', '#已转发', '#起于', ''],
      state.channels.map(function (row) {
        return [row.connectorId, row.deviceId, row.purpose === 'paired' ? '业务' : '配对',
          bytes(row.forwardedBytes), ago(row.startedAt),
          button('断开', function () {
            if (!confirm('断开这条通道？')) return
            post('/admin/api/disconnect', { connectorId: row.connectorId, deviceId: row.deviceId }).then(refresh)
          }, 'danger')]
      })
    ))

    var quotaRows = state.quota ? state.quota.rows : []
    document.getElementById('quota').replaceChildren(table(
      ['主体', '已用', '上限', ''],
      quotaRows.map(function (row) {
        var used = el('span', bytes(row.used))
        if (row.limit !== null && row.used >= row.limit) used.style.color = 'var(--warn)'
        var bar = el('div'); bar.className = 'bar'
        var fill = el('i')
        var ratio = row.limit === null ? 0 : Math.min(100, Math.round(row.used * 100 / row.limit))
        fill.style.width = ratio + '%'
        if (ratio >= 100) fill.className = 'warn'
        bar.appendChild(fill)
        var limitCell = el('span')
        limitCell.appendChild(el('span', row.limit === null ? '不限制' : bytes(row.limit)))
        limitCell.appendChild(document.createTextNode(' '))
        limitCell.appendChild(bar)
        var actions = el('span')
        actions.appendChild(button(row.limit === null ? '设上限' : '改上限', function () {
          var next = prompt('上限（字节）；留空 = 取消上限', row.limit === null ? '' : String(row.limit))
          if (next === null) return
          var trimmed = next.trim()
          if (trimmed === '') { post('/admin/api/quota', { subject: row.subject, bytes: null }).then(refresh); return }
          var value = parseInt(trimmed, 10)
          if (!isFinite(value) || value <= 0) { alert('要一个正整数（字节），或留空取消'); return }
          post('/admin/api/quota', { subject: row.subject, bytes: value }).then(refresh)
        }))
        actions.appendChild(button('重置', function () {
          if (!confirm('把 ' + row.subject + ' 的本期用量归零？')) return
          post('/admin/api/quota/reset', { subject: row.subject }).then(refresh)
        }))
        return [row.subject, used, limitCell, actions]
      })
    ))

    var roster = state.roster
    var per = Object.keys(roster.published).map(function (id) { return id + '：' + roster.published[id] + ' 行' })
    var rosterBox = document.getElementById('roster')
    rosterBox.replaceChildren(
      el('div', '共 ' + roster.devices + ' 行 · 有归属 ' + roster.bound + ' 行'),
      el('div', per.length === 0 ? '还没有连接器报名册' : per.join('　'))
    )
    rosterBox.lastChild.className = 'muted'

    document.getElementById('tokens').replaceChildren(table(
      ['id', '所属人', '状态', ''],
      state.tokens.map(function (row) {
        var status = el('span', row.revokedAt ? '已吊销' : '有效')
        status.className = 'tag ' + (row.revokedAt ? 'bad' : 'ok')
        return [row.id, row.owner || '—', status,
          button(row.revokedAt ? '恢复' : '吊销', function () {
            if (!confirm((row.revokedAt ? '恢复' : '吊销') + '令牌 ' + row.id + '？')) return
            post(row.revokedAt ? '/admin/api/tokens/restore' : '/admin/api/tokens/revoke', { id: row.id }).then(refresh)
          }, row.revokedAt ? '' : 'danger')]
      })
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
