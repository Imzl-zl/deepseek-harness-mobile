/**
 * 手机端多端边界校验（规则见 docs/subsystems/app-platform-boundaries.md §3）。
 *
 * 跑法：node app/tools/verify-platform-boundary.mjs
 *
 * 判据与取舍见 .agents/notes/proposed/2026-09-30-experience-first-three-layer-split.md
 *
 * 现在 app/lib 只有主题层，真实扫描几乎是空的——所以脚本自带**自检**：
 * 用合成样本证明每条规则真的会拦。自检不过 = 规则写错了，而不是代码干净。
 */
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { join, relative, sep } from 'node:path'

const ROOT = process.cwd()
const SCAN_DIRS = ['app/lib', 'app/packages']

/** 各端实现包的后缀；UI 不允许 import 它们。 */
const IMPL_SUFFIX = /import\s+['"][^'"]*_(ios|android|ohos)\//

/**
 * 纯 Dart 层禁用的库，**匹配 import / export 指令本身**，不匹配正文。
 *
 * 为什么不能直接 grep 正文：这几条规则的意图是"不许**引入**平台库"
 * （见每条规则的 `why`），而正文里出现 `dart:io` 的字样往往是**在说明这条规则**
 * —— 例如 `core/frame.dart` 的文件头写着「不许 import `dart:io`」。
 * 按正文匹配会把这种说明判成违规，等于**惩罚把规则写进代码**，
 * 而下一批 core/ 文件每一个都会想提这件事。所以这里只认真正的 import/export 行。
 *
 * 顺带天然放过注释：注释行以 `//` / `///` 开头，`^\s*` 之后接不上 `import`。
 */
const FORBIDDEN_IMPORT =
  /^[ \t]*(?:import|export)\s+['"](?:dart:io|package:flutter\/(?:services|widgets|material)\.dart)['"]/m

/**
 * `ui/` 禁用的库：**只有 `dart:io`**。
 *
 * 界面层当然要 `package:flutter/material.dart` —— 那是它的语言。
 * 它不该碰的是 `dart:io`：那意味着某个屏自己开了 socket 或读了文件，
 * 而这类事属于 `platform/` 或能力包。平台**分支**由 `branch-whitelist` 单独管。
 *
 * 两条曾经共用 `FORBIDDEN_IMPORT`，结果是**每个 UI 文件都误报**
 * "平台细节漏进了界面层" —— 而 Material 正是 UI 该用的东西。
 */
const UI_FORBIDDEN_IMPORT = /^[ \t]*(?:import|export)\s+['"]dart:io['"]/m

/** 取第一条匹配，用于报错信息里显示"命中了什么"。 */
function firstForbiddenImport(content) {
  const found = FORBIDDEN_IMPORT.exec(content)
  return found ? found[0].trim() : null
}

/** `ui/` 专用：只拦 `dart:io`（见 `UI_FORBIDDEN_IMPORT` 的说明）。 */
function firstUiForbiddenImport(content) {
  const found = UI_FORBIDDEN_IMPORT.exec(content)
  return found ? found[0].trim() : null
}

/**
 * 在**去掉了注释**的源码里找第一个匹配。
 *
 * 用于"某符号的**用法**"这类规则（如 `Icons.*`）。与"只认 import 指令"是同一个道理：
 * **说明为什么不用它**是好代码，而按正文 grep 会让规则惩罚把理由写下来的人。
 * 本项目在 `core-no-platform-import` 上踩过同一个坑（见那条规则的注释）。
 *
 * 去掉的是 `//…` 行注释与 `/*…*\/` 块注释。**不去字符串**：
 * 那需要真正的词法分析，而这里的规则只关心"有没有真的用这个符号" ——
 * 字符串里写 `Icons.send` 不是用法，但它极罕见，且真出现时多报一次比漏报安全。
 */
function firstCodeUse(content, pattern) {
  const withoutComments = content
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/\/\/[^\n]*/g, ' ')
  const found = pattern.exec(withoutComments)
  return found ? found[0].trim() : null
}

const RULES = [
  {
    id: 'core-no-platform-import',
    why: '纯 Dart 层出现平台 import，纯 Dart 单测立刻不可写',
    appliesTo: (p) => /^app\/lib\/(core|data|model)\//.test(p),
    match: (content) => firstForbiddenImport(content),
  },
  {
    id: 'ui-no-impl-import',
    why: 'UI 直接依赖某个端的实现包，等于把平台分支搬进界面层',
    appliesTo: (p) => /^app\/lib\/ui\//.test(p),
    match: (content) => firstMatch(content, IMPL_SUFFIX),
  },
  {
    id: 'ui-no-platform-import',
    why: 'UI 里出现 dart:io，说明某个屏自己开了 socket 或读了文件（该走 platform/ 或能力包）',
    appliesTo: (p) => /^app\/lib\/ui\//.test(p),
    match: (content) => firstUiForbiddenImport(content),
  },
  {
    id: 'branch-whitelist',
    why: '平台分支只允许出现在能力实现包、装配点与 ui/adaptive 层里',
    appliesTo: (p) => !/^app\/packages\//.test(p) && !/^app\/lib\/platform\//.test(p) && !/^app\/lib\/ui\/adaptive\//.test(p),
    match: (content) => firstMatch(content, /Platform\.|defaultTargetPlatform|MethodChannel|EventChannel/g),
  },
  {
    id: 'no-platform-isohos',
    why: 'CPF 官方 FAQ：Platform.isOhos 会导致 flutter run / build har / attach 失败，鸿蒙判断必须用 defaultTargetPlatform',
    appliesTo: () => true,
    match: (content) => firstMatch(content, /Platform\.isOhos/g),
  },
  {
    id: 'no-material-icons',
    why: '图标只有一个来源（DSH 的 98 个图标，见 lib/theme/dsh_icons.dart）。'
      + '用 Icons.* 等于从 Material 借图标，而原型与 App 会长得不一样 —— '
      + '项目硬规则是「改基线要同步改落地端，不允许两边各自漂移」。',
    appliesTo: (p) => /^app\/lib\/ui\//.test(p),
    match: (content) => firstCodeUse(content, /(?<![\w.])Icons\.[A-Za-z_]\w*/g),
  },
  {
    id: 'fallback-not-in-release',
    why: '兜底实现混进 release 装配点（必须由 kDebugMode 守住），禁止静默降级',
    appliesTo: (p) => p === 'app/lib/platform/registry.dart',
    match: (content) => (/InMemory|NullPush|Noop/.test(content) && !/kDebugMode/.test(content)
      ? '装配点引用了兜底实现但没有 kDebugMode 守卫'
      : null),
  },
]

/** 自检样本：每条规则都要能拦住一个反例、放过一个正例。 */
const SELF_TEST = [
  { rule: 'core-no-platform-import', path: 'app/lib/core/transport.dart', content: "import 'dart:io';", shouldFail: true },
  { rule: 'core-no-platform-import', path: 'app/lib/core/transport.dart', content: "import 'package:flutter/foundation.dart';", shouldFail: false },
  // **说明这条规则的注释不算违规**：正则只认 import/export 指令本身。
  // 少了这两条样本，规则会退化成"按正文 grep"，而那样会惩罚把规则写进代码
  // （真实踩到：core/frame.dart 的文件头写了「不许 import `dart:io`」就被判违规）。
  {
    rule: 'core-no-platform-import',
    path: 'app/lib/core/transport.dart',
    content: '/// 本文件是纯 Dart：不许 import `dart:io` 或 `package:flutter/material.dart`。\nimport \'dart:convert\';',
    shouldFail: false,
  },
  {
    rule: 'core-no-platform-import',
    path: 'app/lib/core/transport.dart',
    content: '// 见 docs：core 层禁 dart:io\nimport \'dart:typed_data\';',
    shouldFail: false,
  },
  // 但**真的 import** 必须拦住，哪怕前面有注释。
  {
    rule: 'core-no-platform-import',
    path: 'app/lib/core/transport.dart',
    content: '/// 说明\nimport \'dart:io\';\n',
    shouldFail: true,
  },
  { rule: 'ui-no-impl-import', path: 'app/lib/ui/chat.dart', content: "import '../../packages/secure_store_ohos/secure_store_ohos.dart';", shouldFail: true },
  { rule: 'ui-no-impl-import', path: 'app/lib/ui/chat.dart', content: "import '../../packages/secure_store/secure_store.dart';", shouldFail: false },
  { rule: 'ui-no-platform-import', path: 'app/lib/ui/chat.dart', content: "import 'dart:io';", shouldFail: true },
  // **界面层必须能 import Material** —— 那是它写 UI 的语言。
  // 缺这条自检时，`ui/` 的规则误用了 core 的禁用表（那张表含 material.dart），
  // 结果是每个 UI 文件都报"平台细节漏进了界面层"（实测踩到，见 `.agents/notes/`）。
  { rule: 'ui-no-platform-import', path: 'app/lib/ui/chat.dart', content: "import 'package:flutter/material.dart';", shouldFail: false },
  { rule: 'ui-no-platform-import', path: 'app/lib/ui/chat.dart', content: "import 'package:flutter/widgets.dart';", shouldFail: false },
  // 图标只有一个来源：`Icons.*` 是 Material 的图标，UI 层不许用。
  { rule: 'no-material-icons', path: 'app/lib/ui/chat.dart', content: 'icon: const Icon(Icons.send),', shouldFail: true },
  { rule: 'no-material-icons', path: 'app/lib/ui/chat.dart', content: "DshIcon('send', color: DshColors.onAccent)", shouldFail: false },
  // **注释里提到 `Icons.*` 不算违规**：说明"为什么不用它"是好事，
  // 按正文 grep 会让规则惩罚把理由写下来的人（`core-no-platform-import` 踩过同一个坑）。
  { rule: 'no-material-icons', path: 'app/lib/ui/chat.dart', content: '// 不用 Icons.send，图标只有一个来源', shouldFail: false },
  // 但别的层可以用（`platform/` 将来可能有自己的原生图标需求）——
  // 这条规则的适用范围就是 UI 层，不该外溢。
  { rule: 'no-material-icons', path: 'app/lib/platform/registry.dart', content: 'const Icon(Icons.send)', shouldFail: false },
  { rule: 'branch-whitelist', path: 'app/lib/ui/chat.dart', content: 'if (Platform.isAndroid) {}', shouldFail: true },
  { rule: 'branch-whitelist', path: 'app/lib/ui/adaptive/switcher.dart', content: 'if (Platform.isIOS) {}', shouldFail: false },
  { rule: 'no-platform-isohos', path: 'app/packages/notify_ohos/lib/notify_ohos.dart', content: 'if (Platform.isOhos) {}', shouldFail: true },
  { rule: 'no-platform-isohos', path: 'app/packages/notify_ohos/lib/notify_ohos.dart', content: 'if (defaultTargetPlatform == TargetPlatform.ohos) {}', shouldFail: false },
  { rule: 'branch-whitelist', path: 'app/packages/push_android/lib/push_android.dart', content: 'if (Platform.isAndroid) {}', shouldFail: false },
  { rule: 'branch-whitelist', path: 'app/lib/platform/registry.dart', content: 'if (Platform.isAndroid) {}', shouldFail: false },
  {
    rule: 'fallback-not-in-release',
    path: 'app/lib/platform/registry.dart',
    content: 'final store = InMemorySecureStore();',
    shouldFail: true,
  },
  {
    rule: 'fallback-not-in-release',
    path: 'app/lib/platform/registry.dart',
    content: 'final store = kDebugMode ? InMemorySecureStore() : fail();',
    shouldFail: false,
  },
]

function firstMatch(content, pattern) {
  pattern.lastIndex = 0
  const found = pattern.exec(content)
  return found ? found[0] : null
}

function normalize(path) {
  return path.split(sep).join('/')
}

function walk(dir, out = []) {
  if (!existsSync(dir)) return out
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) walk(full, out)
    else if (entry.endsWith('.dart')) out.push(normalize(relative(ROOT, full)))
  }
  return out
}

const failures = []
let checks = 0

// ---- 自检：先证明规则本身有效 ----
for (const sample of SELF_TEST) {
  checks += 1
  const rule = RULES.find((r) => r.id === sample.rule)
  if (!rule) {
    failures.push(`自检: 规则 ${sample.rule} 不存在`)
    continue
  }
  const fires = rule.appliesTo(sample.path) && Boolean(rule.match(sample.content))
  if (fires !== sample.shouldFail) {
    failures.push(`自检: ${sample.rule} 对样本应${sample.shouldFail ? '拦下' : '放过'}却相反 → ${sample.content}`)
  }
}

// ---- 真实扫描 ----
const files = SCAN_DIRS.flatMap((dir) => walk(join(ROOT, dir)))
for (const file of files) {
  const content = readFileSync(join(ROOT, file), 'utf8')
  for (const rule of RULES) {
    if (!rule.appliesTo(file)) continue
    const hit = rule.match(content)
    checks += 1
    if (hit) failures.push(`${rule.id}: ${file} → 命中「${hit}」（${rule.why}）`)
  }
}

if (failures.length > 0) {
  console.error(`FAIL ${failures.length}/${checks} 项不通过（扫描 ${files.length} 个 Dart 文件）\n`)
  for (const line of failures) console.error(`  - ${line}`)
  process.exit(1)
}

console.log(`ALL CHECKS PASSED — ${checks} 项（规则自检 ${SELF_TEST.length} 条 + 扫描 ${files.length} 个 Dart 文件）`)
