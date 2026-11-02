/**
 * 用户控制台（`/console`）：概览 / 我的电脑 / 账号。
 *
 * 所有数据来自 `/api/console/state`（4 秒轮询，页面隐藏时暂停）；写操作都带
 * `X-CSRF-Token`（从 `dsh_relay_csrf` cookie 读）。页面没有任何外链，
 * 所有动态文本走 `textContent`，不拼 `innerHTML`。
 */
import { THEME_CSS } from './theme.ts'

export const CONSOLE_PAGE = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>控制台 · DSH 中转</title>
<style>${THEME_CSS}</style>
</head>
<body>
<div class="app">
  <aside class="side">
    <div class="brandline">
      <div class="mark">${'<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round"><rect x="3" y="4" width="6" height="6" rx="1.6"/><rect x="15" y="14" width="6" height="6" rx="1.6"/><path d="M9 7h4a2 2 0 0 1 2 2v1"/><path d="M15 17h-4a2 2 0 0 1-2-2v-1"/></svg>'}</div>
      <div><b>DSH 中转</b><span>console</span></div>
    </div>
    <nav id="nav">
      <a href="#/overview" data-view="overview">概览</a>
      <a href="#/computers" data-view="computers">我的电脑<em id="n-computers"></em></a>
      <a href="#/account" data-view="account">账号</a>
    </nav>
    <div class="sidefoot">
      <div class="who">
        <div class="avatar" id="avatar">·</div>
        <div class="mail" id="who-mail">—</div>
      </div>
      <button class="btn small" id="logout" type="button">退出登录</button>
    </div>
  </aside>
  <main class="main">
    <header class="topbar">
      <div>
        <h1 id="title">概览</h1>
        <p id="sub">这台中转上，你的账号与电脑</p>
      </div>
      <div class="grow"></div>
      <button class="btn primary small" id="add" type="button">添加电脑</button>
    </header>
    <div class="content" id="view">
      <div class="card"><div class="body"><div class="skeleton"></div></div></div>
    </div>
  </main>
</div>

<div class="modal-backdrop" id="modal" hidden></div>
<div class="toast" id="toast" role="status" aria-live="polite"></div>

<script>
(function () {
  var state = null
  var me = null
  var timer = null
  var toastTimer = null

  function q(id) { return document.getElementById(id) }
  function el(tag, text, cls) {
    var node = document.createElement(tag)
    if (text !== undefined && text !== null) node.textContent = String(text)
    if (cls) node.className = cls
    return node
  }
  function button(text, cls, onClick) {
    var node = el('button', text, 'btn small' + (cls ? ' ' + cls : ''))
    node.type = 'button'
    node.addEventListener('click', onClick)
    return node
  }
  function csrf() {
    var match = document.cookie.match(/(?:^|; )dsh_relay_csrf=([^;]+)/)
    return match ? decodeURIComponent(match[1]) : ''
  }
  function api(path, method, body) {
    var headers = { 'content-type': 'application/json' }
    if (method === 'POST') headers['x-csrf-token'] = csrf()
    return fetch(path, {
      method: method || 'GET',
      headers: headers,
      credentials: 'same-origin',
      body: body === undefined ? undefined : JSON.stringify(body)
    }).then(function (response) {
      if (response.status === 401) { location.href = '/login'; throw new Error('unauthorized') }
      return response.json().catch(function () { return {} }).then(function (data) {
        if (!response.ok) {
          var error = new Error((data && (data.message || data.error)) || ('HTTP ' + response.status))
          error.code = data && data.error
          error.status = response.status
          throw error
        }
        return data
      })
    })
  }
  function toast(message, kind) {
    var node = q('toast')
    node.textContent = message
    node.className = 'toast show' + (kind ? ' ' + kind : '')
    clearTimeout(toastTimer)
    toastTimer = setTimeout(function () { node.className = 'toast' }, 3200)
  }
  function bytes(n) {
    if (typeof n !== 'number' || !isFinite(n)) return '—'
    if (n >= 1073741824) return (n / 1073741824).toFixed(1) + ' GB'
    if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB'
    if (n >= 1024) return Math.round(n / 1024) + ' KB'
    return n + ' B'
  }
  function ago(ts) {
    if (!ts) return '—'
    var seconds = Math.max(0, Math.round((Date.now() - ts) / 1000))
    if (seconds < 60) return '刚刚'
    if (seconds < 3600) return Math.round(seconds / 60) + ' 分钟前'
    if (seconds < 86400) return Math.round(seconds / 3600) + ' 小时前'
    return Math.round(seconds / 86400) + ' 天前'
  }
  function badge(text, kind) {
    return el('span', text, 'badge' + (kind ? ' ' + kind : ''))
  }
  function statusOf(row) {
    if (row.revokedAt) return badge('已停用', 'bad')
    return row.online ? badge('在线', 'ok') : badge('离线', '')
  }
  function card(title, metaText) {
    var node = el('section', null, 'card')
    var head = el('header')
    head.appendChild(el('h2', title))
    if (metaText) head.appendChild(el('span', metaText, 'meta'))
    node.appendChild(head)
    var body = el('div', null, 'body')
    node.appendChild(body)
    return { card: node, body: body }
  }
  function kpi(value, label, extra) {
    var node = el('div', null, 'kpi')
    node.appendChild(el('div', value, 'v'))
    node.appendChild(el('div', label, 'k'))
    if (extra) { extra.className = 'extra'; node.appendChild(extra) }
    return node
  }
  function table(headers, rows, emptyText) {
    if (rows.length === 0) {
      var empty = el('div', null, 'empty')
      empty.appendChild(el('b', emptyText || '暂无数据'))
      return empty
    }
    var wrap = el('div', null, 'table-wrap')
    var table = el('table')
    var head = el('tr')
    headers.forEach(function (name) {
      var numeric = name.charAt(0) === '#'
      head.appendChild(el('th', numeric ? name.slice(1) : name, numeric ? 'r' : ''))
    })
    var thead = el('thead'); thead.appendChild(head); table.appendChild(thead)
    var tbody = el('tbody')
    rows.forEach(function (cells) {
      var tr = el('tr')
      cells.forEach(function (value, index) {
        var numeric = headers[index] && headers[index].charAt(0) === '#'
        var td = el('td', null, numeric ? 'r num' : '')
        if (value instanceof Node) td.appendChild(value)
        else td.textContent = value === undefined || value === null ? '—' : String(value)
        tr.appendChild(td)
      })
      tbody.appendChild(tr)
    })
    table.appendChild(tbody)
    wrap.appendChild(table)
    return wrap
  }
  function openModal(build) {
    var backdrop = q('modal')
    backdrop.textContent = ''
    backdrop.hidden = false
    var box = el('div', null, 'modal')
    build(box)
    backdrop.appendChild(box)
    return box
  }
  function closeModal() {
    var backdrop = q('modal')
    backdrop.hidden = true
    backdrop.textContent = ''
  }
  function confirmModal(title, text, confirmText, danger, onConfirm) {
    openModal(function (box) {
      var head = el('header')
      head.appendChild(el('h3', title))
      head.appendChild(el('p', text, 'sub'))
      box.appendChild(head)
      var foot = el('footer')
      var cancel = button('取消', '', closeModal)
      var confirm = button(confirmText, danger ? 'danger' : 'primary', function () {
        confirm.disabled = true
        Promise.resolve(onConfirm()).then(closeModal).catch(function (error) {
          confirm.disabled = false
          toast(error.message || '操作失败', 'bad')
        })
      })
      foot.appendChild(cancel); foot.appendChild(confirm)
      box.appendChild(foot)
      setTimeout(function () { cancel.focus() }, 0)
    })
  }

  function renderShell() {
    if (!state) return
    var online = state.connectors.filter(function (row) { return row.online && !row.revokedAt }).length
    q('n-computers').textContent = String(state.connectors.filter(function (row) { return !row.revokedAt }).length)
    q('who-mail').textContent = state.user.email || state.user.displayName
    q('who-mail').title = state.user.email || ''
    q('avatar').textContent = (state.user.displayName || state.user.email || '?').slice(0, 1).toUpperCase()
    document.querySelectorAll('#nav a').forEach(function (link) {
      var view = (location.hash || '#/overview').replace('#/', '')
      link.className = link.getAttribute('data-view') === view ? 'active' : ''
    })
  }

  function viewOf() {
    var hash = (location.hash || '').replace('#/', '')
    return hash === 'computers' || hash === 'account' ? hash : 'overview'
  }
  function render() {
    if (!state) return
    renderShell()
    var view = viewOf()
    q('title').textContent = view === 'computers' ? '我的电脑' : view === 'account' ? '账号' : '概览'
    q('sub').textContent = view === 'computers'
      ? '每台电脑一枚令牌；停用即断线，删除前必须先停用'
      : view === 'account'
        ? '邮箱、密码与登录会话'
        : '这台中转上，你的账号与电脑'
    var host = q('view')
    host.textContent = ''
    if (view === 'computers') renderComputers(host)
    else if (view === 'account') renderAccount(host)
    else renderOverview(host)
  }

  function quotaExtra() {
    var quota = state.quota
    var wrap = el('div')
    if (quota.limit === null) {
      wrap.appendChild(el('div', '不设上限', 'muted'))
      return wrap
    }
    var ratio = quota.limit > 0 ? quota.used / quota.limit : 0
    var bar = el('span', null, 'bar')
    var fill = el('i')
    fill.style.width = Math.min(100, Math.round(ratio * 100)) + '%'
    if (ratio >= 0.9) fill.className = 'bad'
    else if (ratio >= 0.7) fill.className = 'warn'
    bar.appendChild(fill)
    wrap.appendChild(bar)
    return wrap
  }

  function renderOverview(host) {
    var active = state.connectors.filter(function (row) { return !row.revokedAt })
    var online = active.filter(function (row) { return row.online }).length
    var devices = state.devices.length
    var kpis = el('div', null, 'kpis')
    kpis.appendChild(kpi(
      state.quota.limit === null
        ? bytes(state.quota.used)
        : bytes(state.quota.used) + ' / ' + bytes(state.quota.limit),
      state.quota.period === 'day' ? '今日用量' : '本月用量',
      quotaExtra(),
    ))
    kpis.appendChild(kpi(online + ' / ' + state.limits.maxConnectors, '在线电脑'))
    kpis.appendChild(kpi(String(devices), '已配对设备'))
    host.appendChild(kpis)

    if (active.length === 0) {
      var onboarding = card('还没有电脑')
      var intro = el('p', '添加一台电脑，把令牌粘贴到 DSH 的「手机 → 连接」卡。', 'muted')
      intro.style.margin = '0 0 16px'
      onboarding.body.appendChild(intro)
      var addNow = button('添加电脑', 'primary', openAddComputer)
      var actions = el('div', null, 'actions')
      actions.style.marginTop = '16px'
      actions.appendChild(addNow)
      onboarding.body.appendChild(actions)
      host.appendChild(onboarding.card)
      return
    }

    var list = card('我的电脑', '共 ' + active.length + ' 台')
    list.body.appendChild(table(
      ['名称', '状态', '#设备', '最近在线', ''],
      active.map(function (row) {
        var name = el('div')
        name.appendChild(el('div', row.name, 'name'))
        if (row.connectorId) {
          var id = el('div', row.connectorId.slice(0, 18) + (row.connectorId.length > 18 ? '…' : ''), 'mono muted')
          name.appendChild(id)
        } else {
          name.appendChild(el('div', '等待首次连接后绑定', 'muted'))
        }
        var actions = el('div', null, 'actions')
        actions.appendChild(button('重命名', '', function () { renameComputer(row) }))
        actions.appendChild(button(row.revokedAt ? '恢复' : '停用', row.revokedAt ? '' : 'danger', function () {
          toggleComputer(row)
        }))
        return [name, statusOf(row), row.devices, row.online ? '刚刚' : ago(row.lastPongAt), actions]
      }),
    ))
    host.appendChild(list.card)

    host.appendChild(el('p', '令牌只显示一次；丢了就停用后重建。', 'note'))
  }

  function renderComputers(host) {
    var rows = state.connectors
    var section = card('全部电脑', rows.length + ' 台')
    section.body.appendChild(table(
      ['名称', '状态', '#设备', '创建', '最近在线', ''],
      rows.map(function (row) {
        var name = el('div')
        name.appendChild(el('div', row.name, 'name'))
        name.appendChild(el('div',
          row.connectorId ? '绑定 ' + row.connectorId : '尚未绑定（第一次连接时自动绑定）',
          'mono muted'))
        var actions = el('div', null, 'actions')
        actions.appendChild(button('重命名', '', function () { renameComputer(row) }))
        actions.appendChild(button(row.revokedAt ? '恢复' : '停用', row.revokedAt ? '' : 'danger', function () {
          toggleComputer(row)
        }))
        if (row.revokedAt) {
          actions.appendChild(button('删除', 'danger', function () { removeComputer(row) }))
        } else if (!row.online && row.connectorId) {
          actions.appendChild(button('重置绑定', '', function () { resetBinding(row) }))
        }
        return [
          name,
          statusOf(row),
          row.devices,
          row.createdAt ? ago(row.createdAt) : '—',
          row.online ? '刚刚' : ago(row.lastPongAt),
          actions,
        ]
      }),
      '还没有电脑 — 点右上角「添加电脑」开始',
    ))
    host.appendChild(section.card)

    host.appendChild(el('p', '停用会立刻断线；删除只对已停用的电脑开放。', 'note'))
  }

  function renderAccount(host) {
    var profile = card('账号')
    var kv = el('div', null, 'kv')
    ;[
      ['邮箱', state.user.email],
      ['昵称', state.user.displayName],
      ['角色', state.user.role === 'admin' ? '管理员' : '普通用户'],
      ['注册时间', new Date(state.user.createdAt).toLocaleString('zh-CN')],
      ['最近登录', state.user.lastLoginAt ? new Date(state.user.lastLoginAt).toLocaleString('zh-CN') : '—'],
    ].forEach(function (pair) {
      var row = el('div', null, 'row')
      row.appendChild(el('span', pair[0]))
      row.appendChild(el('span', pair[1]))
      kv.appendChild(row)
    })
    profile.body.appendChild(kv)
    host.appendChild(profile.card)

    var passwordCard = card('改密码')
    var form = el('form')
    form.autocomplete = 'off'
    var current = el('input', null, 'input')
    current.type = 'password'; current.placeholder = '当前密码'; current.autocomplete = 'current-password'
    var next = el('input', null, 'input')
    next.type = 'password'; next.placeholder = '新密码（至少 10 位）'; next.autocomplete = 'new-password'
    var currentField = el('label', null, 'field')
    currentField.appendChild(el('span', '当前密码')); currentField.appendChild(current)
    var nextField = el('label', null, 'field')
    nextField.appendChild(el('span', '新密码')); nextField.appendChild(next)
    var save = el('button', '改密码', 'btn primary')
    save.type = 'submit'
    form.appendChild(currentField); form.appendChild(nextField); form.appendChild(save)
    form.addEventListener('submit', function (event) {
      event.preventDefault()
      save.disabled = true
      api('/api/auth/password', 'POST', { current: current.value, next: next.value })
        .then(function () {
          current.value = ''; next.value = ''
          toast('密码已改；其它设备上的登录已退出', 'ok')
        })
        .catch(function (error) { toast(error.message, 'bad') })
        .finally(function () { save.disabled = false })
    })
    passwordCard.body.appendChild(form)
    host.appendChild(passwordCard.card)

    var sessionsCard = card('登录会话', '最近 30 天')
    sessionsCard.body.appendChild(el('div', '正在读取…', 'muted'))
    host.appendChild(sessionsCard.card)
    api('/api/auth/sessions').then(function (data) {
      sessionsCard.body.textContent = ''
      sessionsCard.body.appendChild(table(
        ['设备', 'IP', '最近使用', ''],
        data.sessions.map(function (row) {
          var ua = row.userAgent || '未知客户端'
          if (ua.length > 58) ua = ua.slice(0, 58) + '…'
          var action = row.current
            ? badge('当前会话', 'ok')
            : button('退出', 'danger', function () {
                api('/api/auth/sessions/revoke', 'POST', { id: row.id })
                  .then(function () { toast('已退出那条会话', 'ok'); render() })
                  .catch(function (error) { toast(error.message, 'bad') })
              })
          return [ua, row.ip || '—', ago(row.lastSeenAt), action]
        }),
        '没有其它会话',
      ))
    }).catch(function (error) {
      sessionsCard.body.textContent = ''
      sessionsCard.body.appendChild(el('div', error.message, 'error'))
    })

    var danger = card('退出')
    var logout = button('退出登录', 'danger', function () {
      api('/api/auth/logout', 'POST', {}).then(function () { location.href = '/login' })
        .catch(function () { location.href = '/login' })
    })
    danger.body.appendChild(logout)
    host.appendChild(danger.card)
  }

  function openAddComputer() {
    openModal(function (box) {
      var head = el('header')
      head.appendChild(el('h3', '添加一台电脑'))
      head.appendChild(el('p', '令牌只显示一次。', 'sub'))
      box.appendChild(head)
      var body = el('div', null, 'body')
      var field = el('label', null, 'field')
      field.appendChild(el('span', '电脑名'))
      var input = el('input', null, 'input')
      input.placeholder = '家里的台式机'
      input.maxLength = 40
      field.appendChild(input)
      body.appendChild(field)
      box.appendChild(body)
      var foot = el('footer')
      foot.appendChild(button('取消', '', closeModal))
      var create = button('创建', 'primary', function () {
        var name = input.value.trim()
        if (name === '') { input.focus(); return }
        create.disabled = true
        api('/api/console/connectors', 'POST', { name: name })
          .then(function (data) { showToken(data.token, name) })
          .catch(function (error) { create.disabled = false; toast(error.message, 'bad') })
      })
      foot.appendChild(create)
      box.appendChild(foot)
      setTimeout(function () { input.focus() }, 0)
      input.addEventListener('keydown', function (event) {
        if (event.key === 'Enter') { event.preventDefault(); create.click() }
      })
    })
  }

  function showToken(token, name) {
    openModal(function (box) {
      var head = el('header')
      head.appendChild(el('h3', '「' + name + '」的令牌'))
      head.appendChild(el('p', '只显示一次。', 'sub'))
      box.appendChild(head)
      var body = el('div', null, 'body')
      var codebox = el('div', null, 'codebox')
      var code = el('div', token, 'mono')
      codebox.appendChild(code)
      var copy = button('复制', '', function () {
        var done = function () { copy.textContent = '已复制'; setTimeout(function () { copy.textContent = '复制' }, 1600) }
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(token).then(done).catch(function () { toast('复制失败，手动选中吧', 'bad') })
        } else {
          var range = document.createRange(); range.selectNodeContents(code)
          var selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range)
          toast('已选中，按 Ctrl+C 复制', 'ok')
        }
      })
      codebox.appendChild(copy)
      body.appendChild(codebox)
      var check = el('label', null, 'check')
      var checkbox = el('input'); checkbox.type = 'checkbox'
      check.appendChild(checkbox)
      check.appendChild(el('span', '我已保存'))
      body.appendChild(check)
      box.appendChild(body)
      var foot = el('footer')
      var done = button('完成', 'primary', function () {
        closeModal()
        refresh()
      })
      done.disabled = true
      checkbox.addEventListener('change', function () { done.disabled = !checkbox.checked })
      foot.appendChild(done)
      box.appendChild(foot)
    })
  }

  function renameComputer(row) {
    openModal(function (box) {
      var head = el('header')
      head.appendChild(el('h3', '重命名'))
      box.appendChild(head)
      var body = el('div', null, 'body')
      var field = el('label', null, 'field')
      field.appendChild(el('span', '电脑名'))
      var input = el('input', null, 'input')
      input.value = row.name
      input.maxLength = 40
      field.appendChild(input)
      body.appendChild(field)
      box.appendChild(body)
      var foot = el('footer')
      foot.appendChild(button('取消', '', closeModal))
      var save = button('保存', 'primary', function () {
        save.disabled = true
        api('/api/console/connectors/action', 'POST', { action: 'rename', id: row.id, name: input.value.trim() })
          .then(function () { closeModal(); refresh(); toast('已改名', 'ok') })
          .catch(function (error) { save.disabled = false; toast(error.message, 'bad') })
      })
      foot.appendChild(save)
      box.appendChild(foot)
      setTimeout(function () { input.focus(); input.select() }, 0)
    })
  }

  function toggleComputer(row) {
    var revoking = !row.revokedAt
    confirmModal(
      revoking ? '停用这台电脑？' : '恢复这台电脑？',
      revoking
        ? '它当前的手机连接会立刻断开；记录留着，之后可以恢复。'
        : '恢复后这台电脑可以重新连上来。',
      revoking ? '停用' : '恢复',
      revoking,
      function () {
        return api('/api/console/connectors/action', 'POST', {
          action: revoking ? 'revoke' : 'restore',
          id: row.id,
        }).then(function () { toast(revoking ? '已停用' : '已恢复', 'ok'); refresh() })
      },
    )
  }

  function removeComputer(row) {
    confirmModal(
      '永久删除这台电脑？',
      '记录与令牌摘要都会消失，不可恢复。这台电脑之后连不上中转。',
      '删除',
      true,
      function () {
        return api('/api/console/connectors/action', 'POST', { action: 'remove', id: row.id })
          .then(function () { toast('已删除', 'ok'); refresh() })
      },
    )
  }

  function resetBinding(row) {
    confirmModal(
      '重置这台电脑的绑定？',
      '只在那台电脑重装过、pcId 变了的时候用。重置后它下次连上来会重新绑定。',
      '重置绑定',
      false,
      function () {
        return api('/api/console/connectors/action', 'POST', { action: 'reset-binding', id: row.id })
          .then(function () { toast('已重置', 'ok'); refresh() })
      },
    )
  }

  function refresh() {
    return api('/api/console/state').then(function (data) {
      state = data
      if (!me) {
        me = data.user
      }
      render()
    }).catch(function (error) {
      if (error.message !== 'unauthorized') toast(error.message || '读不到状态', 'bad')
    })
  }

  function boot() {
    api('/api/auth/me').then(function (data) {
      me = data.user
      if (me.role === 'admin') {
        var link = el('a', '管理台', '')
        link.href = '/admin'
        link.style.marginLeft = '8px'
        q('logout').parentNode.insertBefore(link, q('logout'))
      }
      return refresh()
    }).catch(function () {
      // api() 已经把 401 送到 /login
    })
    if (timer === null) {
      timer = setInterval(function () {
        if (!document.hidden) refresh()
      }, 4000)
    }
  }

  q('add').addEventListener('click', openAddComputer)
  q('logout').addEventListener('click', function () {
    api('/api/auth/logout', 'POST', {}).then(function () { location.href = '/login' })
      .catch(function () { location.href = '/login' })
  })
  window.addEventListener('hashchange', render)
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) refresh()
  })
  q('modal').addEventListener('click', function (event) {
    if (event.target === q('modal')) closeModal()
  })
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape' && !q('modal').hidden) closeModal()
  })

  boot()
})();
</script>
</body>
</html>`
