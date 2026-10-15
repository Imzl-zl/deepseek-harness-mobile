/**
 * 方法名的两侧一致性：**实现了的方法必须写在契约 §5.7 里**，且契约定义了恰好 26 个方法名。
 *
 * 为什么值得：
 * - 处理器表的键就是"手机看到的方法名"（`repo.info` 报的就是这张表的键）。**打错一个字母**
 *   不会报错，只会让那个方法在手机侧**不存在** —— 表现是"按钮点了没反应"。
 * - "26" 这个数字被 `memory.md`、cookbook 与契约多处引用（当前 17/26）。把它变成断言，
 *   那些文字里的"X/26"就不会悄悄失真。
 *
 * 允许的差异是**有意的**：契约列全量（26），实现是子集（当前 17）——所以断言是**包含**关系，
 *   不是相等：`connector/unsupported` 正是为"契约有、实现没有"准备的回执。
 *
 * **口径只取表格第一列**：早先按"整节里所有反引号的 `x.y`"数，于是 `caps.direct`
 * 这类写在正文里的非方法名也被数进去 —— 表现是"加了 1 个方法，数却涨了 2"，
 * 而门禁指向的是文档而不是真正的原因。方法名只出现在方法表的第一列。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

const CONTRACT = new URL('../../docs/subsystems/remote-channel.md', import.meta.url)
const HANDLERS = new URL('../src/handlers.ts', import.meta.url)

/** 取出 §5.7 这一节的正文（到下一个二级/三级标题为止）。 */
function section57(markdown: string): string {
  const start = markdown.indexOf('### 5.7')
  assert.equal(start >= 0, true, '契约里找不到 §5.7 —— 标题改了就要同步这条门禁')
  const rest = markdown.slice(start)
  const next = rest.slice(3).search(/\n#{2,3} /)
  return next === -1 ? rest : rest.slice(0, next + 3)
}

test('实现的方法名都在契约 §5.7 里，且契约定义了恰好 26 个方法（"X/26" 不会悄悄失真）', () => {
  // **26 是"方法名"数,不是表行数**:契约那张表一行可以写两个方法
  // （`job.follow` / `job.unfollow`、`settings.describe` / `settings.update`、
  // `credentials.set` / `credentials.unset`）—— 行数更少。
  //
  // **26 的来历**:2026-10-14 加 `endpoint.describe`(端点自报),
  // 2026-10-15 加 `session.projections`(一个方法打开全部只读面)、
  // `session.select-model`(切模型,**与 Web 同一个 DSH 方法**)与
  // `permission.catalog` / `permission.switch`(权限切换:读预设目录 + 写 `/permission <档位>`)。
  // 每次变动都要同步 `memory.md` 里的"X/26"、`tools.md` 的方法数与契约那一行。
  const declared = new Set<string>()
  for (const line of section57(readFileSync(CONTRACT, 'utf8')).split('\n')) {
    if (!line.trimStart().startsWith('|')) continue
    // **只取第一列**（方法名列）。整节扫反引号会把 `caps.direct` 这类
    // 正文里的非方法名数进来。
    const firstCell = line.split('|')[1] ?? ''
    // `[\w-]` 必须含**连字符**：`session.select-model` 这种名字里就有。
    // 只写 `[\w.]` 时它会被截成 `session.select`（一个不存在的名字）——
    // 于是新方法静默漏检，而门禁看起来是通过的（2026-10-15 实测）。
    for (const match of firstCell.matchAll(/`([a-z]+\.[a-z][\w-]*)`/g)) {
      const method = match[1]
      if (method !== undefined) declared.add(method)
    }
  }

  // 处理器表的键写法是 `'面.方法': async (params) => {`（单引号 + 点号，形状够独特）。
  const implemented = new Set<string>()
  // 同上：连字符要进字符类，否则 `session.select-model` 抽不出来。
  for (const match of readFileSync(HANDLERS, 'utf8').matchAll(/^\s*'([a-z]+\.[a-z][\w-]*)':\s/gm)) {
    const method = match[1]
    if (method !== undefined) implemented.add(method)
  }

  assert.equal(declared.size, 26, `契约 §5.7 定义了 26 个方法名，实际 ${declared.size} —— 改表就要同步引用它的文档`)
  assert.equal(implemented.size > 0, true, '没能从 handlers.ts 抽出任何方法名 —— 先修解析口径，别当成通过')

  const stray = [...implemented].filter((method) => !declared.has(method)).sort()
  assert.deepEqual(
    stray,
    [],
    '有实现了、但契约 §5.7 里没有的方法名（多半是键打错了）：手机侧会看到"这个方法不存在"',
  )
})
