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
  /** 吊销时间（§12 的 `revoked_at`：**软吊销**）。见 `digest-auth.ts` 的说明。 */
  revokedAt?: number
}

export function issueToken(
  spec: TokenKind,
  random: (size: number) => Uint8Array = (size) => nodeRandomBytes(size),
): IssuedToken {
  const token = Buffer.from(random(TOKEN_BYTES)).toString('base64url')
  const hash = createHash('sha256').update(token, 'utf8').digest('hex')
  // `spec` 只用来让调用方一眼看出"这个令牌是给谁的"；它不进任何签名（摘要是唯一的凭据面）。
  void spec
  return { token, hash }
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
