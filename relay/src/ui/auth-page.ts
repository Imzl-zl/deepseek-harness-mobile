/**
 * 登录 / 注册 / 重置密码页（单文件、内联脚本、无外链）。
 *
 * 三个路径共用一张壳：字段显隐、标题与提交动作由 `location.pathname` 决定。
 * 这样视觉只有一份，不会出现"登录页和注册页长得像两个产品"。
 */
import { THEME_CSS } from './theme.ts'

export const AUTH_PAGE = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>DSH 中转</title>
<style>${THEME_CSS}</style>
</head>
<body>
<div class="auth">
  <aside class="auth-brand">
    <div class="brandline">
      <div class="mark">${'<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round"><rect x="3" y="4" width="6" height="6" rx="1.6"/><rect x="15" y="14" width="6" height="6" rx="1.6"/><path d="M9 7h4a2 2 0 0 1 2 2v1"/><path d="M15 17h-4a2 2 0 0 1-2-2v-1"/></svg>'}</div>
      <span>DSH 中转</span>
    </div>
    <div>
      <h1>把 DSH 带到手机上。</h1>
      <p class="lead">端到端加密 · 按账号计量</p>
      <ul class="points">
        <li><i>01</i><span><b>端到端加密</b></span></li>
        <li><i>02</i><span><b>每台电脑一枚令牌</b></span></li>
        <li><i>03</i><span><b>按月计量</b></span></li>
      </ul>
    </div>
    <div class="auth-foot">self-hosted</div>
  </aside>

  <main class="auth-main">
    <section class="auth-card">
      <div class="mobile-brand">
        <div class="mark">${'<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round"><rect x="3" y="4" width="6" height="6" rx="1.6"/><rect x="15" y="14" width="6" height="6" rx="1.6"/><path d="M9 7h4a2 2 0 0 1 2 2v1"/><path d="M15 17h-4a2 2 0 0 1-2-2v-1"/></svg>'}</div>
        <span id="mobile-name">DSH 中转</span>
      </div>
      <div class="mark">${'<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round"><rect x="3" y="4" width="6" height="6" rx="1.6"/><rect x="15" y="14" width="6" height="6" rx="1.6"/><path d="M9 7h4a2 2 0 0 1 2 2v1"/><path d="M15 17h-4a2 2 0 0 1-2-2v-1"/></svg>'}</div>
      <h2 id="title">登录</h2>

      <form id="form" autocomplete="on" novalidate>
        <label class="field">
          <span>邮箱</span>
          <input class="input" id="email" type="email" name="email" inputmode="email"
                 autocomplete="username" placeholder="you@qq.com" spellcheck="false" required>
        </label>

        <label class="field" id="code-field" hidden>
          <span>验证码</span>
          <div class="field-row">
            <input class="input" id="code" type="text" name="code" inputmode="numeric"
                   autocomplete="one-time-code" maxlength="6" placeholder="6 位数字">
            <button class="btn" id="send" type="button">发送验证码</button>
          </div>
        </label>

        <label class="field">
          <span id="password-label">密码</span>
          <input class="input" id="password" type="password" name="password"
                 autocomplete="current-password" placeholder="至少 10 位" required>
        </label>

        <label class="field" id="name-field" hidden>
          <span>昵称 <span class="muted">（可选）</span></span>
          <input class="input" id="displayName" type="text" name="displayName" maxlength="40"
                 autocomplete="nickname" placeholder="显示在控制台里">
        </label>

        <button class="btn primary block" id="submit" type="submit">登录</button>
        <p class="error" id="error" role="alert" hidden></p>
        <p class="okline" id="ok" role="status" hidden></p>
      </form>

      <p class="auth-alt" id="alt-login">
        还没有账号？<a href="/register">注册</a>
        <span class="muted"> · </span><a href="/reset">忘记密码</a>
      </p>
      <p class="auth-alt" id="alt-register" hidden>
        已有账号？<a href="/login">登录</a>
      </p>
      <p class="auth-alt" id="alt-reset" hidden>
        想起来了？<a href="/login">登录</a>
      </p>

      <p class="hint" id="domain-hint" hidden></p>
      <p class="hint" id="closed-hint" hidden>这台中转已关闭注册。</p>
      <p class="hint" id="full-hint" hidden>注册名额已满。</p>
    </section>
  </main>
</div>

<script>
(function () {
  var mode = location.pathname === '/register' ? 'register'
    : location.pathname === '/reset' ? 'reset' : 'login'
  var config = null
  var countdown = null

  function q(id) { return document.getElementById(id) }
  function show(id, on) { q(id).hidden = !on }
  function setText(id, value) { q(id).textContent = value }
  function setError(message) {
    var node = q('error')
    node.textContent = message || ''
    node.hidden = !message
    if (message) { node.scrollIntoView({ block: 'nearest' }) }
  }
  function setOk(message) {
    var node = q('ok')
    node.textContent = message || ''
    node.hidden = !message
  }
  function setBusy(on) {
    q('submit').disabled = on
    q('submit').textContent = on ? '请稍候…' : (mode === 'login' ? '登录' : mode === 'register' ? '创建账号' : '重置密码')
  }
  function messageOf(data, fallback) {
    return (data && (data.message || data.error)) || fallback
  }
  function post(path, body) {
    return fetch(path, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body || {})
    }).then(function (response) {
      return response.json().catch(function () { return {} }).then(function (data) {
        return { status: response.status, data: data }
      })
    })
  }

  // 标题与字段显隐
  if (mode === 'login') {
    setText('title', '登录')
    setText('submit', '登录')
    q('password').placeholder = '输入密码'
    q('password').setAttribute('autocomplete', 'current-password')
  } else if (mode === 'register') {
    setText('title', '创建账号')
    setText('submit', '创建账号')
    setText('password-label', '密码')
    q('password').setAttribute('autocomplete', 'new-password')
    show('code-field', true)
    show('name-field', true)
    show('alt-login', false)
    show('alt-register', true)
  } else {
    setText('title', '重置密码')
    setText('submit', '重置密码')
    setText('password-label', '新密码')
    q('password').setAttribute('autocomplete', 'new-password')
    show('code-field', true)
    show('alt-login', false)
    show('alt-reset', true)
  }

  fetch('/api/auth/config').then(function (response) {
    return response.ok ? response.json() : null
  }).then(function (data) {
    if (!data) return
    config = data
    var name = data.serverName || 'DSH 中转'
    document.title = name
    setText('mobile-name', name)
    var domains = (data.registration && data.registration.emailDomains) || []
    if (domains.length > 0 && mode !== 'login') {
      var hint = q('domain-hint')
      hint.textContent = '只接受 ' + domains.map(function (item) { return '@' + item }).join('、') + ' 邮箱'
      hint.hidden = false
    }
    if (mode !== 'login' && data.registration && data.registration.requireEmailVerification === false) {
      show('code-field', false)
    }
    // 两种"不能注册"：closed（不许注册）与 full（名额用完）。**文案分开**，
    // 但置灰是同一件事（复用同一条分支）—— 否则用户会以为"登记一下就能进"。
    // full 只在注册页显示：登录与重置不受名额影响（B5）。
    var closed = data.registration && data.registration.mode === 'closed'
    var full = data.registration && data.registration.full === true
    if (closed) q('closed-hint').hidden = false
    if (mode === 'register' && (closed || full)) {
      if (full && !closed) q('full-hint').hidden = false
      q('submit').disabled = true
      q('email').disabled = true
      q('code').disabled = true
      q('password').disabled = true
      q('send').disabled = true
    }
  }).catch(function () { /* 配置拉不到不挡提交，服务端还会再判一次 */ })

  q('send').addEventListener('click', function () {
    setError('')
    setOk('')
    var email = q('email').value.trim()
    if (email === '') { setError('先填邮箱'); q('email').focus(); return }
    var button = q('send')
    button.disabled = true
    button.textContent = '发送中…'
    var purpose = mode === 'reset' ? 'reset' : 'register'
    post('/api/auth/email-code', { email: email, purpose: purpose }).then(function (result) {
      if (result.status >= 400) {
        setError(messageOf(result.data, '验证码没发出去'))
        button.disabled = false
        button.textContent = '发送验证码'
        return
      }
      setOk('验证码已发出，检查邮箱（也在垃圾箱里看一眼）')
      var seconds = Math.max(30, Math.ceil((result.data.retryAfterMs || 60000) / 1000))
      var left = seconds
      button.textContent = left + 's 后重发'
      clearInterval(countdown)
      countdown = setInterval(function () {
        left -= 1
        if (left <= 0) {
          clearInterval(countdown)
          button.disabled = false
          button.textContent = '重新发送'
          return
        }
        button.textContent = left + 's 后重发'
      }, 1000)
    }).catch(function () {
      setError('连不上中转')
      button.disabled = false
      button.textContent = '发送验证码'
    })
  })

  q('form').addEventListener('submit', function (event) {
    event.preventDefault()
    setError('')
    setOk('')
    var email = q('email').value.trim()
    var password = q('password').value
    var code = q('code').value.trim()
    if (email === '') { setError('先填邮箱'); q('email').focus(); return }
    if (password === '') { setError('先填密码'); q('password').focus(); return }
    var needsCode = mode !== 'login' && !q('code-field').hidden
    if (needsCode && code === '') { setError('先填验证码'); q('code').focus(); return }
    setBusy(true)
    var request = mode === 'login'
      ? post('/api/auth/login', { email: email, password: password })
      : mode === 'register'
        ? post('/api/auth/register', {
            email: email,
            password: password,
            code: code,
            displayName: q('displayName').value.trim()
          })
        : post('/api/auth/password/reset', { email: email, code: code, password: password })
    request.then(function (result) {
      if (result.status >= 400) {
        setError(messageOf(result.data, '操作失败（HTTP ' + result.status + '）'))
        setBusy(false)
        return
      }
      if (mode === 'reset') {
        setOk('密码已改，正在回登录页…')
        setTimeout(function () { location.href = '/login' }, 900)
        return
      }
      location.href = '/console'
    }).catch(function () {
      setError('连不上中转，检查网络后再试')
      setBusy(false)
    })
  })

  q('email').focus()
})();
</script>
</body>
</html>`
