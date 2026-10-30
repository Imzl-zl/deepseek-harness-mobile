/**
 * 管理面页面：**单文件、内联、无外链**（中转没有构建步骤，见 `relay/Dockerfile`）。
 *
 * ## 为什么不是前端工程
 *
 * 页面的全部职责是"把 `/admin/api/state` 画出来 + 点四个按钮"。引入打包链会打破
 * 中转"`node src/main.ts` 直接跑"的形态；而单文件带来的 CSP 更简单：
 * `default-src 'none'` 之外只放行内联样式与脚本。
 *
 * ## 凭据怎么带
 *
 * 令牌存在 `sessionStorage`，每次 `fetch` 放进 `Authorization` 头 —— **不设 cookie**，
 * 所以浏览器不会自动带凭据，CSRF 无从谈起；页面里也没有任何外链脚本可读它。
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
:root{color-scheme:light dark}
body{font:14px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;padding:16px;background:#fafafa;color:#1a1a1a}
@media (prefers-color-scheme:dark){body{background:#111;color:#eee}.card{background:#1b1b1b;border-color:#333}th{color:#999}td{border-color:#2a2a2a}}
h1{font-size:18px;margin:0}
h2{font-size:14px;margin:0 0 8px;color:#666}
.card{background:#fff;border:1px solid #ddd;border-radius:8px;padding:12px;margin:0 0 12px}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{text-align:left;padding:4px 8px;border-bottom:1px solid #eee}
th{color:#777;font-weight:500}
header{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:12px}
input{font:inherit;padding:4px 6px}
button{font:inherit;padding:2px 8px;cursor:pointer}
.muted{color:#888}
.empty{color:#888;padding:8px 0}
</style>
</head>
<body>
<header>
  <h1>DSH 中转</h1>
  <input id="token" type="password" placeholder="管理令牌" size="26" autocomplete="off">
  <button id="save">保存令牌</button>
  <span id="status" class="muted">未连接</span>
</header>

<div class="card"><h2>在线连接器</h2><div id="connectors" class="muted">未加载</div></div>
<div class="card"><h2>活跃通道</h2><div id="channels" class="muted">未加载</div></div>
<div class="card"><h2>按人额度</h2><div id="quota" class="muted">未配置额度</div></div>
<div class="card"><h2>名册</h2><div id="roster" class="muted">未加载</div></div>
<div class="card"><h2>令牌</h2><div id="tokens" class="muted">未加载</div></div>

<script>
(function () {
  var TOKEN_KEY = 'dsh.admin.token'
  var statusEl = document.getElementById('status')
  var input = document.getElementById('token')
  input.value = sessionStorage.getItem(TOKEN_KEY) || ''

  function headers() {
    var token = sessionStorage.getItem(TOKEN_KEY) || ''
    return token === '' ? {} : { authorization: 'Bearer ' + token }
  }
  function el(tag, text) {
    var node = document.createElement(tag)
    if (text !== undefined) node.textContent = text
    return node
  }
  function button(text, onClick) {
    var node = el('button', text)
    node.addEventListener('click', onClick)
    return node
  }
  function table(headers, rows) {
    if (rows.length === 0) {
      var empty = el('div', '没有数据')
      empty.className = 'empty'
      return empty
    }
    var table = el('table')
    var head = el('tr')
    headers.forEach(function (name) { head.appendChild(el('th', name)) })
    var thead = el('thead'); thead.appendChild(head); table.appendChild(thead)
    var tbody = el('tbody')
    rows.forEach(function (cells) {
      var row = el('tr')
      cells.forEach(function (value) {
        var td = el('td')
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
  function post(path, body) {
    return fetch(path, {
      method: 'POST',
      headers: Object.assign({ 'content-type': 'application/json' }, headers()),
      body: JSON.stringify(body || {})
    }).then(function (response) {
      return response.json().catch(function () { return {} }).then(function (data) {
        return { ok: response.ok, status: response.status, data: data }
      })
    })
  }
  function refresh() {
    fetch('/admin/api/state', { headers: headers() }).then(function (response) {
      if (response.status === 401) { statusEl.textContent = '令牌无效'; return null }
      if (!response.ok) { statusEl.textContent = 'HTTP ' + response.status; return null }
      return response.json()
    }).then(function (state) { if (state) render(state) }).catch(function () { statusEl.textContent = '连不上中转' })
  }

  function render(state) {
    statusEl.textContent = '已连接 · ' + new Date().toLocaleTimeString()

    document.getElementById('connectors').replaceChildren(table(
      ['id', '人', '连接时长', '最后心跳', '通道', '操作'],
      state.connectors.map(function (row) {
        return [row.connectorId, row.owner || '—', ago(row.since), ago(row.lastPongAt) + '前', String(row.channels),
          button('断开', function () {
            if (!confirm('断开连接器 ' + row.connectorId + '？它的通道会一起关掉')) return
            post('/admin/api/disconnect', { connectorId: row.connectorId }).then(refresh)
          })]
      })
    ))

    document.getElementById('channels').replaceChildren(table(
      ['电脑', '设备', '用途', '已转发', '起', '操作'],
      state.channels.map(function (row) {
        return [row.connectorId, row.deviceId, row.purpose === 'paired' ? '业务' : '配对', bytes(row.forwardedBytes), ago(row.startedAt),
          button('断开', function () {
            if (!confirm('断开这条通道？')) return
            post('/admin/api/disconnect', { connectorId: row.connectorId, deviceId: row.deviceId }).then(refresh)
          })]
      })
    ))

    var quotaBox = document.getElementById('quota')
    if (!state.quota) {
      quotaBox.textContent = '未配置额度（quota 段不存在）'
    } else {
      quotaBox.replaceChildren(table(
        ['主体', '已用 / 额度（' + state.quota.enforce + '）', '操作'],
        state.quota.rows.map(function (row) {
          var used = el('span', bytes(row.used) + ' / ' + bytes(row.limit))
          if (row.used >= row.limit) { used.className = 'warn'; used.textContent += ' · 已用满' }
          var actions = el('span')
          actions.appendChild(button('改额度', function () {
            var next = prompt('新的额度（字节）', String(row.limit))
            if (next === null) return
            var value = parseInt(next, 10)
            if (!isFinite(value) || value <= 0) { alert('要一个正整数（字节）'); return }
            post('/admin/api/quota', { subject: row.subject, bytes: value }).then(refresh)
          }))
          actions.appendChild(document.createTextNode(' '))
          actions.appendChild(button('重置用量', function () {
            if (!confirm('把 ' + row.subject + ' 的本期用量归零？')) return
            post('/admin/api/quota/reset', { subject: row.subject }).then(refresh)
          }))
          return [row.subject, used, actions]
        })
      ))
    }

    var roster = state.roster
    var per = Object.keys(roster.published).map(function (id) { return id + ' ' + roster.published[id] + ' 行' })
    document.getElementById('roster').textContent =
      '共 ' + roster.devices + ' 行，其中 ' + roster.bound + ' 行有归属' + (per.length === 0 ? '' : '；按连接器：' + per.join('，'))

    document.getElementById('tokens').replaceChildren(table(
      ['id', '人', '状态', '操作'],
      state.tokens.map(function (row) {
        return [row.id, row.owner || '—', row.revokedAt ? '已吊销' : '有效',
          button(row.revokedAt ? '恢复' : '吊销', function () {
            if (!confirm((row.revokedAt ? '恢复' : '吊销') + '令牌 ' + row.id + '？')) return
            post(row.revokedAt ? '/admin/api/tokens/restore' : '/admin/api/tokens/revoke', { id: row.id }).then(refresh)
          })]
      })
    ))
  }

  document.getElementById('save').addEventListener('click', function () {
    sessionStorage.setItem(TOKEN_KEY, input.value.trim())
    refresh()
  })
  refresh()
  setInterval(refresh, 2000)
})()
</script>
</body>
</html>`
