/**
 * 手机的设置面（`settings.describe` / `settings.update`）—— 契约 §5.7。
 *
 * ## 为什么还需要这一层（`dsh/settings.ts` 的端口已经够安全了）
 *
 * 端口保证的是"**读已脱敏、写只发新值**"。但"能读整棵设置树"与"能写任意 ns 的任意
 * 字段"仍然是两台太大的门：
 *
 * 1. **读**：`snapshot(ns)` 会给你那个 ns 的全部字段。手机这一版只为**三行设置**而来
 *    （默认权限档 / 默认 Agent 预设 / Session Log 开关），把其余 ns 也摆出去只是把
 *    配置拓扑送给手机界面，没有任何一行会用到。
 * 2. **写**：`setField` 走的是 `mutate`（`packages/settings/settings/src/index.ts:81-83`），
 *    而 `mutate` **能写密钥字段**（`dsh/settings.ts:9-21` 的第二条就是在说这件事）。
 *    `settings.update` 不是密钥的通道（密钥走 `credentials.set`），所以写面按
 *    **(ns, path)** 三元组逐条放行，而不是"ns 可写"。
 *
 * 越界一律 `gateway/bad-request`（"我们发的参数宿主不认" = 我们的缺陷）；
 * 乐观锁过期转成 `settings/conflict`（
 * `packages/settings/settings/src/index.ts:45-64` 的 `SETTINGS_CONFLICT`）。
 *
 * 取舍见 `.agents/notes/implemented/2026-10-22-settings-handlers-and-default-mode.md`。
 */
import type { SettingsSnapshot, SettingsPort } from './settings.js'

/** 手机能读的命名空间（就这三行设置所在的三个 ns）。 */
export const READABLE_NAMESPACES: readonly string[] = [
  'permission',
  'agent-preset-registry',
  'session-log-deepseek',
]

/** 手机能写的字段：**(ns, path)** 逐条列出，不按 ns 放行。 */
export const WRITABLE_FIELDS: readonly { ns: string; path: readonly string[] }[] = [
  // 新会话默认权限档（`packages/client/ui-permission-presets/src/client/settings-store.ts:19,124-128`）。
  { ns: 'permission', path: ['defaultPreset'] },
  // 新任务默认 Agent 预设（`packages/client/ui-agent-preset/src/client/settings-store.ts:17,30-37`）。
  { ns: 'agent-preset-registry', path: ['selectedDefault'] },
  // 上传 Session Log 的开关（`packages/client/ui-settings-session-log/src/client/index.ts:27,29`）。
  { ns: 'session-log-deepseek', path: ['enabled'] },
]

/** 一个可写的设置字段（手机侧三行设置各对应一条）。 */
export interface SettingsUpdate {
  ns: string
  path: readonly string[]
  value: unknown
  /** 乐观锁：上一次 describe 拿到的 revision。缺省 = 不校验。 */
  expectedRevision?: unknown
}

export interface SettingsFace {
  /** 读若干命名空间（不在 [READABLE_NAMESPACES] 里的**静默跳过**：手机问多了不该报错）。 */
  describe(namespaces: readonly string[]): readonly SettingsSnapshot[]
  /** 改一个字段；返回**改完之后**的快照（手机据此刷新那一行）。 */
  update(input: SettingsUpdate): Promise<SettingsSnapshot | undefined>
}

/** 参数越界。调用方（handlers）会把它翻译成 `gateway/bad-request`。 */
export class SettingsScopeError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SettingsScopeError'
  }
}

/** 乐观锁过期（宿主抛 `SETTINGS_CONFLICT`，`settings/src/index.ts:45-64`）。 */
export class SettingsConflictError extends Error {
  constructor(message = '设置已被改动，请重新读取后再改') {
    super(message)
    this.name = 'SettingsConflictError'
  }
}

function samePath(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((segment, index) => segment === b[index])
}

/** 宿主的冲突错误是"普通 Error + code 字段"（不是 subclass），所以按 code 认。 */
function isConflict(error: unknown): boolean {
  return (
    typeof error === 'object' &&
    error !== null &&
    (error as { code?: unknown }).code === 'SETTINGS_CONFLICT'
  )
}

export function createSettingsFace(port: SettingsPort): SettingsFace {
  return {
    describe(namespaces) {
      const out: SettingsSnapshot[] = []
      for (const ns of namespaces) {
        if (!READABLE_NAMESPACES.includes(ns)) continue
        const snapshot = port.snapshot(ns)
        if (snapshot !== undefined) out.push(snapshot)
      }
      return out
    },

    async update(input) {
      const allowed = WRITABLE_FIELDS.some(
        (field) => field.ns === input.ns && samePath(field.path, input.path),
      )
      if (!allowed) {
        throw new SettingsScopeError(
          `settings.update 只能改这三处：${WRITABLE_FIELDS.map((f) => `${f.ns}.${f.path.join('.')}`).join('、')}`,
        )
      }
      try {
        await port.setField(input.ns, input.path, input.value, input.expectedRevision)
      } catch (error) {
        if (isConflict(error)) throw new SettingsConflictError()
        throw error
      }
      // **改完再读一次**：手机拿到的是新 revision 与新值，不必自己猜。
      return port.snapshot(input.ns)
    },
  }
}
