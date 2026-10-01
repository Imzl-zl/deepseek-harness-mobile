/**
 * 电脑侧身份种子的落点（契约 §4.1、§12.1）。
 *
 * 三件事：
 *
 * 1. 身份是**一个 32 字节主种子**，两把长期密钥都由它派生（`protocol/crypto.ts`）——
 *    所以这里只需要看住这一个 secret。
 * 2. 它进凭据 seam 的**具名记录面**（`CredentialKey`），不是设置、不是配置文件：
 *    记录面的 `payload` 按定义就是「本插件自己的格式，seam 不解释它」
 *    （`packages/credentials/credentials/src/types.ts:52-57`），正是自持密钥该待的地方。
 * 3. **只在没有记录时生成**（§12.1 第 1 步「电脑侧生成身份」）。已有记录但读不懂时**抛错**，
 *    绝不覆盖 —— 覆盖等于把所有已配对设备一次性作废，而症状只是"手机连不上"。
 *
 * 用到的凭据接口（路径相对 DSH checkout 根）：
 *
 * | 接口 | 位置 |
 * |---|---|
 * | `credentialKey(scope, id)`，两段都须匹配 `^[a-z][a-z0-9-]*$` | `packages/credentials/credentials/src/index.ts:22,69` |
 * | `readRecord(key)` | 同文件 `:217` |
 * | `modifyRecord(key, mutate)` —— **唯一**的写路径（读-改-写在一把锁里） | 同文件 `:236-250` |
 *
 * 为什么落在这里（而不是设置、配置文件或 domain KV）见
 * `.agents/notes/implemented/2026-10-01-connector-identity-home.md`
 */
import type { CredentialKey, CredentialRecord } from '@deepseek-ai/dsh-credentials'
import { credentialKey } from '@deepseek-ai/dsh-credentials'

import { deriveIdentity, generateIdentitySeed, type IdentityKeys } from '../protocol/crypto.js'

/** 记录地址：`<本插件注册名>/<id>`。作用域取注册名，所以别的插件读不到这条。 */
export const IDENTITY_RECORD: CredentialKey = credentialKey('dsh-mobile-connector', 'identity')

/**
 * 本文件真正用到的凭据面（就这两个方法）。
 *
 * 收窄成端口而不是直接吃 `CredentialProvider`：一来这个模块能在没有 DSH 运行时的情况下
 * 被测到，二来**它拿不到别的方法**，于是"顺手读一下别人的凭据"在类型上就不可能。
 * 结构上 `CredentialProvider` 天然满足它（`index.ts` 直接把 `ctx.get('credentials')` 递进来）。
 */
export interface IdentityCredentials {
  readRecord(key: CredentialKey): Promise<CredentialRecord | undefined>
  modifyRecord(
    key: CredentialKey,
    mutate: (current: CredentialRecord | undefined) => Promise<CredentialRecord | undefined>,
  ): Promise<CredentialRecord | undefined>
}

/** 记录载荷。**只有 masterSeed**：其余都由它派生，存第二份就多一个漂移点。 */
interface IdentityPayload {
  masterSeed: string
}

export interface Identity {
  masterSeed: string
  keys: IdentityKeys
}

const SEED_RE = /^[0-9a-f]{64}$/

/** 从记录里取种子；记录不存在返回 `undefined`，**存在但读不懂则抛**。 */
function seedOf(record: CredentialRecord | undefined): string | undefined {
  if (record === undefined) return undefined
  if (record.kind !== 'grant') {
    throw new Error(
      `身份记录 ${IDENTITY_RECORD} 是 ${record.kind} 类型，不是本插件写的 grant 记录：拒绝在别人的记录上做手脚`,
    )
  }
  const payload: unknown = record.payload
  const seed =
    typeof payload === 'object' && payload !== null
      ? (payload as Record<string, unknown>)['masterSeed']
      : undefined
  if (typeof seed !== 'string' || !SEED_RE.test(seed)) {
    throw new Error(
      `身份记录 ${IDENTITY_RECORD} 里的 masterSeed 不合法：拒绝覆盖（覆盖会让所有已配对设备作废）`,
    )
  }
  return seed
}

/**
 * 取本机身份：有记录就用它，没有就生成一条并落盘。
 *
 * **返回值里那条记录才是权威**，不是我们自己生成的那个种子：两个进程同时首启时，
 * 先到者写入、后到者拿到的是它写的那条（`modifyRecord` 的回调此时看到的是已有记录，
 * 返回 `undefined` 即"不改"）。用自己生成的那个会让两端身份悄悄分叉。
 */
export async function loadOrCreateIdentity(credentials: IdentityCredentials): Promise<Identity> {
  const existing = seedOf(await credentials.readRecord(IDENTITY_RECORD))
  if (existing !== undefined) return { masterSeed: existing, keys: deriveIdentity(existing) }

  const written = await credentials.modifyRecord(IDENTITY_RECORD, (current) =>
    Promise.resolve(
      current ?? ({ kind: 'grant', payload: { masterSeed: generateIdentitySeed() } } satisfies { kind: 'grant'; payload: IdentityPayload }),
    ),
  )
  const seed = seedOf(written)
  if (seed === undefined) {
    throw new Error(`身份记录 ${IDENTITY_RECORD} 写入后仍读不到：凭据提供方拒绝了这次写`)
  }
  return { masterSeed: seed, keys: deriveIdentity(seed) }
}
