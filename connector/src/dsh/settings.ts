/**
 * 设置与凭据适配（契约 §7.5）。
 *
 * 两条硬规则：**密钥值不回传手机**、**改密钥只发新值**。
 *
 * 本文件的设计目标是让**安全路径成为唯一路径** —— 端口上不存在「要不过滤的读」这种方法，
 * 调用方无从选错。这不是风格问题，是三个默认行为都站在危险一侧：
 *
 * 1. **裸 `settings.describe()` 会把 `role('secret')` 字段的明文放进 `value` / `base` / `user`**
 *    （`packages/settings/settings/src/index.ts:327-330` 的三元；测试级证据
 *    `tests/configuration.spec.ts:254-255`：裸调拿到明文，传 `{ redactSecrets: true }` 后
 *    JSON 里不含）。忘记传参**没有任何警告**。
 * 2. **`settings.replace(ns, 从 redacted 文档重建的 section)` 会静默删掉**客户端从没收到过的
 *    每一个密钥（`settings/src/index.ts:73-80` 明写这一点）。所以改密钥只能走 `mutate`。
 * 3. **DSH 没有「凭据只写不读」模式**：`credentials.resolve` / `readRecord` / `modifyRecord`
 *    全部返回明文（`packages/credentials/credentials/src/index.ts:183` / `:217` / `:247`），
 *    `modifyRecord` 的回调直接拿到当前记录。单向性只存在于 Remote 那一层
 *    （`packages/api/settings-controller/src/credentials.ts:64-65`）。
 *    ⇒ 本插件有完整读权，**「只写面」必须由本层保证**：绝不把
 *    `resolve` / `readRecord` / `modifyRecord` 放进任何能到手机的调用路径。
 *
 * 取舍见 `.agents/notes/implemented/2026-10-01-connector-settings-adapter.md`
 */
import type { CredentialProvider, CredentialRef } from '@deepseek-ai/dsh-credentials'
import type { SettingsForms, SettingsDescriptor } from '@deepseek-ai/dsh-settings'

/** 一个密钥位：只有位置与「设没设」，**值本身永不过线**。 */
export interface SecretSlot {
  /** 相对 section 根的路径；含具体 dict key 与数组下标（`redact.ts:27-32`）。 */
  path: readonly string[]
  /** 是否已设值。仅此一个布尔，不含值。 */
  set: boolean
}

export interface SettingsSnapshot {
  ns: string
  /** 乐观并发用的版本号；写回时当作 `expectedRevision`。 */
  revision: unknown
  /** 已剔除 `role('secret')` 字段的设置值。 */
  values: unknown
  /** 密钥位清单。 */
  secrets: readonly SecretSlot[]
}

export interface SecretStatus {
  configured: boolean
  /** 是否可写；只读来源遮蔽时为 false（`credentials-local/src/index.ts:780-784`）。 */
  writable: boolean
}

export interface SettingsPort {
  /** 读一个命名空间的设置快照。**唯一的安全读路径**。 */
  snapshot(ns: string): SettingsSnapshot | undefined
  /**
   * 只发新值地改一个字段。
   *
   * 用 `mutate` 而不是 `replace` —— 后者拿 redacted 文档重建会静默删密钥。
   */
  setField(
    ns: string,
    path: readonly string[],
    value: unknown,
    expectedRevision?: unknown,
  ): Promise<void>
  /**
   * 一次写多个字段。
   *
   * **为什么不是循环调 `setField`**：`mutate` 每次写入都会让 revision +1
   * （`packages/settings/settings/src/index.ts:315-317` 的 revision 递推），
   * 而乐观锁比的是本轮读到的那个值 —— 第二次调用拿旧 revision 必抛
   * `SETTINGS_CONFLICT`。面板一次保存改三个字段，必须是**一次写入**。
   *
   * 用 `update`（合并）而不是 `replace`（重建）：后者会拿脱敏文档覆盖
   * 密钥字段，正是本文件首要要防的那件事。
   */
  setFields(
    ns: string,
    patch: Readonly<Record<string, unknown>>,
    expectedRevision?: unknown,
  ): Promise<void>
  /** 写一个凭据。明文只进不出。 */
  setSecret(ref: CredentialRef, value: string): Promise<void>
  unsetSecret(ref: CredentialRef): Promise<void>
  /** 只回答「配没配 + 能不能写」；对应 `CredentialInfo`，视图里没有能装值的槽。 */
  secretStatus(ref: CredentialRef): Promise<SecretStatus>
}

/** 依赖缺失时的显式失败。绝不静默降级成「什么都不做」。 */
class ServiceUnavailableError extends Error {
  constructor(service: string) {
    super(`${service} 服务不可用：能力位应已把它标为 false，调用方不该走到这里`)
    this.name = 'ServiceUnavailableError'
  }
}

/** 从 descriptor 抽出密钥位。`secrets` 只在传了 `redactSecrets` 时才挂上（`index.ts:327-330`）。 */
function secretSlotsOf(descriptor: SettingsDescriptor): readonly SecretSlot[] {
  const secrets = descriptor.secrets ?? []
  return secrets.map((slot) => ({ path: slot.path, set: slot.set }))
}

export interface SettingsServices {
  settings: SettingsForms | undefined
  credentials: CredentialProvider | undefined
}

export function createSettingsPort(services: SettingsServices): SettingsPort {
  const { settings, credentials } = services

  const requireSettings = (): SettingsForms => {
    if (settings === undefined) throw new ServiceUnavailableError('settings')
    return settings
  }
  const requireCredentials = (): CredentialProvider => {
    if (credentials === undefined) throw new ServiceUnavailableError('credentials')
    return credentials
  }

  return {
    snapshot(ns) {
      // `redactSecrets: true` **必须**传：这是本文件存在的首要理由。
      const found = requireSettings()
        .describe({ redactSecrets: true })
        .find((row) => row.ns === ns)
      if (found === undefined) return undefined
      return {
        ns: found.ns,
        revision: found.revision,
        // `value` 已被 redact（`index.ts:327-330`）；密钥位另走 secrets。
        values: found.value,
        secrets: secretSlotsOf(found),
      }
    },

    async setField(ns, path, value, expectedRevision) {
      // `mutate(ns, ops, expectedRevision?)`：`SettingsPathOp = {op:'set',path,value} | {op:'unset',path}`
      // （`settings/src/index.ts:81-83`）。冲突抛 `SettingsConflictError`（code `SETTINGS_CONFLICT`，`:45-64`）。
      await requireSettings().mutate(
        ns,
        [{ op: 'set', path: [...path], value }],
        expectedRevision as never,
      )
    },

    async setFields(ns, patch, expectedRevision) {
      // `update(ns, patch, expectedRevision?)`：合并进该条目的 config，
      // 一次 `configEditor.edit`（`packages/settings/settings/src/index.ts:348-351`）。
      await requireSettings().update(ns, { ...patch }, expectedRevision as never)
    },

    async setSecret(ref, value) {
      // 空值会被拒绝，删除要用 `unset`（`credentials/src/index.ts:201` 与 `:209`）。
      await requireCredentials().set(ref, value)
    },

    async unsetSecret(ref) {
      await requireCredentials().unset(ref)
    },

    async secretStatus(ref) {
      // `describe(ref)` 返回 `CredentialInfo { configured, source?, writable }` ——
      // 注释原文「The view has no slot a value could ride in」（`credentials/src/types.ts:67-74`）。
      const info = await requireCredentials().describe(ref)
      if (info === undefined) return { configured: false, writable: false }
      return { configured: info.configured, writable: info.writable }
    },
  }
}
