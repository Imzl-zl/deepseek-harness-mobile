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
