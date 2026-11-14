/**
 * 尺寸预算棘轮：`app/lib` 的文件行数与单类方法数**只降不升**。
 *
 * 跑法：`node app/tools/verify-size.mjs`（不需要 Flutter 工程、不需要浏览器）
 *
 * 判据与取舍见 `.agents/notes/implemented/2026-11-10-size-budget-ratchet.md`。
 *
 * ## 它为什么存在
 *
 * 本仓所有别的结构性约束都有机械门禁：分层（`verify-platform-boundary.mjs` 9 条规则）、
 * 协议知识只在 `wire/`（`verify-rpc-single-caller.mjs`）、图标只有一个来源、
 * 工具脚本不许写盘符……唯独"这一坨代码该多大"没有 —— 于是
 * `data/app_model.dart` 长到 5209 行 / 178 个方法、`ui/chat_page.dart` 长到 5278 行，
 * 而**没有任何东西会在下次变大时提醒任何人**（收窄提案躺在
 * `proposed/2026-10-27-ui-state-design.md` 里，没有落地的机械抓手）。
 *
 * 这条门禁不做"重构"，只做两件事：**钉住今天的实测值**，以及**把它当上限**。
 * 想往上加，就得先在同一个文件里削掉同样的量 —— 拆分的成本因此永远小于"再塞一段"。
 *
 * ## 为什么只数"文件行数"与"类方法数"，不数"函数长度"
 *
 * 函数长度需要一个真解析器才数得准。正则 + 括号计数的做法**在本仓不可信**：
 * 注释与字符串里大量出现 `{` `}`（`chat_item.dart` 的注释占 50%），
 * 括号深度会被吃掉 —— 实测用它数 `_isStateOnlyEvent`（实际一行）得到 285 行，
 * 因为它一路把下一个方法的 `}` 也算了进去。**一个会撒谎的门禁比没有门禁更糟**：
 * 它给出的数字没人敢信，于是大家都绕过它。
 *
 * 行数（数 `\n`，与 `wc -l` 同一口径）与"2 空格缩进的成员声明"这两样是**确定可数**的。
 * 它们不是完美的复杂度度量，但它们是**不会骗人**的代理指标，而代理指标的全部价值
 * 就在于可信。
 *
 * ## 两种计数，两种余量（这条区别是刻意的）
 *
 * - **方法数 = 精确值**。它只在有人加/删成员时才变，而那正是我们要拦的结构性增长。
 *   留余量等于留一条"再塞两个方法也不要紧"的暗门（第一版留了 5 的余量，
 *   变异校验里加一个方法**没有红** —— 那 2 个空档就是暗门）。
 * - **行数 = 向上取整到 50**。行数会因**非结构性**原因变（改注释、格式化、
 *   字符串换行），精确值会把一次错字修复变成一次表格改动。50 行是"一次性小改不会红"的上界。
 *
 * 两个方向都红：长了要削或把数字提上去（提是一次可见的 diff），
 * 瘦了要把数字压下来（否则棘轮会松掉）。**没有任何"这段先放过"的余地。**
 *
 * ## 表的维护
 *
 * - 新增一项 = 承认这个文件/类**暂时**超线。必须在该项右侧写一句它为什么该被拆。
 * - 删掉一项 = 它已经达标，棘轮棘下去了，别再放回来。
 * - 表里指定了但扫不到（改名 / 删除 / 抄错）= 红：那条预算从此永不求值，
 *   等于一条永不作废的假绿（`verify-platform-boundary.mjs` 在
 *   `app/packages` 与 `platform/registry.dart` 上两次栽在这一条）。
 */
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = 'app/lib'

/** 不在表里的文件，行数不得超过这个数。 */
const DEFAULT_FILE_LINES = 800
/** 不在表里的类，成员方法不得超过这个数。 */
const DEFAULT_CLASS_METHODS = 30
/** 行数余量（向上取整的步长）。方法数不取整 —— 见文件头的"两种余量"。 */
const FILE_STEP = 50

/**
 * 文件行数预算。数字 = 写这篇时的实测向上取整，**不是目标值**。
 *
 * 每项右侧的注释是"它为什么该被拆"；拆完就别再把它放回来。
 */
const FILE_BUDGET = [
  ['app/lib/ui/chat_page.dart', 4450], // 一个 State 里塞了整页脚手架（`_mainScaffold` 414 行）；2026-11-12 文件面板搬去 `ui/files_pane.dart`（5300 → 4800），同日改动卡搬去 `ui/changes_card.dart`、轨迹页签搬进 `ui/trajectory_page.dart`（4800 → 4450）
  ['app/lib/data/app_model.dart', 5204], // host 投影的 façade；会话内存压缩策略（2026-11-11）在这里，+25 行是有意的；2026-11-12 `job.list` 等 `repo.info`（+15 行，见 `implemented/2026-11-12-caps-settlement.md`）；同日提醒簇搬去 `data/notices.dart`（−88 行，5250 → 5150）；2026-11-14 Agent Teams 只读面 +17 行（`caps.team` 与 `teamBoard`）；同日 +37 行是 Team 开关的写路径（`setTeamEnabled` + `modelEverUsed`，读完投影才改状态），两次都见 `implemented/2026-11-14-agent-team-integration.md`
  ['app/lib/core/sync_client_impl.dart', 2050], // 连接层，收帧/恢复/写操作三件事在同一类
  ['app/lib/ui/chat_turns.dart', 2050], // 逐种条目的渲染器，可按条目族分文件；2026-11-12 a11y 批给六处可折行补了角色（+10 行，见 `implemented/2026-11-12-a11y-chat-turns-and-panes.md`）
  ['app/lib/main.dart', 1950], // 装配点 + 路由 + 抽屉回调，装配之外的部分可下沉
  ['app/lib/ui/dsh_composer.dart', 1850], // `build` 一个方法 357 行
  ['app/lib/ui/usage_page.dart', 1600], // 图表与列表可分开
  ['app/lib/ui/session_drawer.dart', 1400], // 抽屉 + 会话行 + 分组
  ['app/lib/ui/settings_page.dart', 1350], // 42 项设置，可按分组分文件
  ['app/lib/model/chat_item.dart', 1250], // 条目族定义，可按族拆
  ['app/lib/ui/takeover.dart', 1250], // 接管队列 + 三种卡
  ['app/lib/data/projection.dart', 1150], // 事件投影，可按事件族拆
  ['app/lib/ui/pairing_page.dart', 1000], // 配对三段式
  ['app/lib/ui/side_pane.dart', 982], // 四个面板；2026-11-14 第四枚「任务板」+32 行（枚举值 / 三个入参 / 徽标与主体分支 / 选中项回落的 6 行），**可见性规则不在这个文件**（`ui/side_panel_visibility.dart`）—— 再长就按面板拆文件，见 `implemented/2026-11-14-agent-team-integration.md`
  ['app/lib/ui/plugins_page.dart', 900], // 清单/详情/日志三面
]

/**
 * 类的方法数预算。**数字必须等于实测值**（不是上限，是"今天在这一格"）。
 * 名字必须**唯一**（同名类出现在两个文件里就是抄错了）。
 */
const CLASS_BUDGET = [
  ['AppModel', 177], // 收窄：任务簇（2026-11-11）与提醒簇（2026-11-12：`_noticeKeyOf` / `_desiredNotices`）已搬走；+1 = 后台任务提醒档 setter（2026-11-13）；+1 = Agent Teams 开关 `setTeamEnabled`（2026-11-14，见 `implemented/2026-11-14-agent-team-integration.md`）
  ['ChatPageState', 65], // 面板/文件区/轨迹该各自成 widget
  ['_SyncClient', 61], // 收帧 / 恢复 / 写操作三件事在同一类
  ['_DshMobileAppState', 48], // 装配之外的路由回调可下沉
]

const CLASS_DECL = /^class\s+(\w+)/
/**
 * "类成员方法"的判据：**2 空格缩进 + 返回类型 + 名字 + `(` 或 `<`**。
 *
 * 不数字段：字段的声明形态太多（`late final`、多行泛型、初始化表达式折行），
 * 数出来的东西会因为排版而抖。方法形态稳定，抖不动。
 *
 * **不额外判注释**：`METHOD_DECL` 要求 2 空格后直接是类型记号，`//` / `///` / `*`
 * 都接不上 —— 所以注释里的 `void m() {}` 天然不计数。这条性质靠**自检样本**钉住
 * （两空格的行注释与文档注释各一条）：哪天有人放松 `METHOD_DECL`，样本会先红。
 */
const METHOD_DECL =
  /^ {2}(?:@override\s+)?(?:static\s+)?(?:Future<[^>]*>|Stream<[^>]*>|void|bool|int|double|String|Widget|List<[^>]*>|[A-Z][\w.]*)\??\s+(\w+)\s*[<(]/

const ceil = (n, step) => Math.ceil(n / step) * step

// 自检样本**不手抄表里的数字**：表一改（收窄一次就要改），样本会跟着红 ——
// 而那时红的是「样本过时」，读起来像「规则坏了」。从表里取。
const budgetOf = (table, key) => {
  const hit = table.find(([name]) => name === key)
  if (hit === undefined) throw new Error(`自检样本指名的 ${key} 不在表里`)
  return hit[1]
}
const CHAT_PAGE_LINES = budgetOf(FILE_BUDGET, 'app/lib/ui/chat_page.dart')
const APP_MODEL_METHODS = budgetOf(CLASS_BUDGET, 'AppModel')

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) walk(full, out)
    else if (entry.endsWith('.dart')) out.push(full)
  }
  return out
}

/** 行数与 `wc -l` 同一口径：数 `\n`，不数"最后一行没有换行"的那半行。 */
const lineCount = (text) => (text.match(/\n/g) ?? []).length

/** 量一个文件的 (行数, [(类名, 方法数)])。 */
function measure(relPath, text) {
  const rows = []
  let current = null
  for (const line of text.split('\n')) {
    const decl = CLASS_DECL.exec(line)
    if (decl) {
      current = { name: decl[1], methods: 0 }
      rows.push(current)
    }
    if (current && METHOD_DECL.test(line)) {
      current.methods++
    }
  }
  return { path: relPath, lines: lineCount(text), classes: rows }
}

// ---------------------------------------------------------------------------
// 四条规则：输入是"一批测量结果"，输出是违规列表
// ---------------------------------------------------------------------------

/**
 * @param {{path: string, lines: number, classes: {name: string, methods: number}[]}[]} measured
 */
const RULES = [
  {
    id: 'file-lines',
    why: '文件超线：先拆再改。表里的数字是上限，不是目标值',
    run: (measured) => {
      const budget = new Map(FILE_BUDGET)
      const out = []
      for (const file of measured) {
        const ceiling = budget.get(file.path) ?? DEFAULT_FILE_LINES
        if (file.lines > ceiling) {
          out.push(
            `${file.path} 实测 ${file.lines} 行 > 上限 ${ceiling}`
              + (budget.has(file.path) ? '（表内）' : '（默认）'),
          )
        }
      }
      return out
    },
  },
  {
    id: 'class-methods',
    why: '类超线：它在承担两件以上的事。按族抽出去，别再加分支',
    run: (measured) => {
      const budget = new Map(CLASS_BUDGET)
      const out = []
      for (const file of measured) {
        for (const cls of file.classes) {
          const ceiling = budget.get(cls.name) ?? DEFAULT_CLASS_METHODS
          if (cls.methods > ceiling) {
            out.push(
              `${cls.name}（${file.path}）实测 ${cls.methods} 个方法 > 上限 ${ceiling}`
                + (budget.has(cls.name) ? '（表内）' : '（默认）'),
            )
          }
        }
      }
      return out
    },
  },
  {
    id: 'budget-applies',
    why: '表里的条目扫不到 = 那条预算永不求值（改名 / 抄错 / 已删）',
    run: (measured) => {
      const paths = new Set(measured.map((m) => m.path))
      const classNames = new Set(measured.flatMap((m) => m.classes.map((c) => c.name)))
      const out = []
      for (const [path] of FILE_BUDGET) {
        if (!paths.has(path)) out.push(`FILE_BUDGET 的 '${path}' 扫不到任何文件`)
      }
      for (const [name] of CLASS_BUDGET) {
        if (!classNames.has(name)) out.push(`CLASS_BUDGET 的 '${name}' 扫不到任何类`)
      }
      return out
    },
  },
  {
    id: 'budget-not-stale',
    why: '瘦了就得把数字收紧，否则棘轮会松掉（数字大到没人在意时，门禁等于没有）',
    run: (measured) => {
      const lines = new Map(measured.map((m) => [m.path, m.lines]))
      const methods = new Map()
      for (const file of measured) {
        for (const cls of file.classes) methods.set(cls.name, cls.methods)
      }
      const out = []
      for (const [path, ceiling] of FILE_BUDGET) {
        if (!lines.has(path)) continue
        if (ceiling > ceil(lines.get(path), FILE_STEP)) {
          out.push(
            `${path} 已降到 ${lines.get(path)} 行，上限应收紧成 ${ceil(lines.get(path), FILE_STEP)}（现在写着 ${ceiling}）`,
          )
        }
      }
      // 方法数是精确值：**少了也必须改表**（否则改完后还留着上次的空档）。
      for (const [name, ceiling] of CLASS_BUDGET) {
        if (!methods.has(name)) continue
        if (ceiling !== methods.get(name)) {
          out.push(
            `${name} 实测 ${methods.get(name)} 个方法，表里写着 ${ceiling}`
              + '（这一格必须等于实测值：长了要削或提数字，瘦了要压数字）',
          )
        }
      }
      return out
    },
  },
]

// ---------------------------------------------------------------------------
// 自检：每条规则都要能拦住反例、放过正例
//
// 只证明"规则会拦"不够，还要证明"规则扫得到"（`budget-applies` 那两个样本）。
// ---------------------------------------------------------------------------

const sample = (path, body) => measure(path, body)
const cls = (name, n) => `class ${name} {\n${'  void m() {}\n'.repeat(n)}}`
const head = '/** 一段文件头，行数算进总量但不含声明 */\n\n'

const SELF_TEST = [
  // --- file-lines ---
  {
    rule: 'file-lines',
    why: '表外的文件超过默认上限 → 拦',
    measured: [sample('app/lib/ui/x.dart', head + 'const a = 1;\n'.repeat(DEFAULT_FILE_LINES + 1))],
    shouldFail: true,
  },
  {
    rule: 'file-lines',
    why: '表外的文件正好等于默认上限 → 放（上限是闭区间）',
    measured: [sample('app/lib/ui/x.dart', 'const a = 1;\n'.repeat(DEFAULT_FILE_LINES))],
    shouldFail: false,
  },
  {
    rule: 'file-lines',
    why: '表内文件超过它自己的上限 → 拦（棘轮在这儿咬人）',
    measured: [sample('app/lib/ui/chat_page.dart', 'const a = 1;\n'.repeat(CHAT_PAGE_LINES + 1))],
    shouldFail: true,
  },
  {
    rule: 'file-lines',
    why: '表内文件正好等于上限 → 放',
    measured: [sample('app/lib/ui/chat_page.dart', 'const a = 1;\n'.repeat(CHAT_PAGE_LINES))],
    shouldFail: false,
  },
  // --- class-methods ---
  {
    rule: 'class-methods',
    why: '表外的类超过默认方法数 → 拦',
    measured: [sample('app/lib/data/x.dart', cls('Narrow', DEFAULT_CLASS_METHODS + 1))],
    shouldFail: true,
  },
  {
    rule: 'class-methods',
    why: '表外的类正好等于默认方法数 → 放',
    measured: [sample('app/lib/data/x.dart', cls('Narrow', DEFAULT_CLASS_METHODS))],
    shouldFail: false,
  },
  {
    rule: 'class-methods',
    why: '表内的类超过它自己的上限 → 拦',
    measured: [sample('app/lib/data/app_model.dart', cls('AppModel', APP_MODEL_METHODS + 2))],
    shouldFail: true,
  },
  {
    rule: 'class-methods',
    why: '表内的类正好等于上限 → 放',
    measured: [sample('app/lib/data/app_model.dart', cls('AppModel', APP_MODEL_METHODS))],
    shouldFail: false,
  },
  {
    rule: 'class-methods',
    why: '**表内类多一个方法就红**（方法数没有余量：余量就是暗门）',
    measured: [sample('app/lib/data/app_model.dart', cls('AppModel', APP_MODEL_METHODS + 1))],
    shouldFail: true,
  },
  {
    rule: 'class-methods',
    why: '**两空格的行注释里的 `void m() {}` 不算成员**（否则注释写得越多越红，惩罚写理由的人）',
    measured: [sample('app/lib/data/x.dart', `class Narrow {\n${'  // void m() {}\n'.repeat(60)}}`)],
    shouldFail: false,
  },
  {
    rule: 'class-methods',
    why: '**文档注释里的 `Future<void> m()` 也不算成员**',
    measured: [sample('app/lib/data/x.dart', `class Narrow {\n${'  /// Future<void> m()\n'.repeat(60)}}`)],
    shouldFail: false,
  },
  {
    rule: 'class-methods',
    why: '**4 空格缩进的是局部函数/闭包体，不算类成员**',
    measured: [sample('app/lib/data/x.dart', `class Narrow {\n  void m() {\n${'    void inner() {}\n'.repeat(60)}  }\n}`)],
    shouldFail: false,
  },
  {
    rule: 'class-methods',
    why: '多行签名的首行照样数得着（`Future<void> foo(` 折行不会漏）',
    measured: [sample('app/lib/data/x.dart', `class Wide {\n${'  Future<void> m(\n  ) async {}\n'.repeat(31)}}`)],
    shouldFail: true,
  },
  // --- budget-applies ---
  {
    rule: 'budget-applies',
    why: '一个文件都没有 = 表里每一条都扫不到 → 拦（否则整张表是假绿）',
    measured: [],
    shouldFail: true,
  },
  {
    rule: 'budget-applies',
    why: '文件名抄错（表里是 chat_page.dart，扫到的是 chat.dart）→ 拦',
    measured: [sample('app/lib/ui/chat.dart', 'const a = 1;\n')],
    shouldFail: true,
  },
  // --- budget-not-stale ---
  {
    rule: 'budget-not-stale',
    why: '文件瘦下来却没收紧上限 → 拦',
    measured: [sample('app/lib/ui/chat_page.dart', 'const a = 1;\n'.repeat(4000))],
    shouldFail: true,
  },
  {
    rule: 'budget-not-stale',
    why: '刚好落在余量内（5210 行 vs 上限 5250）→ 放',
    measured: [sample('app/lib/data/app_model.dart', 'const a = 1;\n'.repeat(5210))],
    shouldFail: false,
  },
  {
    rule: 'budget-not-stale',
    why: '类瘦下来却没收紧上限 → 拦',
    measured: [sample('app/lib/data/app_model.dart', cls('AppModel', 60))],
    shouldFail: true,
  },
  {
    rule: 'budget-not-stale',
    why: '类长了却没提数字 → 拦（两个方向都要有牙，否则只能挡一边）',
    measured: [sample('app/lib/data/app_model.dart', cls('AppModel', APP_MODEL_METHODS + 1))],
    shouldFail: true,
  },
]

// ---------------------------------------------------------------------------

function runRule(rule, measured) {
  try {
    return rule.run(measured)
  } catch (error) {
    return [`规则自身抛错：${error.message}`]
  }
}

// 1) 自检
const selfTestFailures = []
for (const testCase of SELF_TEST) {
  const rule = RULES.find((r) => r.id === testCase.rule)
  if (rule === undefined) {
    selfTestFailures.push(`自检样本指向不存在的规则 '${testCase.rule}'`)
    continue
  }
  const hit = runRule(rule, testCase.measured).length > 0
  if (hit !== testCase.shouldFail) {
    selfTestFailures.push(
      `${testCase.rule}：${testCase.why} —— 期望${testCase.shouldFail ? '拦' : '放'}，实际${hit ? '拦了' : '放了'}`,
    )
  }
}

// 2) 真实扫描
const measured = walk(ROOT).map((file) => {
  const relPath = relative('.', file).split('\\').join('/')
  return measure(relPath, readFileSync(file, 'utf8'))
})

const violations = RULES.flatMap((rule) =>
  runRule(rule, measured).map((line) => `[${rule.id}] ${line}`),
)

// 3) 扫到 0 个文件就红：没对象可扫的门禁是假绿（`budget-applies` 会逐条报，
//    但先在这里给一句更直接的话，免得读起来像“表抄错了”）。
const blind = measured.length === 0

const classCount = measured.reduce((n, file) => n + file.classes.length, 0)

if (selfTestFailures.length > 0) {
  console.log(`FAIL — 规则自检 ${selfTestFailures.length} 条不过（规则写错了，不是代码干净）`)
  for (const line of selfTestFailures) console.log('  ', line)
  process.exitCode = 1
} else if (blind) {
  console.log('FAIL — 一个 Dart 文件都没扫到（扫描面写错了，不是代码干净）')
  process.exitCode = 1
} else if (violations.length > 0) {
  console.log(`FAIL — 尺寸预算破了 ${violations.length} 处（规则：只降不升）`)
  for (const line of violations) console.log('  ', line)
  console.log('  取舍与维护方式见 .agents/notes/implemented/2026-11-10-size-budget-ratchet.md')
  process.exitCode = 1
} else {
  console.log(
    `PASS — 规则自检 ${SELF_TEST.length} 条 + 扫描 ${measured.length} 个 Dart 文件 / ${classCount} 个类`
      + ` + 预算 ${FILE_BUDGET.length} 个文件 / ${CLASS_BUDGET.length} 个类，全部有适用对象`,
  )
}
