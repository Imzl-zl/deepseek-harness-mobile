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

    /**
     * 全角数字/符号 → ASCII。
     *
     * 为什么必须有：中文输入法开着「全角」时，数字键打出的是 U+FF11 / U+FF12
     * （１ / ２），而 input.value.trim() **不会**把它变成 ASCII —— 校验器看到
     * 的不是它以为的那个字符。2026-11-06 真机：填「2」被回「要一个 1–100 的整数」，
     * 实际收到的是 U+FF12（/^\d+$/ 为 false，trim() 也救不了）。
     *
     * 只做**字符级归一化**，不替用户改语义：全角数字、全角小数点/正负号是同一个
     * 数字的另一种键盘形态；中文数字（「二」）不在其列，照旧校验失败。
     *
     * Note: 为什么归一化在 Kit 入口而不是每个校验器 —— 见
     * .agents/notes/implemented/2026-11-06-panel-detail-feedback.md
     */
    function normalizeDigits(value) {
      return value
        .replace(/[\\uFF10-\\uFF19]/g, function (ch) {
          return String.fromCharCode(ch.charCodeAt(0) - 0xFEE0)
        })
        .replace(/\\uFF0E/g, '.')
        .replace(/\\uFF0D/g, '-')
        .replace(/\\uFF0B/g, '+')
    }

    /**
     * 把**实际收到的字符**说清楚：ASCII 原样，非 ASCII 每个都带 U+XXXX。
     *
     * 只说「要一个整数」会让用户以为输入法没问题（他看到的明明是 2）。把码位
     * 一起说出来，才能区分「打错了」与「输入法打了全角」。
     */
    function rawDescription(value) {
      if (value === '') return '空'
      var out = ''
      for (var index = 0; index < value.length; index += 1) {
        var code = value.charCodeAt(index)
        out += code >= 0x20 && code <= 0x7E
          ? value.charAt(index)
          : value.charAt(index) + '(U+' + code.toString(16).toUpperCase() + ')'
      }
      return '「' + out + '」'
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
          // inputmode 只改**软键盘**（数字键盘），不改值：全角仍可能从输入法里出来，
          // 所以下面还要归一化。两件事各管一半，缺一条都不够。
          if (spec.numeric) {
            input.inputMode = 'numeric'
            input.setAttribute('inputmode', 'numeric')
          }
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
            var raw = input.value.trim()
            // **先归一化再校验**：校验器看到的是用户想输入的那个 ASCII 数字。
            var value = normalizeDigits(raw)
            var problem = spec.validate ? spec.validate(value) : null
            if (problem) {
              // 归一化改过（全角）或原文含非 ASCII：把实际收到的字符连同码位说出来。
              // 纯 ASCII 的普通输错不啰嗦，保留原来那句短文案。
              var detail = raw !== value || /[^\\x20-\\x7E]/.test(raw)
                ? '（收到 ' + rawDescription(raw) + '）'
                : ''
              error.textContent = problem + detail
              error.hidden = false
              input.focus()
              return
            }
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
