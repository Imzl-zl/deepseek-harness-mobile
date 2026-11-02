/**
 * 管理台「设置」页的配置写回。
 *
 * 只改 `auth.smtp` 与 `auth.registration` 两段，其余键原样保留（尤其是 tokens 与 admin）。
 * 与令牌写入同一条纪律：**先落盘、再改运行时**；写失败时面板回 500，不让界面假装成功。
 *
 * 决策见 `.agents/notes/implemented/2026-11-02-relay-editorial-ui-and-admin-settings.md`。
 */
import { readFile, writeFile } from 'node:fs/promises'

import type { RegistrationMode } from './config.ts'
import type { SmtpConfig } from './smtp.ts'

interface ConfigFile {
  auth?: Record<string, unknown>
  [key: string]: unknown
}

async function readConfig(configPath: string): Promise<ConfigFile> {
  return JSON.parse(await readFile(configPath, 'utf8')) as ConfigFile
}

async function writeConfig(configPath: string, config: ConfigFile): Promise<void> {
  await writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`, 'utf8')
}

export async function setSmtpInConfig(configPath: string, smtp: SmtpConfig): Promise<void> {
  const config = await readConfig(configPath)
  await writeConfig(configPath, { ...config, auth: { ...(config.auth ?? {}), smtp } })
}

export async function setRegistrationInConfig(
  configPath: string,
  mode: RegistrationMode,
  emailDomains: readonly string[],
): Promise<void> {
  const config = await readConfig(configPath)
  const auth = config.auth ?? {}
  const current = typeof auth['registration'] === 'object' && auth['registration'] !== null
    ? auth['registration'] as Record<string, unknown>
    : {}
  await writeConfig(configPath, {
    ...config,
    auth: {
      ...auth,
      registration: { ...current, mode, emailDomains: [...emailDomains] },
    },
  })
}
