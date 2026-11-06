import assert from "node:assert/strict"
import { test } from "node:test"

import { ADMIN_PAGE } from "../src/admin/page.ts"
import { CONSOLE_PAGE } from "../src/ui/console-page.ts"
import { UI_KIT_JS, UI_KIT_MARKUP } from "../src/ui/kit.ts"

/**
 * 两个网页共用同一份反馈组件，且**不许再出现原生对话框**。
 *
 * 原生 alert/confirm/prompt 的三条问题：挡住自动化（2026-10-15 的 31 条记录）、
 * 样式跟皮肤无关、以及"保存成功什么都不说"（管理台 2026-11-03 的反馈）。
 * 这条用例就是那道闸：谁再写一个 alert，这里立刻红。
 */
const NATIVE = /\balert\(|\bconfirm\(|\bprompt\(/

test("管理台：用 Kit 的 toast/确认框，页面上没有 alert/confirm/prompt", () => {
  assert.ok(ADMIN_PAGE.includes("var Kit ="), "管理台没接上反馈组件")
  assert.ok(ADMIN_PAGE.includes('id="toast"') && ADMIN_PAGE.includes('id="modal"'), "缺少 toast/modal 骨架")
  assert.equal(NATIVE.test(ADMIN_PAGE), false, "管理台里还有原生对话框：换成 Kit.toast / Kit.askConfirm / Kit.askValue")
  // 写操作要有回声：保存成功必须说一句话。
  assert.ok(ADMIN_PAGE.includes("Kit.toast(okText === undefined ? '已保存' : okText, 'ok')"), "保存成功没有提示")
})

test("控制台：toast/modal 只剩同名包装，行为在 Kit 里", () => {
  assert.ok(CONSOLE_PAGE.includes("function toast(message, kind) { Kit.toast(message, kind) }"), "控制台还留着自己的 toast 实现")
  assert.ok(CONSOLE_PAGE.includes("function openModal(build) { return Kit.open(build) }"), "控制台还留着自己的 modal 实现")
  assert.equal(NATIVE.test(CONSOLE_PAGE), false, "控制台里还有原生对话框")
})

test("组件本身：三个 ask* 在取消时都会兑现 Promise（遮罩 / Esc / 取消按钮）", () => {
  // 静态判据：取消路径必须挂到 cancelPending 上，否则 Promise 永远不 settle。
  assert.ok(UI_KIT_JS.includes("cancelPending = function () { settle(false) }"), "确认框取消没兑现 Promise")
  assert.ok(UI_KIT_JS.includes("cancelPending = function () { settle(null) }"), "取值框取消没兑现 Promise")
  assert.ok(UI_KIT_JS.includes("if (event.target === backdrop) close()"), "点遮罩没关")
  assert.ok(UI_KIT_JS.includes("if (event.key !== 'Escape'"), "Esc 没关")
  assert.ok(UI_KIT_MARKUP.includes('role="status"'), "toast 缺无障碍角色")
})

/**
 * 2026-11-03 真机事故：`UI_KIT_JS` 的 IIFE 结尾**漏了分号**，而两个页面在它后面
 * 紧跟一行 `(function () {` —— JS 把两行连成 `(...)()(function(){…})`，于是
 * `Kit.configure(...) is not a function`，整页脚本从第一行就死，表现为
 * "点什么都没反应"（管理台登录、控制台菜单全哑）。typec/perl 都看不出这种错。
 *
 * 两道闸：① kit 必须以分号收尾（对**所有**嵌入方生效）；② 页面里调用 Kit 的行
 * 自己也要带分号，下一行才不会被粘上去。
 */
test("内嵌脚本不许和下一行粘连：kit 以分号收尾，调 Kit 的行也带分号", () => {
  assert.match(UI_KIT_JS.trimEnd(), /;$/, "kit 的 IIFE 必须以分号收尾")
  for (const [name, page] of [["管理台", ADMIN_PAGE], ["控制台", CONSOLE_PAGE]] as const) {
    page.split("\n").forEach((line, index) => {
      const trimmed = line.trim()
      // 只看**单行写完的调用**（`Kit.xxx(…)` 整行就是一次调用）：跨行调用的首行
      // 本来就以 `(` 结尾，不该被这条规则误伤。
      if (!/^Kit\.\w+\(.*\)$/.test(trimmed)) return
      assert.match(trimmed, /;$/, `${name} 第 ${index + 1} 行调 Kit 之后缺分号`)
    })
  }
})

test("kit 真的挂出一个对象（不是靠页面兜），七个方法都在", () => {
  // 真跑一遍那段 JS：`new Function` 只查语法，语句粘连是运行期错误 —— 所以这里
  // 用一个最小 document 替身把它执行到底，断言返回的是对象。
  const factory = new Function("document", `${UI_KIT_JS}\nreturn Kit;`)
  const kit = factory({ getElementById: () => null, addEventListener: () => {} }) as Record<string, unknown>
  assert.equal(typeof kit, "object", "kit 的 IIFE 没返回对象")
  assert.deepEqual(Object.keys(kit).sort(), [
    "askConfirm", "askValue", "button", "close", "configure", "open", "toast",
  ])
  assert.equal(typeof kit["configure"], "function", "Kit.configure 不可调用")
})

/** 够 `askValue` 跑完的最小 DOM：元素只实现它真的会碰的那几个属性/方法。 */
function fakeDom() {
  interface FakeNode {
    tagName: string
    type: string
    value: string
    textContent: string
    className: string
    hidden: boolean
    inputMode: string
    style: { cssText: string }
    children: FakeNode[]
    listeners: Record<string, Array<(event?: unknown) => void>>
    appendChild(child: FakeNode): FakeNode
    addEventListener(name: string, fn: (event?: unknown) => void): void
    setAttribute(name: string, value: string): void
    getAttribute(name: string): string | undefined
    focus(): void
    select(): void
    click(): void
  }
  const make = (type: string): FakeNode => {
    const node: FakeNode = {
      tagName: type,
      type,
      value: "",
      textContent: "",
      className: "",
      hidden: false,
      inputMode: "",
      style: { cssText: "" },
      children: [],
      listeners: {},
      appendChild(child) { this.children.push(child); return child },
      addEventListener(name, fn) { (this.listeners[name] ??= []).push(fn) },
      setAttribute(name, value) { (this as unknown as Record<string, string>)[name] = value },
      getAttribute(name) { return (this as unknown as Record<string, string>)[name] },
      focus() {},
      select() {},
      click() { for (const fn of this.listeners["click"] ?? []) fn({ target: this }) },
    }
    return node
  }
  const nodes: Record<string, FakeNode> = { modal: make("div"), toast: make("div") }
  nodes["modal"]!.hidden = true
  return {
    document: {
      getElementById: (id: string) => nodes[id] ?? null,
      createElement: (tag: string) => make(tag),
      addEventListener: () => {},
    },
    modal: nodes["modal"]!,
  }
}

const walk = (node: { children: unknown[] }): Array<Record<string, unknown>> => {
  const out: Array<Record<string, unknown>> = []
  for (const child of node.children as Array<Record<string, unknown> & { children: unknown[] }>) {
    out.push(child)
    out.push(...walk(child))
  }
  return out
}

const findKitButton = (modal: { children: unknown[] }, label: string) =>
  walk(modal).find((node) => node["type"] === "button" && node["textContent"] === label) as
    | { click(): void }
    | undefined

test("askValue：全角 ２ 归一成 2 —— 用户想输入的那个数字才是校验对象", async () => {
  const { document, modal } = fakeDom()
  const kit = new Function("document", `${UI_KIT_JS}\nreturn Kit;`)(document) as {
    askValue(spec: Record<string, unknown>): Promise<string | null>
  }
  const answer = kit.askValue({
    title: "这个账号最多几台电脑",
    value: "２",
    numeric: true,
    validate: (value: string) => (/^\d+$/.test(value) ? null : "要一个 1–100 的整数"),
  })
  const input = walk(modal).find((node) => node["tagName"] === "input") as
    | { inputMode: string; getAttribute(name: string): string | undefined }
    | undefined
  assert.ok(input !== undefined, "弹框里必须有输入框")
  // 软键盘：数字键盘；值仍是 text（number 框会吞掉前导 0 与全角字符）。
  assert.equal(input.inputMode, "numeric", "数字输入要弹数字键盘")
  assert.equal(input.getAttribute("inputmode"), "numeric", "inputmode 属性要落到 DOM 上")

  const ok = findKitButton(modal, "确定")
  assert.ok(ok !== undefined, "必须有确定键")
  ok.click()
  // 校验失败时 askValue 不会 settle —— 变异校验要变成"快速红"，而不是挂住套件。
  const settled = await Promise.race([
    answer,
    new Promise<string>((resolve) => setTimeout(() => resolve("<timeout>"), 100)),
  ])
  assert.equal(settled, "2", "全角 ２ 必须按 2 通过校验并交回 ASCII 2")
})

test("askValue：校验失败时把实际收到的字符与码位说出来（不许只说“要整数”）", async () => {
  const { document, modal } = fakeDom()
  const kit = new Function("document", `${UI_KIT_JS}\nreturn Kit;`)(document) as {
    askValue(spec: Record<string, unknown>): Promise<string | null>
  }
  const answer = kit.askValue({
    title: "这个账号最多几台电脑",
    value: "２",
    numeric: true,
    // 故意永远失败，让错误提示留在弹框里。
    validate: () => "要一个 1–100 的整数",
  })
  findKitButton(modal, "确定")!.click()
  const error = walk(modal).find(
    (node) => node["className"] === "sub" && String((node["style"] as { cssText?: string }).cssText).includes("color"),
  )
  assert.ok(error !== undefined, "校验失败要显示错误行")
  assert.match(String(error["textContent"]), /收到/)
  assert.match(String(error["textContent"]), /U\+FF12/, "必须说出收到的是全角 ２（U+FF12）")

  // 让 promise 收口（取消 = null），否则这个用例会把未 settle 的 Promise 留给运行时。
  findKitButton(modal, "取消")!.click()
  assert.equal(await answer, null)
})

/**
 * 上面那条只盯 `Kit.` 这一族调用；这条扫**整段脚本**。
 *
 * ASI 的真实触发条件是：上一行以 `)`/`]`/标识符/字面量收尾（= 一条完整语句），
 * 下一行以 `(` 或 `[` 开头 —— 两行会被接成一次调用或一次下标。命中即页面从那一行
 * 起全哑，而 `tsc` 看不出来（页面是模板字符串，不参与类型检查）。
 */
test("整段脚本不许出现语句粘连（上一行完整语句 + 下一行以 ( 或 [ 开头）", () => {
  for (const [name, page] of [["管理台", ADMIN_PAGE], ["控制台", CONSOLE_PAGE]] as const) {
    const script = (page.match(/<script>([\s\S]*?)<\/script>/) ?? [])[1] ?? ""
    assert.ok(script.length > 1000, `${name} 的脚本没取到`)
    const lines = script.split("\n")
    const hits: string[] = []
    for (let index = 0; index < lines.length - 1; index += 1) {
      const current = (lines[index] ?? "").trimEnd()
      const next = (lines[index + 1] ?? "").trimStart()
      if (current === "" || /^(\/\/|\*|\/\*)/.test(current)) continue
      if (!/^[([]/.test(next)) continue
      // 上一行必须像"一条完整语句"：以 ) ] 或标识符/字符串/数字收尾。
      if (!/[)\]A-Za-z0-9_'"`]$/.test(current)) continue
      // 上一行自己就是以 ( 或 [ 开头的续行（例如 `table(`）不算。
      if (/^[([]/.test(current)) continue
      hits.push(`${name} 第 ${index + 2} 行：${JSON.stringify(next.slice(0, 16))}`)
    }
    assert.deepEqual(hits, [], `语句粘连（缺分号）会让整页脚本从那里起失效：\n${hits.join("\n")}`)
  }
})
