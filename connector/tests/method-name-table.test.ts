/**
 * 方法名的两侧一致性：**实现了的方法必须写在契约 §5.7 里**，且契约定义的方法名数量与
 * `METHODS` 相等（见下面那条断言里的当前数字）。
 *
 * 为什么值得：
 * - 处理器表的键就是"手机看到的方法名"（`repo.info` 报的就是这张表的键）。**打错一个字母**
 *   不会报错，只会让那个方法在手机侧**不存在** —— 表现是"按钮点了没反应"。
 * - 那个数字被 `memory.md`、`tools.md` 与契约多处引用。把它变成断言，
 *   那些文字里的"X/N"就不会悄悄失真。
 *
 * 允许的差异是**有意的**：契约列全量，实现是子集 —— 所以下面还有一条**包含**关系断言，
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

test('实现的方法名都在契约 §5.7 里，且契约的方法名数量是 38（"X/38" 不会悄悄失真）', () => {
  // **38 是"方法名"数,不是表行数**:契约那张表一行可以写两个方法
  // （`job.follow` / `job.unfollow`、`settings.describe` / `settings.update`、
  // `credentials.set` / `credentials.unset`）—— 行数更少。
  //
  // **38 的来历**:2026-10-14 加 `endpoint.describe`(端点自报),
  // 2026-10-15 加 `session.projections`(一个方法打开全部只读面)、
  // `session.select-model`(切模型,**与 Web 同一个 DSH 方法**)与
  // `permission.catalog` / `permission.switch`(权限切换:读预设目录 + 写 `/permission <档位>`)。
  // 2026-10-15 晚加 `workspace.list`(会话列表按工作区分组)。
  // 2026-10-17 加 `agentPresets.list`(Agent 预设目录,只读)。
  // 2026-10-19 加 `usage.summary`(跨会话用量汇总,只读)。
  // 2026-10-21 加 `workspace.insertSessionBefore` / `workspace.pin` / `workspace.unpin`
  // (侧栏会话重排与置顶,三个都是 Web 已有的 Host 方法)。
  // 同日加 `subagent.prompt`(给可继续子会话投递人写的消息 —— 子会话不能用
  // `session.prompt`,宿主回 `is owned by subagent routing`)。
  // 2026-10-21 晚加 `workspace.insertBefore`(侧栏项目头拖动排序)。
  // 2026-10-23 加 `command.execute`(斜杠命令执行面:白名单只放 /goal 与 /plan)。
  // 每次变动都要同步 `memory.md` 里的"X/N"、`tools.md` 的方法数与契约那一行。
  const declared = new Set<string>()
  for (const line of section57(readFileSync(CONTRACT, 'utf8')).split('\n')) {
    if (!line.trimStart().startsWith('|')) continue
    // **只取第一列**（方法名列）。整节扫反引号会把 `caps.direct` 这类
    // 正文里的非方法名数进来。
    const firstCell = line.split('|')[1] ?? ''
    // `[\w-]` 必须含**连字符**：`session.select-model` 这种名字里就有。
    // 只写 `[\w.]` 时它会被截成 `session.select`（一个不存在的名字）——
    // 于是新方法静默漏检，而门禁看起来是通过的（2026-10-15 实测）。
    // 服务名那一段必须是 `[A-Za-z]` 而不是 `[a-z]`：`agentPresets.list` 里就有大写
    // —— 写成 `[a-z]+` 时**整条都匹配不上**，数字静默少 1（2026-10-17 实测：
    // 门禁报"契约定义了 30 个"而表里明明有 31 行方法名）。
    for (const match of firstCell.matchAll(/`([A-Za-z]+\.[a-z][\w-]*)`/g)) {
      const method = match[1]
      if (method !== undefined) declared.add(method)
    }
  }

  // 处理器表的键写法是 `'面.方法': async (params) => {`（单引号 + 点号，形状够独特）。
  const implemented = new Set<string>()
  // 同上：连字符与**服务名里的大写**都要进字符类，否则 `session.select-model` /
  // `agentPresets.list` 抽不出来 —— 而抽不出来的后果是"漏检"：一个拼错的方法名
  // 本该在这里被 `stray` 抓住，却因为压根没被抽到而看起来一切正常。
  for (const match of readFileSync(HANDLERS, 'utf8').matchAll(/^\s*'([A-Za-z]+\.[a-z][\w-]*)':\s/gm)) {
    const method = match[1]
    if (method !== undefined) implemented.add(method)
  }

  assert.equal(declared.size, 38, `契约 §5.7 定义了 38 个方法名，实际 ${declared.size} —— 改表就要同步引用它的文档`)
  assert.equal(implemented.size > 0, true, '没能从 handlers.ts 抽出任何方法名 —— 先修解析口径，别当成通过')

  const stray = [...implemented].filter((method) => !declared.has(method)).sort()
  assert.deepEqual(
    stray,
    [],
    '有实现了、但契约 §5.7 里没有的方法名（多半是键打错了）：手机侧会看到"这个方法不存在"',
  )
})
