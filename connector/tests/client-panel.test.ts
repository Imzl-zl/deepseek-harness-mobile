/**
 * 浏览器半侧 `client.js` 的冒烟回归。
 *
 * ## 为什么值得单独立一篇
 *
 * `client.js` 是**手写 plain JS**（理由见那个文件的头：DSH 的 client bundle 必须是
 * 闭包工厂格式，而产出它的 tsdown 预设在 DSH 仓库里、本独立工程用不了）。
 * 于是它**没有类型检查、也不进 `pnpm build`** —— 整份文件此前的唯一验证是
 * `node --check`（只证明"能解析"，不证明"渲染得对"）。而 2026-10-15 事故的
 * 确认文案就长在这个文件里。
 *
 * 所以这里用一个**最小的 React 桩**把面板真跑一遍（单遍渲染，不跑 effect），
 * 断言四件只能在运行时发现的事：
 *
 * 1. zh / en 两份字典的**键集合相同** —— 少一个键，界面上就是一段 `undefined`；
 * 2. 源码里没有 `window.confirm`，也没有 `offline` scope 的按钮（事故的两个入口）；
 * 3. 每行的动作按钮与状态词对上新行为（未停用 → 停用+删除；已停用 → 启用+删除）；
 * 4. 点「停用」/「删除」弹出的对话框，**标题与后果句逐字符合预期** ——
 *    事故里确认框写"已吊销记录"而实际删的是离线记录，这类张冠李戴由这里钉住。
 *
 * 桩是**测试自己的**，不是产品代码的形状：产品跑在 DSH 的真 React 里。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

/** `client.js` 在包根，`exports['./client']` 指向它。 */
const CLIENT_PATH = new URL('../client.js', import.meta.url)

interface Element {
  type: string
  props: Record<string, unknown> & { children?: unknown }
}

/** 把 `h(...)` 的产出拍平成元素数组，顺手收集所有文本。 */
function flatten(node: unknown, out: Element[] = []): Element[] {
  if (Array.isArray(node)) {
    for (const child of node) flatten(child, out)
    return out
  }
  if (typeof node !== 'object' || node === null) return out
  const element = node as Element
  if (typeof element.type === 'string') out.push(element)
  flatten(element.props.children, out)
  return out
}

const textOf = (node: unknown): string => {
  if (typeof node === 'string' || typeof node === 'number') return String(node)
  if (Array.isArray(node)) return node.map(textOf).join('')
  if (typeof node === 'object' && node !== null) return textOf((node as Element).props.children)
  return ''
}

const allText = (tree: unknown): string => flatten(tree).map((element) => textOf(element.props.children)).join('\n')

/** 按可见文字找按钮。 */
const buttonWith = (tree: unknown, label: string): Element | undefined =>
  flatten(tree).find((element) => element.type === 'button' && textOf(element.props.children) === label)

/** 按类型找控件。 */
/**
 * 设备行的勾选框。
 *
 * **只认 `type === 'checkbox'`**：面板上还有别的输入框（2026-10-18 起
 * "上报地址"那块有一个填地址的文本框）。按"是不是 input"数会把文本框
 * 也算成一个勾选框，于是"每行行首一个勾选框"这条断言数出 3 个。
 */
const inputsOf = (tree: unknown): Element[] =>
  flatten(tree).filter(
    (element) => element.type === 'input' && (element.props.type ?? 'checkbox') === 'checkbox',
  )

/**
 * 表格的**数据行**（`tbody` 的那些 `tr`）。
 *
 * 不能直接数 `tr`：`thead` 里还有一个表头行，而它没有任何行级按钮。
 */
const bodyRows = (tree: unknown): Element[] => {
  const body = flatten(tree).find((element) => element.type === 'tbody')
  assert.ok(body !== undefined, '设备表必须有 tbody')
  const rows = Array.isArray(body.props.children) ? body.props.children : [body.props.children]
  return rows.filter((row): row is Element => typeof row === 'object' && row !== null)
}

/** 页面内的确认对话框（`role="alertdialog"`）。没开就是 undefined。 */
const dialogOf = (tree: unknown): Element | undefined =>
  flatten(tree).find((element) => element.props['role'] === 'alertdialog')

/** 元素的内联样式。测试里只读 `position` 这一个定位字段。 */
const positionOf = (element: Element): unknown =>
  ((element.props.style ?? {}) as Record<string, unknown>)['position']

/**
 * 最小 React 桩：`createElement` 记树，hooks 用"每次渲染重建下标"的方式实现。
 *
 * 单遍渲染足够 —— 这里不验证协调器，只验证"给定这份 status 与这份 locale，
 * 组件产出什么"。setState 直接写回 hook 槽，于是测试可以"点一下 → 重渲染 → 看结果"。
 * `useEffect` **只在首渲染跑一遍**（对齐生产：deps 稳定所以 effect 只跑一次）。
 * 早先它每遍渲染都跑，于是 `refresh()` 的 `setError('')` 会在断言前把错误清掉 ——
 * 那是桩的保真度问题，不是产品的（生产里写失败后没有 state 变化会触发重拉）。
 *
 * **函数类型的 `type` 当场渲染**（`h(AdminPanel, …)` 这种组合）：真 React 会递归
 * 渲染子组件，桩不渲染就只看到一棵"未展开"的树，断言全部落空。
 */
function makeReact() {
  let hooks: unknown[] = []
  let index = 0
  const createElement = (type: unknown, props: Record<string, unknown> | null, ...children: unknown[]): unknown => {
    const merged = { ...(props ?? {}), ...(children.length === 0 ? {} : { children: children.length === 1 ? children[0] : children }) }
    if (typeof type === 'function') {
      return (type as (p: Record<string, unknown>) => unknown)(merged)
    }
    return { type, props: merged }
  }
  return {
    createElement,
    useState(initial: unknown) {
      const at = index++
      if (!(at in hooks)) hooks[at] = typeof initial === 'function' ? (initial as () => unknown)() : initial
      return [
        hooks[at],
        (next: unknown) => {
          hooks[at] = typeof next === 'function' ? (next as (prev: unknown) => unknown)(hooks[at]) : next
        },
      ]
    },
    useRef(initial: unknown) {
      const at = index++
      if (!(at in hooks)) hooks[at] = { current: initial }
      return hooks[at] as { current: unknown }
    },
    useCallback(fn: unknown) {
      index++
      return fn
    },
    useEffect(fn: () => unknown) {
      // **按 hook 槽判首跑**（对齐生产：deps 稳定所以每个 effect 一辈子只跑
      // 一次）。不能用一个全局 flag —— 外层 ConnectorPanel 的 Esc effect 会先把
      // 它吃掉，里面 AdminPanel 的 refresh 就永远不跑了。桩每遍渲染都跑则会让
      // 异步 `setError('')` 与断言竞态（见文件头）。
      const at = index++
      if (!(at in hooks)) {
        hooks[at] = true
        fn()
      }
    },
    /** 重渲染：hook 槽保留（state 活着），下标归零。 */
    render(component: (props: Record<string, unknown>) => unknown, props: Record<string, unknown>): unknown {
      index = 0
      return component(props)
    },
    /** 换一份 props 重新跑，但**丢掉所有 state**（等价于卸载后重挂）。 */
    fresh(component: (props: Record<string, unknown>) => unknown, props: Record<string, unknown>): unknown {
      hooks = []
      index = 0
      return component(props)
    },
  }
}

/** 等 `refresh()` 那个 async 函数把 status 写进 state。 */
const flush = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))

/** 三行设备：一台在线前台、一台离线未停用、一台已停用。 */
const DEVICES = [
  { id: 'dev-live', name: '我的手机', pairedAt: 1760000000000, revoked: false, online: true, foreground: true, lastInteractedAt: 1760000600000 },
  { id: 'dev-idle', name: '平板', pairedAt: 1750000000000, revoked: false, online: false, foreground: false },
  { id: 'dev-gone', name: '旧手机', pairedAt: 1740000000000, revoked: true, online: false, foreground: false },
]

/** 两条传输通道（按"方式"分开关，2026-10-17）。 */
const CHANNELS = [
  { id: 'relay', label: '中转拨号', running: true, detail: 'ws://127.0.0.1:8787/ws/connector' },
  { id: 'direct', label: '直连监听', running: true, detail: '0.0.0.0:8790' },
]

/** status 与 /transport 两份读面的默认桩。 */
const defaultFetch = (channels: unknown[] = CHANNELS) => async (url: string) =>
  String(url).includes('/transport')
    ? { ok: true, status: 200, json: async () => ({ channels }) }
    : { ok: true, status: 200, json: async () => ({ relayUrl: 'ws://127.0.0.1:8787/ws/connector', devices: DEVICES }) }

/** 把 `client.js` 装起来，交出「渲染函数」与「它注册的 locale 字典」。 */
function loadClient(fetchImpl?: (url: string, init?: unknown) => unknown) {
  const source = readFileSync(CLIENT_PATH, 'utf8')
  let loaded: { factory: (require: (id: string) => unknown) => { apply: (ctx: unknown) => void } } | null = null
  const window = { __ModuleLoader__: { load: (mod: typeof loaded) => { loaded = mod } } }
  // `client.js` 只在 `askConfirm` 里碰 `document.activeElement`，桩一个就够。
  // **addEventListener 也要桩**：ConnectorPanel 的 Esc 关闭挂在 document 上。
  ;(globalThis as { document?: unknown }).document = {
    activeElement: null,
    addEventListener: () => {},
    removeEventListener: () => {},
  }
  // 首渲染的 effect 会拉 status 与 /transport；这里回一份和 `DEVICES` 一致的。
  ;(globalThis as { fetch?: unknown }).fetch = fetchImpl ?? defaultFetch()
  new Function('window', source)(window)
  assert.ok(loaded !== null, 'client.js 必须调用 window.__ModuleLoader__.load')

  const react = makeReact()
  // `react-dom` 是平台基线外部（`client/web/src/platform.ts:9`）；桩的
  // `createPortal` 原样返回节点 —— 测试只验树，不验证挂载点。
  const reactDom = { createPortal: (node: unknown) => node }
  let registered: { zh: Record<string, string>; en: Record<string, string> } | null = null
  const panels: Array<(props: Record<string, unknown>) => unknown> = []
  let layoutSelects: Array<string | null> = []
  const module = (loaded as unknown as {
    factory: (require: (id: string) => unknown) => {
      apply: (ctx: unknown) => void
    }
  }).factory((id: string) => (id === 'react-dom' ? reactDom : react))
  module.apply({
    effect: (fn: () => unknown) => fn(),
    locale: { register: (_ns: string, dict: { zh: Record<string, string>; en: Record<string, string> }) => { registered = dict } },
    layout: { selectPanel: (id: string | null) => { layoutSelects.push(id) } },
    slots: {
      // `inject(slot, factory)` 的语义是"在这个 slot 上注册"，所以要把 factory 调起来。
      inject: (_slot: string, factory: () => unknown) => factory(),
      register: (_def: unknown, component: (props: Record<string, unknown>) => unknown) => { panels.push(component) },
    },
  })
  assert.ok(registered !== null, '必须注册 locale 字典')
  // 两个注册：侧边栏图标 + 主面板（弹框）。顺序即注册顺序。
  assert.equal(panels.length, 2, '必须注册侧边栏条目与主面板两个组件')
  return {
    react,
    dict: registered as unknown as { zh: Record<string, string>; en: Record<string, string> },
    panel: panels[1] as unknown as (props: Record<string, unknown>) => unknown,
    icon: panels[0] as unknown as (props: Record<string, unknown>) => unknown,
    layoutSelects,
  }
}

/** 挂载面板：首渲染 → 等 status 落进 state → 再渲染一遍拿到有数据的那棵树。 */
async function mountPanel(extra: Record<string, unknown> = {}, fetchImpl?: (url: string, init?: unknown) => unknown) {
  const loaded = loadClient(fetchImpl)
  const t = translate(loaded.dict.zh)
  const props = { view: 'page', t, ...extra }
  loaded.react.fresh(loaded.panel, props)
  await flush()
  const tree = loaded.react.render(loaded.panel, props)
  return { ...loaded, props, tree, t }
}

/** `t(key, params)` 的最小实现：DSH 的 `Translate`（`ui-slots/src/index.ts:54`）。 */
const translate = (dict: Record<string, string>) => (key: string, params?: Record<string, unknown>): string => {
  const template = dict[key]
  assert.ok(template !== undefined, `locale 里没有键 ${key} —— 界面上会显示 undefined`)
  return template.replace(/\{(\w+)\}/g, (match, name: string) => String(params?.[name] ?? match))
}

test('locale：zh 与 en 的键集合相同（少一个键界面上就是一段 undefined）', () => {
  const { dict } = loadClient()
  const zh = Object.keys(dict.zh).sort()
  const en = Object.keys(dict.en).sort()
  assert.deepEqual(zh, en, '两份字典必须同步 —— 漏一个键，那半边界面显示 undefined')
  // 空串不是文案：占位键会静默变成"什么都没有"。
  for (const key of zh) {
    assert.notEqual(dict.zh[key], '', `zh.${key} 不能是空串`)
    assert.notEqual(dict.en[key], '', `en.${key} 不能是空串`)
  }
})

test('源码里没有 window.confirm，也没有按离线批量清（事故的两个入口）', () => {
  const source = readFileSync(CLIENT_PATH, 'utf8')
  // **先剥注释再扫**：文件头有大段解释"为什么不用 window.confirm"的注释，
  // 直接按文本扫会把注释里的词当成代码。
  const code = source.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ')
  assert.doesNotMatch(code, /window\.confirm/, '破坏性操作必须走页面内对话框（2026-10-15 事故）')
  assert.doesNotMatch(code, /scope:\s*'offline'/, '按当前离线批量硬删已删：它命中"暂时离线但还在用"的设备')
  assert.doesNotMatch(code, /allOffline/, 'revokeAllOffline 端点已删，不许有调用者')
  assert.doesNotMatch(code, /cleanOffline/, '没有"清掉当前离线"这个按钮')
})

test('面板：每行的动作按钮与状态词对上新行为', async () => {
  const { tree } = await mountPanel()

  const text = allText(tree)
  // 状态词照 DSH：运行中 / 未运行 / 已停用。
  assert.match(text, /运行中/, '在线的行显示"运行中"')
  assert.match(text, /未运行/, '离线未停用的行显示"未运行"')
  assert.match(text, /已停用/, '停用的行显示"已停用"')
  // 已停用默认折叠，有一行展开入口。
  assert.match(text, /已停用 1 台 · 展开/)

  // 未停用的行（在线的我那台）：「停用」+「删除」。
  const rows = bodyRows(tree)
  assert.equal(rows.length, 2, '默认只显示未停用的两行')
  const liveRow = rows[0] as Element
  assert.equal(buttonWith(liveRow, '停用') !== undefined, true, '未停用的行有「停用」')
  assert.equal(buttonWith(liveRow, '删除') !== undefined, true, '未停用的行有「删除」')
  assert.equal(buttonWith(liveRow, '启用'), undefined, '未停用的行不该有「启用」')

  // 按状态清只剩两种，且**没有"清掉当前离线"**。
  assert.equal(buttonWith(tree, '清掉已停用记录（1）') !== undefined, true)
  assert.equal(buttonWith(tree, '清空全部记录（3）') !== undefined, true)
  assert.equal(
    flatten(tree).some((element) => element.type === 'button' && /当前离线/.test(textOf(element.props.children))),
    false,
    '没有"清掉当前离线"这个按钮',
  )
  // 行首有勾选框（多选入口）。
  assert.equal(inputsOf(tree).length, 2, '每行行首一个勾选框')
  // 对话框没开时页面上不该有它。
  assert.equal(buttonWith(tree, '取消'), undefined, '没开确认框时不出现「取消」')
})

test('面板：勾选后出现浮现操作栏，不改变行本身', async () => {
  const { react, panel, props, tree } = await mountPanel()
  assert.equal(buttonWith(tree, '删除所选'), undefined, '没勾选时不出现操作栏')

  // 勾第一行的 checkbox（那台在线的我的手机）。
  const checkbox = inputsOf(tree)[0]
  assert.ok(checkbox !== undefined, '每行行首有一个勾选框')
  ;(checkbox.props.onChange as () => void)()

  const after = react.render(panel, props)
  const text = allText(after)
  assert.match(text, /已选 1 台/, '浮现栏显示已选几台')
  assert.equal(buttonWith(after, '删除所选') !== undefined, true, '浮现栏有「删除所选」')
  assert.equal(buttonWith(after, '取消') !== undefined, true, '浮现栏有「取消」')
  // **行本身没变**：还是那两个按钮，没有被勾选框挤掉。
  const rows = bodyRows(after)
  assert.equal(buttonWith(rows[0] as Element, '停用') !== undefined, true, '勾选不改变行级按钮')
  assert.equal(buttonWith(rows[0] as Element, '删除') !== undefined, true, '勾选不改变行级按钮')
})

test('对话框：停用的后果写明"下次重连就会失败"，确认键是「停用」', async () => {
  const { react, panel, props, tree } = await mountPanel()

  const disable = buttonWith(bodyRows(tree)[0] as Element, '停用')
  assert.ok(disable !== undefined)
  ;(disable.props.onClick as () => void)()

  const shown = react.render(panel, props)
  assert.match(allText(shown), /停用「我的手机」？/, '标题是问句')
  assert.match(
    allText(shown),
    /那台手机下次重连就会失败,需要重新配对才能恢复。记录仍会保留。/,
    '后果必须逐字对上新行为：停用是软的、可恢复、记录仍会保留',
  )
  assert.equal(buttonWith(shown, '停用') !== undefined, true, '确认键是「停用」')
  assert.equal(buttonWith(shown, '取消') !== undefined, true, '有取消')
})

test('对话框：删除在线那台的后果句是"正在使用 + 要重新配对"，不是"不会删除"', async () => {
  const { react, panel, props, tree } = await mountPanel()

  const remove = buttonWith(bodyRows(tree)[0] as Element, '删除')
  assert.ok(remove !== undefined)
  ;(remove.props.onClick as () => void)()

  const dialog = allText(react.render(panel, props))
  assert.match(dialog, /删除「我的手机」？/)
  // **显式删除可以删在线的**（不变量 2）：手机丢了还在线，要立刻弄死它，
  // 为此先"让那台手机断开连接"是荒谬的。所以既不能说"不会删除"（假），
  // 也不能不提它在用。
  assert.match(dialog, /这台在线,正在使用。删除后它需要重新配对。/)
  assert.doesNotMatch(dialog, /不会删除/, '在线那台照样删，不许承诺"不会删除"')
  assert.doesNotMatch(dialog, /会跳过/, '"跳过"只属于按状态批量')
})

test('对话框：删除离线那台的后果句是"那台手机需要重新配对"', async () => {
  const { react, panel, props, tree } = await mountPanel()

  // 第二行是离线未停用的平板。
  const remove = buttonWith(bodyRows(tree)[1] as Element, '删除')
  assert.ok(remove !== undefined)
  ;(remove.props.onClick as () => void)()

  const dialog = allText(react.render(panel, props))
  assert.match(dialog, /删除「平板」？/)
  assert.match(dialog, /那台手机需要重新配对。/)
})

// ---- 2026-10-17：侧边栏弹框 + 传输方式分开关 + 配对时间列 ----

test('注册：侧边栏条目与主面板两个组件，且都走标准槽', async () => {
  const source = readFileSync(CLIENT_PATH, 'utf8')
  const code = source.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ')
  assert.match(code, /slots\.inject\('sidebar\.panellist'/, '侧边栏条目走标准列表槽')
  assert.match(code, /slots\.inject\('main'/, '主面板走标准 keyed 槽')
  assert.match(code, /order:\s*5/, 'order 5：插件(0)之下、自动化任务(10)之上')
  assert.doesNotMatch(code, /plugins\.bundle\.config/, '插件页那张卡已撤（用户明确不要那个入口）')
})

test('弹框：role=dialog + 关闭键走 selectPanel(null)（标准"回会话视图"）', async () => {
  const selects: Array<string | null> = []
  const close = () => selects.push(null)
  const { react, panel, props, tree } = await mountPanel({ close })

  const box = flatten(tree).find((element) => element.props['role'] === 'dialog')
  assert.ok(box !== undefined, '主面板渲染成弹框（role=dialog）')
  assert.equal(box?.props['aria-modal'], true)
  assert.equal(buttonWith(tree, '关闭') !== undefined, true, '有关闭键')

  const closeButton = buttonWith(tree, '关闭') as Element
  ;(closeButton.props.onClick as () => void)()
  assert.deepEqual(selects, [null], '关闭 = 调注入的 close（装配层接 selectPanel(null)），不自己造导航')
  // 渲染不炸（桩的 portal 原样返回）。
  assert.ok(allText(react.render(panel, props)).length > 0)
})

// ---- 传输方式：每个通道一个开关（2026-10-17 用户："两个方式两个开关"）----

test('传输方式：每个通道一行开关，行来自 GET /transport（不写死通道 id）', async () => {
  const { tree } = await mountPanel()
  const text = allText(tree)
  // 两条通道各一行：标签 + 状态 + 详情 + 自己的启停键。
  assert.match(text, /中转拨号/)
  assert.match(text, /直连监听/)
  assert.equal(buttonWith(tree, '启动') , undefined, '运行中的通道给的是「停止」')
  const stops = flatten(tree).filter((element) => element.type === 'button' && textOf(element.props.children) === '停止')
  assert.equal(stops.length, 2, '两条在跑的通道各一个「停止」')
  // 批量入口（同时开 / 同时关是常态）。
  assert.equal(buttonWith(tree, '全部启动') !== undefined, true)
  assert.equal(buttonWith(tree, '全部停止') !== undefined, true)
})

test('传输方式：电脑侧说停了，那一行的键换成「启动」', async () => {
  const stopped = [
    { id: 'relay', label: '中转拨号', running: false, detail: 'ws://127.0.0.1:8787/ws/connector' },
    { id: 'direct', label: '直连监听', running: false, detail: '未配置监听端口（listenPort: 0）' },
  ]
  const { tree } = await mountPanel({}, defaultFetch(stopped))
  const starts = flatten(tree).filter((element) => element.type === 'button' && textOf(element.props.children) === '启动')
  assert.equal(starts.length, 2, '两条停着的通道各一个「启动」')
  assert.match(allText(tree), /直连监听[\s\S]*未配置监听端口/, '未配置的通道说清原因')
})

test('传输方式：点一行的「停止」打的是 /transport/{id}/stop，跑完重拉状态', async () => {
  const seen: string[] = []
  const { tree } = await mountPanel({}, async (url: string) => {
    seen.push(String(url))
    return defaultFetch()(url)
  })
  // 第一行是中转拨号（在跑 ⇒ 「停止」）。
  const stop = flatten(tree).find((element) =>
    element.type === 'button' && textOf(element.props.children) === '停止') as Element
  assert.ok(stop !== undefined, '在跑的通道给「停止」')
  await (stop.props.onClick as () => Promise<void>)()
  assert.ok(seen.includes('/api/dsh-mobile/transport/relay/stop'), `应打 relay/stop，实际 ${seen.join(',')}`)
  // 跑完重拉了 /transport（按钮状态要从电脑侧真值来，不乐观翻转）。
  assert.ok(seen.filter((url) => url.includes('/transport')).length >= 2, '跑完要重拉通道列表')
})

test('传输方式：加第三种方式不改 UI 形状（三个通道渲染三行）', async () => {
  const three = [...CHANNELS, { id: 'tailscale', label: 'Tailscale', running: false, detail: '未配置' }]
  const { tree } = await mountPanel({}, defaultFetch(three))
  const text = allText(tree)
  assert.match(text, /Tailscale/)
  const stops = flatten(tree).filter((element) => element.type === 'button' && textOf(element.props.children) === '停止')
  const starts = flatten(tree).filter((element) => element.type === 'button' && textOf(element.props.children) === '启动')
  assert.equal(stops.length, 2, '两条在跑的给「停止」')
  assert.equal(starts.length, 1, '停着的那条给「启动」')
})

test('传输方式：启动失败带原因显示在面板顶部（端口被占）', async () => {
  // 直连是停着状态，点「启动」而电脑侧回 400 + 原话（端口被占）。
  const failing = async (url: string) =>
    String(url).endsWith('/api/dsh-mobile/transport/direct/start')
      ? { ok: false, status: 400, json: async () => ({ ok: false, error: 'listen EADDRINUSE: address already in use 8790' }) }
      : defaultFetch([
        { id: 'relay', label: '中转拨号', running: true, detail: 'ws://127.0.0.1:8787/ws/connector' },
        { id: 'direct', label: '直连监听', running: false, detail: '0.0.0.0:8790' },
      ])(url)
  const { react, panel, props, tree } = await mountPanel({}, failing)

  const start = flatten(tree).filter((element) =>
    element.type === 'button' && textOf(element.props.children) === '启动')[0] as Element
  assert.ok(start !== undefined, '停着的直连给「启动」')
  await (start.props.onClick as () => Promise<void>)()

  const text = allText(react.render(panel, props))
  assert.match(text, /启动失败：listen EADDRINUSE/, '失败要带原因，且要能被看见')
})

test('设备表有「配对于」列：同一台手机扫几次码就有几条，按配对时间认出一条', async () => {
  const { tree } = await mountPanel()
  const head = flatten(tree).find((element) => element.type === 'thead')
  assert.match(textOf(head?.props.children), /配对于/, '表头有「配对于」')
  // 第一行的配对于列是**绝对时间**（不是相对时间、也不是 '—'）——
  // 要认出"哪条是最新那条"，相对时间给不出这个答案。
  const firstRow = bodyRows(tree)[0] as Element
  const cells = Array.isArray(firstRow.props.children) ? firstRow.props.children : [firstRow.props.children]
  const pairedCell = textOf(cells[2])
  assert.notEqual(pairedCell, '', '配对于列有内容')
  assert.notEqual(pairedCell, '—', '配对于列不是占位符')
  assert.match(pairedCell, /\d/, '配对于列渲染出可读的时间')
})

test('对话框：删除所选时，有在线报"其中 {s} 台在线"，无在线就不提', async () => {
  const { react, panel, props, tree } = await mountPanel()
  // 两行都勾：一台在线、一台离线。**每勾一下都要重渲染、并且重新取那一行的
  // checkbox** —— `onChange` 闭包捕获的是当次渲染的 `selected`，沿用旧树上的控件
  // 会互相覆盖（真 React 在两次事件之间会重渲染；这是桩，得手动补上那两步）。
  let current: unknown = tree
  for (let row = 0; row < 2; row += 1) {
    const checkbox = inputsOf(current)[row]
    assert.ok(checkbox !== undefined, `第 ${row} 行应有勾选框`)
    ;(checkbox.props.onChange as () => void)()
    current = react.render(panel, props)
  }
  const picked = current
  const removeSelected = buttonWith(picked, '删除所选')
  assert.ok(removeSelected !== undefined)
  ;(removeSelected.props.onClick as () => void)()

  const dialog = allText(react.render(panel, props))
  assert.match(dialog, /删除所选的 2 台设备？/)
  // 一台在线：说明规模里有几台在用，但**不提"跳过"**（显式删除一台都不跳）。
  assert.match(dialog, /其中 1 台在线,正在使用。被删的设备都需要重新配对。/)
  assert.doesNotMatch(dialog, /会跳过/, '显式删除不许承诺"跳过"')

  // 只勾离线那台：句子不该出现"其中 0 台在线"。
  const offlineOnly = await mountPanel()
  const offlineCheckbox = inputsOf(offlineOnly.tree)[1]
  assert.ok(offlineCheckbox !== undefined)
  ;(offlineCheckbox.props.onChange as () => void)()
  const onePicked = offlineOnly.react.render(offlineOnly.panel, offlineOnly.props)
  const again = buttonWith(onePicked, '删除所选')
  assert.ok(again !== undefined)
  ;(again.props.onClick as () => void)()
  const solo = allText(offlineOnly.react.render(offlineOnly.panel, offlineOnly.props))
  assert.match(solo, /删除所选的 1 台设备？/)
  assert.match(solo, /被删的那几台手机都需要重新配对。/)
  assert.doesNotMatch(solo, /其中 0 台在线/)
})

test('对话框：按状态清的后果句必带"那几台手机需要重新配对"，全部还要带跳过数', async () => {
  const { react, panel, props, tree } = await mountPanel()

  const cleanRevoked = buttonWith(tree, '清掉已停用记录（1）')
  assert.ok(cleanRevoked !== undefined)
  ;(cleanRevoked.props.onClick as () => void)()
  let dialog = allText(react.render(panel, props))
  assert.match(dialog, /删除已停用的 1 台设备？/, '标题带数量')
  assert.match(dialog, /那几台手机需要重新配对。/)

  const clearAll = buttonWith(react.render(panel, props), '清空全部记录（3）')
  assert.ok(clearAll !== undefined)
  ;(clearAll.props.onClick as () => void)()
  dialog = allText(react.render(panel, props))
  assert.match(dialog, /删除全部 3 台设备？/)
  assert.match(dialog, /在线的 1 台会跳过。那几台手机需要重新配对。/)
})

test('弹框遮罩用 fixed（主面板是框架根级区域，没有带 transform 的祖先）', async () => {
  const { react, panel, props, tree } = await mountPanel()
  // 2026-10-17 迁到侧边栏弹框后，定位基准从"插件页卡片"换成"主面板"——
  // 主面板是 `main` keyed 槽的根级区域，`createPortal` 挂到 body，
  // 没有带 transform 的祖先，fixed  therefore 安全且能盖住整页。
  assert.equal(positionOf(tree as Element), 'fixed', '遮罩 fixed：盖住整页')

  const disable = buttonWith(bodyRows(tree)[0] as Element, '停用')
  assert.ok(disable !== undefined)
  ;(disable.props.onClick as () => void)()
  const shown = react.render(panel, props)
  // 面板内的确认对话框仍用 absolute：它的基准是 S.wrap（position: relative），
  // 盖住弹框本体就够了 —— 不需要也不该盖到整页。
  const mask = flatten(shown).find((element) => positionOf(element) === 'absolute')
  assert.ok(mask !== undefined, '确认对话框遮罩绝对定位于面板自身')
  const wrap = flatten(shown).find((element) => positionOf(element) === 'relative')
  assert.ok(wrap !== undefined, 'S.wrap 仍是定位基准')
})

test('失败必须带原因显示在面板顶部（照 DSH `停用失败：{reason}`）', async () => {
  // status 与 /transport 照常成功，**写端点**回 400 + 原话；界面必须把它显示出来，
  // 而不是静默什么都不做。
  const failing = async (url: string) => {
    const path = String(url)
    if (path.endsWith('/api/dsh-mobile/status')) {
      return { ok: true, status: 200, json: async () => ({ relayUrl: 'ws://127.0.0.1:8787/ws/connector', devices: DEVICES }) }
    }
    if (path.endsWith('/api/dsh-mobile/transport')) {
      return { ok: true, status: 200, json: async () => ({ channels: CHANNELS }) }
    }
    return { ok: false, status: 400, json: async () => ({ ok: false, error: '名册上报失败：中转不应答' }) }
  }
  const { react, panel, props, tree } = await mountPanel({}, failing)

  const disable = buttonWith(bodyRows(tree)[0] as Element, '停用')
  assert.ok(disable !== undefined)
  ;(disable.props.onClick as () => void)()
  const shown = react.render(panel, props)
  const dialog = dialogOf(shown)
  assert.ok(dialog !== undefined, '点「停用」应当弹出页面内对话框')
  const confirmButton = buttonWith(dialog, '停用')
  assert.ok(confirmButton !== undefined, '对话框里的确认键是「停用」')
  ;(confirmButton.props.onClick as () => void)()
  // 确认键跑起来是 async，等它落定。
  await flush()

  // **只从一棵树断言**：桩的 `useEffect` 每遍渲染都重跑（生产的 deps 稳定、
  // 只跑一次），多渲染一遍会让 refresh 的 `setError('')` 赶上来了 —— 那是桩的
  // 保真度问题，不是产品的。生产里写失败后没有 state 变化会触发重拉。
  const after = react.render(panel, props)
  assert.match(allText(after), /停用失败：名册上报失败：中转不应答/, '失败要带原因，且要能被看见')
  // 对话框已经关掉：跑起来之后不该还挂着一层遮罩。
  assert.equal(dialogOf(after), undefined, '跑起来就关框')
})

