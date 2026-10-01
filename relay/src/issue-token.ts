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

/** 令牌长度（16 字节 = 128 位）。 */
export const TOKEN_BYTES = 16

export interface TokenKind {
  kind: 'device' | 'connector'
  /** 逻辑身份：设备 id 或连接器 id。 */
  id: string
}

export interface IssuedToken {
  /** **只在签发这一刻存在**：调用方负责显示一次，不落盘。 */
  token: string
  /** `sha256(token)` 的十六进制 —— 落进配置的就是它。 */
  hash: string
}

export interface TokenConfigEntry {
  kind: 'device' | 'connector'
  id: string
  hash: string
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
