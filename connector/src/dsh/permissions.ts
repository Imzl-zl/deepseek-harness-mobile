/**
 * 权限预设：读 `permissionPresets.catalog()`，写 `/permission <档位>`。
 *
 * ## 为什么是这一读一写，而不是别的门
 *
 * 手机上的"权限档"曾经是**三档手抄**（`dsh_composer.dart` 的 `AccessMode`
 * 三个枚举值 + 点完只改本地 `_accessMode`）—— 既与电脑侧无关，也不会真的切。
 * DSH 原生给了两扇门，形状就是选择器要的形状：
 *
 * 1. **读档位清单**：`@Remote('catalog')`
 *    （`packages/interaction/permission-presets/src/index.ts:292`），返回
 *    `PermissionCatalog = {options, defaultOptions, defaultPreset}`
 *    （`types.ts:26-33`）。**部署可配**：预设表来自 config
 *    （`packages/bundle/base/cordis.patch.yml:262-271` 配了 `read-only` /
 *    `workspace-write` / `danger-full-access` 三个），所以手抄一份名单
 *    就是第二份真值 —— 电脑上加一个预设，手机上永远看不到。
 * 2. **写当前会话档位**：`/permission <档位>` 这条斜杠命令。DSH 的注释原话是
 *    "the one write path a web client uses (the popup contribution submits the
 *    picked preset as this line)"（`permission-presets/src/index.ts:252-254`），
 *    注册处在 `:255-276`（`name: 'permission'`、`input: {hint: '<preset>'}`、
 *    handler 在 `:264-274`）。Web 侧就是这么调的：
 *    `live.command('/permission ' + preset)`
 *    （`packages/client/ui-permission-presets/src/client/index.ts:126`），
 *    而 `SessionFace.command` 落到
 *    `remote.commands.execute(sessionId, line, [])`
 *    （`packages/api/session-controller/src/client/sessions/session.ts:388`）。
 *
 * **当前值不在 catalog 里**：它在 `permissions` 投影的 `{currentValue}`
 * （注册在 `permission-presets/src/index.ts:237-244`，wire view 在 `:243`），
 * 手机经已有的 `session.projections` 拿 —— 所以本文件**不碰**它，
 * 同一个状态不会有第二个来源。
 *
 * ## 为什么不放一个通用的 `command.execute`
 *
 * 契约 §5.7 的方法名是**封闭集**，每个方法对应手机上一个人人看得见的动作。
 * 通用的命令执行面会让手机调到那些"移动端根本没有形态"的命令上
 * （`/compact`、`/export`、各插件自带的命令），而它们的 `CommandResult`
 * 只有 `{kind, text}`（`interaction/commands/src/types.ts:34-41`）——
 * 副作用在电脑侧发生，手机上既呈现不了也撤不回来。本期只接"权限切换"这一个面，
 * 将来每个面各带自己的方法名（与 `session.select-model` 同一个命名口径）。
 *
 * ## 命令注入这条边界
 *
 * `preset` 是手机给的字符串，被拼进一条命令行。已核实
 * `parseCommand`（`interaction/commands/src/index.ts:125-132`）只取
 * `^\/([a-z][a-z0-9_-]*)` 之后**全部**内容当 `rawInput`，所以换行不会变成
 * 第二条命令；而 `/permission` 的 handler 自己 `rawInput.trim()` 后与预设名
 * 精确比对（`:265-271`），不中就回 `{kind:'error'}`。即便如此，参数仍在
 * handler 侧按边界校验（见 `handlers.ts` 的 `permission.switch`）。
 *
 * 取舍（为何是两个方法而不是一个通用的 `command.execute`）见
 * `.agents/notes/implemented/2026-10-15-permission-switch-through-dsh-two-doors.md`。
 */
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'

import { ProtocolError } from '../protocol/errors.js'

/** `permissionPresets` 服务面（`super(ctx, 'permissionPresets')`，`:208`）。 */
interface PermissionPresetsService {
  catalog(): unknown
}

/**
 * `commands` 服务面（`@Remote` 的 `execute`，`interaction/commands/src/index.ts:360`；
 * 方法体 `:361`）。**按形状收窄、不 import DSH 类型** —— 与 `index.ts` 里
 * `ctx.get('commands')` 的 `register` 同一个口径（`dsh-commands` 不是本插件的依赖）。
 */
interface CommandsService {
  execute(
    agent: Agent,
    line: string,
    submittedAttachments: readonly unknown[],
    signal: AbortSignal,
  ): Promise<unknown>
}

/** `agents` 注册表（`packages/core/agent/src/index.ts` 的 `get`；口径同 `dsh/questions.ts`）。 */
interface AgentsRegistry {
  get(id: Agent['id']): Agent | undefined
}

export interface PermissionFaceDeps {
  /** 通道别名 → DSH 会话 id（契约 §5.1）。不认识的别名返回 `undefined`。 */
  sessionOf(sid: string): string | undefined
}

/**
 * 一次切换的结论。
 *
 * `matched` 是 Web 客户端自己推导的那个字段（`session.ts:390`：
 * `matched: result.value !== undefined`）—— `undefined` 的语义是
 * "语法或名字没解析出来"，也就是**这台电脑上没有 `/permission` 这个命令**。
 * 它与 `{kind:'error'}` 是两件事：后者是命令在、但预设名不对。
 */
export interface PermissionSwitchView {
  matched: boolean
  /** `matched` 为 true 时 DSH 的结算（`commandId` + `result`），**原样过线不挑字段**。 */
  execution?: unknown
}

export interface PermissionFace {
  /**
   * 全部可切预设（贡献顺序）。拿不到返回 `undefined`（调用方据此回 `{available:false}`）——
   * 与 `session.modelCatalog` 同一条纪律：空数组会被读成"没有可用预设"，
   * 而真实原因可能是这个部署没配预设表。
   */
  catalog(): Promise<unknown | undefined>
  /** 切这个会话的权限预设。 */
  switchTo(sid: string, preset: string): Promise<PermissionSwitchView>
}

/** `/permission` 命令的超时。契约 §10 的请求超时是 60 s，取同一个值。 */
const COMMAND_TIMEOUT_MS = 60_000

/**
 * 建权限面的 DSH 半边。
 *
 * 三个服务键全部走 `ctx.get`（缺了就是能力位为 false，不是抛异常 ——
 * 裸读在服务缺失时抛，见 `dsh/caps.ts` 的文件头）。**装配层按三者同时在场
 * 才挂这个方法**（`index.ts`），与 DSH 自己的规则一致：键缺席时客户端
 * **隐藏控件**（`permission-presets/src/types.ts:58-59`）。
 */
export function createPermissionFace(ctx: Context, deps: PermissionFaceDeps): PermissionFace {
  const presetsOf = (): PermissionPresetsService | undefined =>
    (ctx.get('permissionPresets') as PermissionPresetsService | undefined) ?? undefined
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
    async catalog() {
      const presets = presetsOf()
      if (presets === undefined) return undefined
      try {
        return await presets.catalog()
      } catch {
        // 目录是**展示用**的：读不到就让调用方回 `{available:false}`，
        // 手机说"拿不到目录"，而不是摆一个空列表（那会被读成"没有预设"）。
        return undefined
      }
    },

    async switchTo(sid, preset) {
      const commands = commandsOf()
      // 装配层已经按能力位挂过，走到这里只可能是装配写错了。
      if (commands === undefined) {
        throw new ProtocolError('internal', 'commands 服务不在：/permission 写路径不可用')
      }
      const agent = agentOf(sid)
      if (agent === undefined) {
        // DSH 的 Web 客户端在同一处抛 "this session is not materialized yet"
        // （`ui-permission-presets/src/client/index.ts:125`）：`/permission`
        // 需要一个**活的** agent（要 `agent.session` 落生命周期事件、
        // 要 agent 的 scope 合并命令层）。
        // 错误码用 `internal` 而不是 `session/not-found`：这个会话**存在**，
        // 而 `session/not-found` 的客户端动作是"从列表移除"（契约 §3.1）——
        // 那会让手机把一个好会话删掉。表是封闭的，不为它加一个新码。
        throw new ProtocolError(
          'internal',
          `这个会话在电脑上没有对应的活动 agent（${sid}）：/permission 需要一个已打开的会话`,
        )
      }
      const execution = await commands.execute(
        agent,
        `/permission ${preset}`,
        [],
        AbortSignal.timeout(COMMAND_TIMEOUT_MS),
      )
      return execution === undefined || execution === null
        ? { matched: false }
        : { matched: true, execution }
    },
  }
}
