/**
 * 两个网页共用的**反馈组件**：Toast（一次性结果）+ 页内弹框（确认 / 取值）。
 *
 * ## 为什么不是 alert / confirm / prompt
 *
 * 2026-10-15 的事故：window.confirm **挡不住自动化** —— chrome-devtools 的
 * evaluate_script 有个默认 accept 的 dialogAction，脚本点到「清掉当前离线」
 * 就把 31 条记录硬删了。原生对话框在自动化面前等于没有确认。
 * 所以确认框一律是**页内 DOM**：看得见、点得到，自动化要动它得显式选中元素。
 *
 * ## 为什么抽成一份
 *
 * 控制台（console-page.ts）早就有一版 toast + modal，管理台（admin/page.ts）却还在用
 * alert/confirm/prompt：同一个产品里两套反馈、两种手感，管理台那套还「保存完什么都不说」。
 * 这里只放**行为**；配色与排版留在各自的皮肤里（控制台的 CSS 在 theme.ts，
 * 管理台有自己的一套），因为两个页面的视觉语言本来就不一样。
 *
 * ## 用法
 *
 * 页面骨架里放一处 UI_KIT_MARKUP，脚本开头拼上 UI_KIT_JS，然后：
 *
 *     Kit.configure({ ok: 'btn', cancel: 'ghost', danger: 'btn danger' })   // 按皮肤，可选
 *     Kit.toast('已保存', 'ok')
 *     Kit.askConfirm({ title: '停用这个账号？', body: '名下连接会立刻断开', ok: '停用', danger: true })
 *       .then(function (yes) { if (yes) { … } })
 *     Kit.askValue({ title: '本月额度（GB）', value: '5', validate: function (v) {
 *       return isFinite(Number(v)) ? null : '要一个数字'
 *     } }).then(function (value) { if (value !== null) { … } })
 *
 * 三个 ask* 都返回 Promise：取消（按钮 / 遮罩 / Esc）给 false 或 null，
 * **不会挂在那里等** —— 这是页内弹框最容易漏的一条。
 *
 * Note: 为什么必须页内、为什么抽一份 —— 见
 * .agents/notes/implemented/2026-11-03-web-feedback-kit.md
 */

/** 页面骨架里放一处（放在 body 末尾）。 */
export const UI_KIT_MARKUP = `<div class="modal-backdrop" id="modal" hidden></div>
<div class="toast" id="toast" role="status" aria-live="polite"></div>`

/** 行为部分：挂在 window.Kit 上。 */
export const UI_KIT_JS = `
  var Kit = (function () {
    var toastTimer = null
    var cancelPending = null
    var classes = { ok: 'primary', cancel: '', danger: 'danger' }

    function node(id) { return document.getElementById(id) }

    function configure(next) {
      if (!next) return
      if (typeof next.ok === 'string') classes.ok = next.ok
      if (typeof next.cancel === 'string') classes.cancel = next.cancel
      if (typeof next.danger === 'string') classes.danger = next.danger
    }

    function toast(message, kind) {
      var box = node('toast')
      if (box === null) return
      box.textContent = message
      box.className = 'toast show' + (kind ? ' ' + kind : '')
      clearTimeout(toastTimer)
      toastTimer = setTimeout(function () { box.className = 'toast' }, 3200)
    }

    function button(text, className, onClick) {
      var element = document.createElement('button')
      element.type = 'button'
      element.textContent = text
      if (className) element.className = className
      if (onClick) element.addEventListener('click', onClick)
      return element
    }

    function close() {
      var backdrop = node('modal')
      if (backdrop === null) return
      backdrop.hidden = true
      backdrop.textContent = ''
      var pending = cancelPending
      cancelPending = null
      if (pending) pending()
    }

    function open(build) {
      var backdrop = node('modal')
      if (backdrop === null) return null
      backdrop.textContent = ''
      backdrop.hidden = false
      var box = document.createElement('div')
      box.className = 'modal'
      build(box)
      backdrop.appendChild(box)
      return box
    }

    function head(box, title, body) {
      var header = document.createElement('header')
      var h = document.createElement('h3')
      h.textContent = title
      header.appendChild(h)
      if (body) {
        var p = document.createElement('p')
        p.className = 'sub'
        p.textContent = body
        header.appendChild(p)
      }
      box.appendChild(header)
    }

    function foot(box, buttons) {
      var footer = document.createElement('footer')
      for (var index = 0; index < buttons.length; index += 1) footer.appendChild(buttons[index])
      box.appendChild(footer)
    }

    /** 确认：Promise<boolean>。 */
    function askConfirm(spec) {
      return new Promise(function (resolve) {
        var settled = false
        function settle(value) {
          if (settled) return
          settled = true
          cancelPending = null
          close()
          resolve(value)
        }
        cancelPending = function () { settle(false) }
        open(function (box) {
          head(box, spec.title, spec.body)
          var cancel = button(spec.cancel || '取消', classes.cancel, function () { settle(false) })
          var ok = button(spec.ok || '确定', spec.danger ? classes.danger : classes.ok, function () { settle(true) })
          foot(box, [cancel, ok])
          setTimeout(function () { cancel.focus() }, 0)
        })
      })
    }

    /** 取一个值：Promise<string|null>。validate 返回非空字符串 = 不合法（显示在输入框下）。 */
    function askValue(spec) {
      return new Promise(function (resolve) {
        var settled = false
        function settle(value) {
          if (settled) return
          settled = true
          cancelPending = null
          close()
          resolve(value)
        }
        cancelPending = function () { settle(null) }
        open(function (box) {
          head(box, spec.title, spec.body)
          var body = document.createElement('div')
          body.className = 'body'
          var input = document.createElement('input')
          input.type = 'text'
          input.value = spec.value === undefined ? '' : String(spec.value)
          if (spec.placeholder) input.placeholder = spec.placeholder
          input.style.cssText = 'width:100%;padding:8px 10px;border:1px solid var(--line2,var(--line,#cbd5e1));border-radius:8px;background:transparent;color:inherit;font:inherit'
          body.appendChild(input)
          var error = document.createElement('p')
          error.className = 'sub'
          error.style.cssText = 'color:#e5484d;margin:6px 0 0'
          error.hidden = true
          body.appendChild(error)
          box.appendChild(body)
          var cancel = button(spec.cancel || '取消', classes.cancel, function () { settle(null) })
          var ok = button(spec.ok || '确定', classes.ok, function () {
            var value = input.value.trim()
            var problem = spec.validate ? spec.validate(value) : null
            if (problem) { error.textContent = problem; error.hidden = false; input.focus(); return }
            settle(value)
          })
          foot(box, [cancel, ok])
          input.addEventListener('keydown', function (event) {
            if (event.key === 'Enter') { event.preventDefault(); ok.click() }
          })
          setTimeout(function () { input.focus(); input.select() }, 0)
        })
      })
    }

    // 遮罩点击与 Esc 一律等于「取消」。**装在 document 上**：弹框是后插进 DOM 的，
    // 挂在按钮上会在重画后丢。
    document.addEventListener('click', function (event) {
      var backdrop = node('modal')
      if (backdrop === null || backdrop.hidden) return
      if (event.target === backdrop) close()
    })
    document.addEventListener('keydown', function (event) {
      var backdrop = node('modal')
      if (event.key !== 'Escape' || backdrop === null || backdrop.hidden) return
      close()
    })

    return {
      configure: configure,
      toast: toast,
      open: open,
      close: close,
      askConfirm: askConfirm,
      askValue: askValue,
      button: button
    }
  })();
`
