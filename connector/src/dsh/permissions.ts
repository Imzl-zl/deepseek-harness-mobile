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
 * ## 与通用命令门（`command.execute`）的分工
 *
 * 手机上现在有两扇命令门，落到**同一段**执行逻辑（`dsh/command-line.ts`）：
 *
 * - `permission.switch`（本文件）：一个**具名动作**，手机上有落点（输入栏的权限 chip），
 *   参数是预设名而不是一条自由文本命令行。
 * - `command.execute`：白名单里的命令（`/goal`、`/plan`），准入判据见契约 §5.7 那一行。
 *
 * **`/permission` 不在那个白名单里**：同一个状态只许一个写入口，否则手机上会出现
 * "从 chip 切"与"从命令行切"两条路径，而它们的错误措辞、幂等键、失败呈现都得对齐两遍。
 * 反过来也成立 —— 这里不会因为白名单存在就改走通用门。
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
 * `.agents/notes/implemented/2026-10-15-permission-switch-through-dsh-two-doors.md`；
 * 2026-10-23 起通用门有了白名单，取舍见
 * `.agents/notes/implemented/2026-10-23-slash-command-execution-surface.md`。
 */
import type { Context } from '@deepseek-ai/cordis'

import { createCommandLineRunner, type CommandRunView } from './command-line.js'

/** `permissionPresets` 服务面（`super(ctx, 'permissionPresets')`，`:208`）。 */
interface PermissionPresetsService {
  catalog(): unknown
}

export interface PermissionFaceDeps {
  /** 通道别名 → DSH 会话 id（契约 §5.1）。不认识的别名返回 `undefined`。 */
  sessionOf(sid: string): string | undefined
}

/**
 * 一次切换的结论。
 *
 * **与 `command.execute` 是同一个形状**（`dsh/command-line.ts` 的 `CommandRunView`）：
 * 两者都是 `commands.execute` 的应答，`matched` 都来自同一条推导
 * （`session.ts:390`：`matched: result.value !== undefined`）。
 * `undefined` 的语义是"语法或名字没解析出来"，也就是**这台电脑上没有 `/permission`
 * 这个命令**；它与 `{kind:'error'}` 是两件事 —— 后者是命令在、但预设名不对。
 */
export type PermissionSwitchView = CommandRunView

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

/**
 * 建权限面的 DSH 半边。
 *
 * 三个服务键全部走 `ctx.get`（缺了就是能力位为 false，不是抛异常 ——
 * 裸读在服务缺失时抛，见 `dsh/caps.ts` 的文件头）。**装配层按三者同时在场
 * 才挂这个方法**（`index.ts`），与 DSH 自己的规则一致：键缺席时客户端
 * **隐藏控件**（`permission-presets/src/types.ts:58-59`）。
 *
 * `commands` 与 `agents` 这两个键的用法**不在这里**：它连同超时与
 * `undefined` 的语义一起在 `dsh/command-line.ts`，与 `command.execute` 共用。
 */
export function createPermissionFace(ctx: Context, deps: PermissionFaceDeps): PermissionFace {
  const presetsOf = (): PermissionPresetsService | undefined =>
    (ctx.get('permissionPresets') as PermissionPresetsService | undefined) ?? undefined
  const commandLine = createCommandLineRunner(ctx, deps)

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

    // 写路径：**同一条命令**（`/permission <preset>`）经共用那段跑，
    // 所以"没有活动 agent"与"超时"这两条失败语义与 `command.execute` 逐字一致。
    switchTo: (sid, preset) => commandLine.run(sid, `/permission ${preset}`),
  }
}
