/**
 * 跑一条 DSH 斜杠命令 —— 手机侧两个命令门共用的那一段。
 *
 * ## 为什么是一个文件，而不是各写一遍
 *
 * `permission.switch`（窄口）与 `command.execute`（白名单口）落到**同一个** DSH 方法：
 * `@Remote` 的 `execute`（`packages/interaction/commands/src/index.ts:360`，方法体 `:361`）。
 * 三件容易被各抄一遍、然后各漂一半的事只在这里：
 *
 * 1. **别名 → 活的 root agent**：`commands.execute` 的第一个参数是 `Agent`
 *    （`index.ts:361-366`），要 `agent.session` 落生命周期事件、要 agent 的 scope
 *    合并命令层。手机只有 `sid`（契约 §5.1），所以这一步在连接器里做，手机不传 agent id。
 * 2. **请求超时**：契约 §10 的 60 s。取消信号**不进 args**（Typert 在业务参数之后注入，
 *    `tools.md` 的铁律②），它是 `execute` 的**第四个**参数。
 * 3. **`undefined` 的语义**：见下。
 *
 * ## `undefined` 是什么意思
 *
 * `execute` 在**语法或名字没解析出来**时回 `undefined`（`index.ts:367-370`），而且
 * **不落任何日志**（`command/run` 只在进了 handler 之后才追加，`:373-378`）——
 * 所以"没匹配上"与"跑了但结果不好"在电脑侧是两件事，这里也必须分成两件事。
 * Web 客户端自己推导这个字段：`matched: result.value !== undefined`
 * （`packages/api/session-controller/src/client/sessions/session.ts:390`）。原样复述，
 * 不发明第二个含义。
 *
 * ## 附件固定为空数组
 *
 * `submittedAttachments` 是 `readonly CommandSubmitAttachment[]`
 * （`interaction/commands/src/types.ts:14-17`）。手机的附件面（上传文件）还没接，
 * 所以这里**恒传 `[]`** —— 与 Web 的 `/permission` 调用同一个形状（`session.ts:388`）。
 * 别把它换成"手机发什么就传什么"：附件的准入（`definition.input.attachments`）与
 * 落盘都在 DSH 侧（`index.ts:389-409`），我们还没做那半边。
 *
 * ## 会话没有活动 agent 时为什么是 `internal`
 *
 * `/permission` 与命令都需要一个**活的** agent。DSH 的 Web 客户端在同一处抛
 * "this session is not materialized yet"（`ui-permission-presets/src/client/index.ts:125`）。
 * 这里用 `internal` 而不是 `session/not-found`：这个会话**存在**，而
 * `session/not-found` 的客户端动作是"从列表移除"（契约 §3.1）—— 那会让手机把
 * 一个好会话删掉。错误码表是封闭的，不为它加新码。
 *
 * 取舍（为什么两个门共用一段、白名单在哪、为什么不推翻 §5.7）见
 * `.agents/notes/implemented/2026-10-23-slash-command-execution-surface.md`。
 */
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'

import { ProtocolError } from '../protocol/errors.js'

/** `commands` 服务面（`@Remote` 的 `execute`）。**按形状收窄、不 import DSH 类型**。 */
interface CommandsService {
  execute(
    agent: Agent,
    line: string,
    submittedAttachments: readonly unknown[],
    signal: AbortSignal,
  ): Promise<unknown>
}

/** `agents` 注册表（`packages/core/agent/src/index.ts` 的 `get`）。 */
interface AgentsRegistry {
  get(id: Agent['id']): Agent | undefined
}

export interface CommandLineDeps {
  /** 通道别名 → DSH 会话 id（契约 §5.1）。不认识的别名返回 `undefined`。 */
  sessionOf(sid: string): string | undefined
}

/**
 * 一次命令执行的结论。
 *
 * `matched` 是 Web 客户端自己推导的那个字段（`session.ts:390`）；`execution` 是
 * DSH 的 `{commandId, result}`（`types.ts:49-54`）**原样过线不挑字段** ——
 * `result` 只有 `{kind, text?}` / `{kind:'error', text}` 两档（`types.ts:34-41`）。
 */
export interface CommandRunView {
  matched: boolean
  /** `matched` 为 true 时 DSH 的结算。 */
  execution?: unknown
}

export interface CommandLineRunner {
  /** 在这个会话上跑一条命令行。别名未知 = 调用方的缺陷（handler 已经查过一次）。 */
  run(sid: string, line: string): Promise<CommandRunView>
}

/** 单条命令的超时。契约 §10 的请求超时是 60 s，取同一个值。 */
const COMMAND_TIMEOUT_MS = 60_000

/**
 * 命令行里的命令名。
 *
 * **语法与 DSH 逐字一致**：`/^\/([a-z][a-z0-9_-]*)(?=$|[\t\n\r ])/u`
 * （`packages/interaction/commands/src/index.ts:126` 的 `parseCommand`）。
 * 抄它是因为白名单要在**发给宿主之前**判名字，而"这行算不算命令"的唯一判据
 * 就是这条正则 —— 自己写一个更宽松的（比如 `startsWith('/')` 再切空白）会把
 * `/goal:` 这类行误判成命令，然后在白名单那里拒掉一条宿主本来也会回 `undefined` 的行。
 *
 * 解析不出 = **这条行不是命令**，不是错误：调用方把原行交给宿主，宿主回 `undefined`。
 */
export function commandNameOf(line: string): string | undefined {
  const match = /^\/([a-z][a-z0-9_-]*)(?=$|[\t\n\r ])/u.exec(line)
  return match?.[1]
}

/**
 * 建这段共用逻辑。
 *
 * 两个服务键都走 `ctx.get`，**缺席的判定放在 `run` 里而不是构造时**：
 * 装配层按"两个键同时在场"决定挂不挂方法（`index.ts`），所以走到 `run` 时
 * 缺键只可能是装配写错了 —— 那时如实抛，而不是静默换一条路径。
 */
export function createCommandLineRunner(ctx: Context, deps: CommandLineDeps): CommandLineRunner {
  const commandsOf = (): CommandsService | undefined =>
    (ctx.get('commands') as CommandsService | undefined) ?? undefined
  const agentsOf = (): AgentsRegistry | undefined =>
    (ctx.get('agents') as AgentsRegistry | undefined) ?? undefined

  /** 别名 → live root agent。口径与 `dsh/questions.ts` 的 `agentOf` 一致。 */
  const agentOf = (sid: string): Agent | undefined => {
    const dshSessionId = deps.sessionOf(sid)
    if (dshSessionId === undefined) return undefined
    return agentsOf()?.get(dshSessionId as Agent['id'])
  }

  return {
    async run(sid, line) {
      const commands = commandsOf()
      if (commands === undefined) {
        throw new ProtocolError('internal', 'commands 服务不在：斜杠命令的写路径不可用')
      }
      const agent = agentOf(sid)
      if (agent === undefined) {
        throw new ProtocolError(
          'internal',
          `这个会话在电脑上没有对应的活动 agent（${sid}）：斜杠命令需要一个已打开的会话`,
        )
      }
      const execution = await commands.execute(
        agent,
        line,
        [],
        AbortSignal.timeout(COMMAND_TIMEOUT_MS),
      )
      // `undefined` = 语法或名字没解析出来（`index.ts:367-370`）。`null` 也收：
      // 线上是 JSON，将来真有人写了个 `return null` 也不该变成"跑了"。
      return execution === undefined || execution === null
        ? { matched: false }
        : { matched: true, execution }
    },
  }
}
