# Agent Note: 网页反馈只有一个组件（Toast + 页内弹框）

Status: implemented

## Problem

2026-11-03 用户原话：「web 的保存啊啥的那些按钮，有的点了也没个弹框提示一下啥的，都以为没效果呢？
还有弹框能不能做一个组件用用，太简陋了吧」。

现场是两套东西：

- **控制台**（`console-page.ts`）早就有 toast + 页内 modal，每个写操作都有回声
  （已改名 / 已停用 / 已恢复 / 已删除 / 已重置）。
- **管理台**（`admin/page.ts`）是另一套：22 处 `alert` / `confirm` / `prompt`，
  而且**保存成功什么都不说** —— `post()` 只在失败时 `alert`，成功时静默 `refresh()`。
  用户点「保存」，页面重画一遍，看不出到底存没存。

两套反馈手感还不一样：原生对话框跟深色海军底 + 青绿强调色的皮肤毫无关系。

## Decision

1. 新建 `relay/src/ui/kit.ts`：**行为的唯一实现**（markup + JS，不含配色）。
   - `Kit.toast(message, kind)`：顶部居中，3.2 s 自动消失，`role="status"`。
   - `Kit.askConfirm({title, body, ok, danger})` → `Promise<boolean>`。
   - `Kit.askValue({title, body, value, validate})` → `Promise<string|null>`，
     `validate` 返回非空字符串就把话显示在输入框下面。
   - `Kit.open(build)` / `Kit.close()`：给控制台那种"表单弹框"用。
   - 遮罩点击与 Esc **一律等于取消**，并且**一定兑现 Promise**（`cancelPending`）——
     页内弹框最容易漏的就是"取消了但 Promise 挂着"。
   - 按钮 class 由 `Kit.configure({ok, cancel, danger})` 按皮肤给：控制台 `primary/danger`，
     管理台 `btn/ghost/btn danger`。
2. 两个页面都用它：
   - 管理台：`post(path, body, okText)` 成功后 **默认 toast「已保存」**（可传更准的文案：
     已断开 / 已吊销 / 已重置 / 已签发…），失败 toast 原因；22 处原生对话框全部换成
     `ifConfirmed` / `withValue` 两个薄包装。
   - 控制台：`toast` / `openModal` / `closeModal` / `confirmModal` 改成**同名包装**，
     调用点一个字不改，实现搬到 Kit 里。
3. 皮肤各留一份：控制台的 `.modal/.toast` CSS 在 `theme.ts`，管理台在自己的 `<style>` 里
   （它的配色是另一套）。**组件只管行为**，所以两处 CSS 不合并。

## Alternatives considered

1. **只在管理台加 alert 替代品（不做组件）**
   - 最强的理由：改动面最小，控制台本来就正常。
   - 为何被否：那就是第三套实现。这个仓库反复吃过"同一件事两处判据"的亏
     （`AGENTS.md` 的「同一件事只有一处判据」），而两个页面的反馈迟早要一起改。
2. **继续用 `window.confirm`，只补 toast**
   - 最强的理由：零组件、零样式。
   - 为何被否：2026-10-15 的事故就是 `window.confirm` 挡不住自动化（脚本默认 accept，
     一次删了 31 条记录）。破坏性操作必须在页内确认。
3. **把 CSS 也塞进组件（一份样式两处用）**
   - 最强的理由：真正"一个文件搞定"。
   - 为何被否：两个页面的视觉语言不同（控制台是纸张底色 + 衬线，管理台是深色海军 + 青绿），
     一份 CSS 只会逼出一堆覆盖规则。行为共用、皮肤各自，是这里正确的切法。
4. **成功时什么都不提示，靠列表变化暗示**
   - 最强的理由：少打扰。
   - 为何被否：用户已经明说"以为没效果"。写操作必须有回声，这是可用性不是打扰。

## Consequences

- 收益：每个写操作都有回声；确认框看得见、点得到、Esc 能退；两个页面同一套手感。
- 收益：新增一道机械闸 —— `tests/ui-kit.test.ts` 断言两个页面里**不许再出现**
  `alert(` / `confirm(` / `prompt(`，谁写回去立刻红。
- 代价：管理台的 `post()` 多一个 `okText` 参数，默认「已保存」；文案不准的地方要显式传
  （断开/吊销/重置/签发各一处）。
- 代价：控制台保留了四个同名薄包装（`toast`/`openModal`/`closeModal`/`confirmModal`）——
  为了不动二十来个调用点，这是有意的。
- 代价：`askValue` 只支持单行文本；多字段表单仍要走 `Kit.open` 自己搭（控制台建电脑就是这样）。

## 判据

- relay `pnpm typecheck` → 0；`node --test` → **161 条全绿**
  （新增 3 条：管理台无原生对话框且保存有回声、控制台只剩包装、取消路径兑现 Promise）。
- 静态判据：`ADMIN_PAGE` / `CONSOLE_PAGE` 里 `var Kit =` 存在、`id="toast"`/`id="modal"` 存在。

## 代码入口回指

- `relay/src/ui/kit.ts`（组件本体）。
- `relay/src/admin/page.ts` 的 `post()` / `ifConfirmed` / `withValue` 与 22 处改写。
- `relay/src/ui/console-page.ts` 的四个同名包装。
- `relay/tests/ui-kit.test.ts`（那道闸）。
