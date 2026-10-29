/**
 * 连接器令牌的读取（契约 §12.2：令牌本体走 `ctx.credentials` 的**具名记录面**）。
 *
 * 形状与身份那条记录同一个范式（`dsh/identity.ts`）：`credentialKey(scope, id)`，
 * 记录 `payload` 由本插件自己解释（seam 不解释它）。
 *
 * ## 三条判断，都是"读不到就大声失败"
 *
 * 1. **记录不存在 → 抛**（不去生成一个）：连接器令牌是**带外配好的**（操作者把它放进凭据 seam），
 *    插件自己编一个只会得到一个中转不认识的令牌 —— 而症状是"连不上"，看不出是令牌没配。
 * 2. **记录类型/载荷不对 → 抛**：别人的记录被我们读到时，静默返回 `undefined`
 *    会让调用方以为"没配"，于是排查方向跑到配置上。
 * 3. **不缓存**：每次要令牌时读一次。凭据面是读-改-写带锁的记录面，读一次很便宜；
 *    缓存反而会在操作者更新令牌后继续用旧的 —— 那种"改了没生效"最难查。
 *
 * 这一层只依赖 `readRecord` 这一个方法（收窄的端口），所以可脱离 DSH 测。
 *
 * ## 写面（2026-10-29 加）
 *
 * 面板的「连接」卡要能换令牌、也要能删。记录面**唯一的写路径是 `modifyRecord`**
 * （没有 `setRecord`），删除是 `deleteRecord`；`set/unset` 只属于 ref（env 形状）
 * 那一半，与记录键文法互斥（`packages/credentials/credentials/src/index.ts:19,22`）。
 * 所以写/删只在这里各开一个窄入口，键的推导仍然只有一处。
 *
 * **值永不回传**：这里没有任何"读出令牌"给调用方的入口；`readRelayToken` 只服务
 * 拨号（§12.2），`relayTokenStatusOf` 只回「设没设 + 能不能写」。
 *
 * 用到的 DSH 接口与位置（与 `dsh/identity.ts` 同一张表）：
 *
 * | 接口 | 位置 |
 * |---|---|
 * | `credentialKey(scope, id)`，两段都须匹配 `^[a-z][a-z0-9-]*$` | `packages/credentials/credentials/src/index.ts:22,69` |
 * | `readRecord(key)` | 同文件 `:217` |
 * | 记录面的 `payload` 由插件自己解释 | `packages/credentials/credentials/src/types.ts:52-57` |
 */
import {
  credentialKey,
  type CredentialKey,
  type CredentialRecord,
  type CredentialRecordInfo,
} from '@deepseek-ai/dsh-credentials'

/** 凭据记录的 scope（与身份记录同一个插件 scope）。 */
const SCOPE = 'dsh-mobile-connector'

/** 只依赖读：令牌由操作者带外配好，插件不写它。 */
export interface RelayTokenSource {
  readRecord(key: CredentialKey): Promise<CredentialRecord | undefined>
}

/** 记录面的写/删/状态（三个窄方法，**没有读值的那一半**）。 */
export interface RelayTokenStore extends RelayTokenSource {
  describeRecord(key: CredentialKey): Promise<CredentialRecordInfo>
  modifyRecord(
    key: CredentialKey,
    mutate: (current: CredentialRecord | undefined) => Promise<CredentialRecord | undefined>,
  ): Promise<CredentialRecord | undefined>
  deleteRecord(key: CredentialKey): Promise<void>
}

export class RelayTokenError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'RelayTokenError'
  }
}

/**
 * 令牌字面量的约束。
 *
 * 它会原样进 `Authorization: Bearer <token>`（`transport/relay-link.ts:110`），
 * 所以**不能含空白与控制字符** —— 那是 HTTP 头注入，不是风格问题。
 * 上限 512 只是防手滑粘进整行日志；中转签发的令牌是 22 字符。
 */
const TOKEN_SHAPE = /^[\x21-\x7e]{1,512}$/

/** 记录键：配置里的 `relayTokenRef` 只是 `<scope>/<id>` 的 id 半边。 */
export function relayTokenKey(ref: string): CredentialKey {
  return credentialKey(SCOPE, ref)
}

/** 「设没设 + 能不能写」。**没有能装值的槽**（`types.ts:63-74` 的原话）。 */
export async function relayTokenStatusOf(
  store: Pick<RelayTokenStore, 'describeRecord'>,
  ref: string,
): Promise<{ configured: boolean; writable: boolean }> {
  const info = await store.describeRecord(relayTokenKey(ref))
  return { configured: info.configured, writable: info.writable }
}

/**
 * 写入（或替换）连接器令牌。
 *
 * 走 `modifyRecord`：它是记录面**唯一**的写路径，而且"读—决定—替换"在一把锁里
 * 完成（`packages/credentials/credentials-local/src/index.ts:678-712`）。
 * 变更函数直接给出新记录：换令牌不需要看旧值。
 */
export async function writeRelayToken(
  store: Pick<RelayTokenStore, 'modifyRecord'>,
  ref: string,
  token: string,
): Promise<void> {
  const value = token.trim()
  if (value === '') throw new RelayTokenError('令牌不能为空：要撤掉请用删除，而不是填一个空值')
  if (!TOKEN_SHAPE.test(value)) {
    throw new RelayTokenError('令牌只能是不含空白/控制字符的可见 ASCII（≤512 字符）：它要放进 Authorization 头')
  }
  await store.modifyRecord(relayTokenKey(ref), () =>
    Promise.resolve({ kind: 'grant', payload: { token: value } }),
  )
}

/** 删除连接器令牌。删除后拨号会抛 `RelayTokenError`（不再静默匿名连接）。 */
export async function clearRelayToken(
  store: Pick<RelayTokenStore, 'deleteRecord'>,
  ref: string,
): Promise<void> {
  await store.deleteRecord(relayTokenKey(ref))
}

/**
 * 读出连接器令牌。
 *
 * @param ref 配置里的 `relayTokenRef`（`^[a-z][a-z0-9-]*$`）。
 * @throws RelayTokenError 记录缺失或形状不对 —— **不返回空串**：空令牌会退化成"匿名连接"，
 *         而中转会回 401，症状与"没配令牌"一样却更难关联。
 */
export async function readRelayToken(
  credentials: RelayTokenSource,
  ref: string,
): Promise<string> {
  const key = credentialKey(SCOPE, ref)
  const record = await credentials.readRecord(key)
  if (record === undefined) {
    throw new RelayTokenError(
      `凭据里没有连接器令牌记录（${SCOPE}/${ref}）：请先把中转签发的连接器令牌放进凭据 seam`,
    )
  }
  if (record.kind !== 'grant') {
    throw new RelayTokenError(
      `连接器令牌记录 ${SCOPE}/${ref} 是 ${record.kind} 类型，不是本插件写的 grant 记录`,
    )
  }
  const payload = record.payload as { token?: unknown } | undefined
  const token = payload?.token
  if (typeof token !== 'string' || token === '') {
    throw new RelayTokenError(`连接器令牌记录 ${SCOPE}/${ref} 里没有非空的 token 字段`)
  }
  return token
}
