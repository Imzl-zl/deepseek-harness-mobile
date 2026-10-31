/**
 * 令牌签发（契约 §12.2 的另一半：中转只存摘要）。
 *
 * 现在摘要表**就是配置文件**（库还没落地），所以签发 = "生成一个令牌 + 把它的摘要追加进配置"。
 * 这条链路里唯一必须钉住的安全性质是：
 *
 * > **令牌本体只出现在签发者的屏幕上，绝不写进配置。**
 *
 * 写进去的话，那份配置就从"摘要表"退化成"凭据表" —— 而 §12.2 让它只存摘要，
 * 正是为了"配置或库被读到时里面的东西不能直接用"。这条性质有测试（读回文件断言不含令牌）。
 *
 * 令牌本身 128 位随机（与 `requestId`、配对码、一次性 ticket 同规格）：它是长期凭据，
 * 但长度不该因为"长期"而缩短 —— 随机性才是它唯一的防线。
 */
import { createHash, randomBytes as nodeRandomBytes } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'

/**
 * 令牌签发与配置读写（契约 §12.2：**中转只存摘要**）。
 *
 * ## 只签**连接器**令牌
 *
 * 设备令牌不在这里签：它由电脑侧签发、摘要经 `POST /devices` 进名册（§8.2）。
 * 中转签设备令牌等于转发器凭空造出"我是某台设备"的凭据，正是 v2 否掉的形状
 * （`pairing-v2.md` §1：中转只做连接路由；身份判定在电脑侧）。
 * 所以 `TokenKind` 只收 `connector` —— 想给设备发令牌的人会在编译期就看到这句话。
 */

/** 令牌长度（16 字节 = 128 位）。 */
export const TOKEN_BYTES = 16

/** 生成一枚令牌原文（128 位随机，base64url）。管理令牌与连接器令牌同规格。 */
export function randomToken(
  random: (size: number) => Uint8Array = (size) => nodeRandomBytes(size),
): string {
  return Buffer.from(random(TOKEN_BYTES)).toString('base64url')
}

/** `sha256(令牌)` 的十六进制。配置里存的就是它。 */
export function hashOf(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex')
}

export interface TokenKind {
  kind: 'connector'
  /** 逻辑身份：连接器 id。 */
  id: string
}

export interface IssuedToken {
  /** **只在签发这一刻存在**：调用方负责显示一次，不落盘。 */
  token: string
  /** `sha256(token)` 的十六进制 —— 落进配置的就是它。 */
  hash: string
}

export interface TokenConfigEntry {
  kind: 'connector'
  id: string
  hash: string
  /**
   * 这台连接器属于谁（可选）。同一人的多台电脑写同一个值。
   *
   * 只影响**按人**的东西：限流桶与日志归属（见 `digest-auth.ts` 的 `rateKeyOf`）。
   * 路由、名册、票都不看它 —— 那些按 `(connectorId, deviceId)` 走。
   */
  owner?: string
  /** `auto` = 连接器自己在中转上兑换的。见 `digest-auth.ts` 的 `TokenDigest.source`。 */
  source?: 'auto'
  /** 吊销时间（§12 的 `revoked_at`：**软吊销**）。见 `digest-auth.ts` 的说明。 */
  revokedAt?: number
}

export function issueToken(
  spec: TokenKind,
  random: (size: number) => Uint8Array = (size) => nodeRandomBytes(size),
): IssuedToken {
  const token = randomToken(random)
  // `spec` 只用来让调用方一眼看出"这个令牌是给谁的"；它不进任何签名（摘要是唯一的凭据面）。
  void spec
  return { token, hash: hashOf(token) }
}

/**
 * 把一条摘要追加进配置文件（保留既有条目，按 `(kind, id)` 去重覆盖）。
 *
 * 返回写回后的完整条目列表，便于调用方打印"现在表里有几条"。
 */
export async function appendTokenToConfig(
  configPath: string,
  entry: TokenConfigEntry,
): Promise<TokenConfigEntry[]> {
  const raw = await readFile(configPath, 'utf8')
  const config = JSON.parse(raw) as { tokens?: TokenConfigEntry[] }
  const existing = config.tokens ?? []
  // 同一个身份重新签发时**替换**旧摘要（否则旧令牌仍然有效 —— 那是"吊销不了"的形状）。
  const kept = existing.filter((item) => !(item.kind === entry.kind && item.id === entry.id))
  const tokens = [...kept, entry]
  await writeFile(configPath, `${JSON.stringify({ ...config, tokens }, null, 2)}\n`, 'utf8')
  return tokens
}

/**
 * 吊销一条令牌（软吊销：行留着、标上 `revokedAt`）。
 *
 * 保留原行而不是删掉，有两个理由：
 * 1. §12 的中转表就是这个形状（`revoked_at`），而"删掉"会让审计线索消失
 *    （"这个身份曾经存在过、某时刻被吊销"是有用的事实）；
 * 2. 将来可以把"你被吊销了"与"这个令牌没见过"分开告诉设备 —— 今天两者都是 401，
 *    因为对客户端来说下一步动作相同，但**能力**留着比补回来便宜。
 *
 * @returns 吊销后的完整条目列表；身份不存在时原样返回（不报错 —— 幂等比"告诉你没这条"更有用）。
 */
export async function revokeTokenInConfig(
  configPath: string,
  spec: TokenKind,
  now: number = Date.now(),
): Promise<{ tokens: TokenConfigEntry[]; revoked: boolean }> {
  const raw = await readFile(configPath, 'utf8')
  const config = JSON.parse(raw) as { tokens?: TokenConfigEntry[] }
  const tokens = (config.tokens ?? []).map((entry) => {
    if (entry.kind !== spec.kind || entry.id !== spec.id) return entry
    // 已经吊销过就保留原时间（幂等：重复执行不刷新吊销时刻）。
    return entry.revokedAt === undefined ? { ...entry, revokedAt: now } : entry
  })
  const revoked = tokens.some(
    (entry) => entry.kind === spec.kind && entry.id === spec.id && entry.revokedAt !== undefined,
  )
  await writeFile(configPath, `${JSON.stringify({ ...config, tokens }, null, 2)}\n`, 'utf8')
  return { tokens, revoked }
}

/**
 * 恢复一条被软吊销的令牌（把 `revokedAt` 拿掉）。
 *
 * 与 `revokeTokenInConfig` 对称：面板的"恢复"按钮走这里，**不是**重新签发 ——
 * 重新签发会让对端那串旧令牌彻底作废，而"恢复"的语义正是"那串还能用"。
 */
export async function restoreTokenInConfig(
  configPath: string,
  spec: TokenKind,
): Promise<{ tokens: TokenConfigEntry[]; restored: boolean }> {
  const raw = await readFile(configPath, 'utf8')
  const config = JSON.parse(raw) as { tokens?: TokenConfigEntry[] }
  let restored = false
  const tokens = (config.tokens ?? []).map((entry) => {
    if (entry.kind !== spec.kind || entry.id !== spec.id || entry.revokedAt === undefined) return entry
    restored = true
    const { revokedAt: _dropped, ...rest } = entry
    return rest
  })
  if (restored) await writeFile(configPath, `${JSON.stringify({ ...config, tokens }, null, 2)}\n`, 'utf8')
  return { tokens, restored }
}

/**
 * 把某人的上限写进配置（面板的"设上限 / 取消上限"）。
 *
 * `bytes === null` = **取消这个人的上限**（删掉 `owners` 里那一格；删空了连 `owners`
 * 一起去掉）。配置里**没有 `quota` 段也能写**：只写 `owners` 是合法的半截配置，
 * `period`/`enforce` 都有默认值，不会让中转起不来。
 */
export async function setQuotaOwnerInConfig(
  configPath: string,
  owner: string,
  bytes: number | null,
): Promise<void> {
  const raw = await readFile(configPath, 'utf8')
  const config = JSON.parse(raw) as { quota?: { owners?: Record<string, number> } }
  const owners = { ...(config.quota?.owners ?? {}) }
  if (bytes === null) {
    if (!(owner in owners)) return
    delete owners[owner]
  } else {
    owners[owner] = bytes
  }
  const quota: { owners?: Record<string, number> } = { ...(config.quota ?? {}) }
  if (Object.keys(owners).length === 0) delete quota.owners
  else quota.owners = owners
  await writeFile(configPath, `${JSON.stringify({ ...config, quota }, null, 2)}\n`, 'utf8')
}

/**
 * 把「连接器是否必须认证」与自动签发名额写进配置（面板那两格）。
 *
 * **两个键都显式写出来**：`autoEnrollLimit: null` 是"无上限"这个决定本身，
 * 不写和写 null 在语义上一样，但写出来 owner 下次打开配置看得见自己选了什么。
 */
export async function setConnectorAuthInConfig(
  configPath: string,
  mode: 'open' | 'required',
  limit: number | null,
): Promise<void> {
  const raw = await readFile(configPath, 'utf8')
  const config = JSON.parse(raw) as Record<string, unknown>
  await writeFile(
    configPath,
    `${JSON.stringify({ ...config, connectorAuth: mode, autoEnrollLimit: limit }, null, 2)}\n`,
    'utf8',
  )
}

/**
 * 从配置里**删掉**一条令牌记录（不可恢复）。
 *
 * 与 `revokeTokenInConfig` 分开：吊销是"留着行、标时间"（可恢复、有审计），
 * 删除是"这条记录不存在了"。只有确认过"已吊销"的调用方才该走这里 ——
 * 那条顺序由面板强制（先吊销、再删除），不是这里猜。
 */
export async function removeTokenFromConfig(
  configPath: string,
  spec: TokenKind,
): Promise<{ tokens: TokenConfigEntry[]; removed: boolean }> {
  const raw = await readFile(configPath, 'utf8')
  const config = JSON.parse(raw) as { tokens?: TokenConfigEntry[] }
  const existing = config.tokens ?? []
  const tokens = existing.filter((entry) => !(entry.kind === spec.kind && entry.id === spec.id))
  const removed = tokens.length !== existing.length
  if (removed) await writeFile(configPath, `${JSON.stringify({ ...config, tokens }, null, 2)}\n`, 'utf8')
  return { tokens, removed }
}

/** 配置里的管理面段（`admin`）：只放摘要。 */
export interface AdminConfigEntry {
  id: string
  /** `sha256(令牌)` 的十六进制。 */
  hash: string
}

/**
 * 把管理面摘要写进配置（整份重写，保留其他键）。
 *
 * 与 `appendTokenToConfig` 同一形状：**明文只出现在签发者的屏幕上**。
 * 覆盖旧值就是"轮换管理令牌" —— 旧令牌下次启动即失效（内存里的表由装配方同步替换）。
 */
export async function setAdminInConfig(
  configPath: string,
  entry: AdminConfigEntry,
): Promise<void> {
  const raw = await readFile(configPath, 'utf8')
  const config = JSON.parse(raw) as { admin?: AdminConfigEntry }
  await writeFile(configPath, `${JSON.stringify({ ...config, admin: entry }, null, 2)}\n`, 'utf8')
}
