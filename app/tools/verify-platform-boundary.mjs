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

const RULES = [
  {
    id: 'core-no-platform-import',
    why: '纯 Dart 层出现平台 import，纯 Dart 单测立刻不可写',
    appliesTo: (p) => /^app\/lib\/(core|data|model)\//.test(p),
    match: (content) => firstMatch(content, /dart:io|package:flutter\/(services|widgets|material)\.dart/g),
  },
  {
    id: 'ui-no-impl-import',
    why: 'UI 直接依赖某个端的实现包，等于把平台分支搬进界面层',
    appliesTo: (p) => /^app\/lib\/ui\//.test(p),
    match: (content) => firstMatch(content, IMPL_SUFFIX),
  },
  {
    id: 'ui-no-platform-import',
    why: 'UI 里出现 dart:io，说明平台细节漏进了界面层',
    appliesTo: (p) => /^app\/lib\/ui\//.test(p),
    match: (content) => firstMatch(content, /dart:io/g),
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
  { rule: 'ui-no-impl-import', path: 'app/lib/ui/chat.dart', content: "import '../../packages/secure_store_ohos/secure_store_ohos.dart';", shouldFail: true },
  { rule: 'ui-no-impl-import', path: 'app/lib/ui/chat.dart', content: "import '../../packages/secure_store/secure_store.dart';", shouldFail: false },
  { rule: 'ui-no-platform-import', path: 'app/lib/ui/chat.dart', content: "import 'dart:io';", shouldFail: true },
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
