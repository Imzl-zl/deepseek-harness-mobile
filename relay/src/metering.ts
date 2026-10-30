/**
 * 按人的流量额度（契约 §2.4 的"按设备限流与审计"从**请求数**扩到**字节**）。
 *
 * ## 它回答的唯一问题
 *
 * "这个人（不是这条连接、也不是这台电脑）这一段周期里已经过了多少字节，超没超？"
 *
 * ## 三条口径（都在这里定死，别处不许再判一遍）
 *
 * 1. **主体是人**：`owner`；没配 `owner` 的连接器退回 `connector:<id>` ——
 *    与限流桶同一个判据（`digest-auth.ts` 的 `rateKeyOf`）。多开一台电脑不多领额度。
 * 2. **只算业务通道的双向帧**：配对候选（`purpose === 'pairing'`）不计量。
 *    配对是恢复路径 —— 一个人把额度用完不该连"重新扫码"都做不到。
 * 3. **周期用 UTC**（`YYYY-MM` / `YYYY-MM-DD`），惰性结算：读的时候发现周期变了就归零，
 *    不引定时器（每个身份一个定时器会在空闲连接上无谓唤醒）。
 *
 * ## 计数与限额分离
 *
 * 这里只做"记了多少、超没超"；**断不断**由 `server.ts` 按 `enforce` 决定：
 * `cut` 断已有连接、`block` 只挡新建、`off` 只记账。
 *
 * Note: 为什么按人、为什么配对不计量、为什么复用 `rate-limited` 而不加新码 —— 见
 * `.agents/notes/implemented/2026-10-30-relay-quota-per-owner.md`
 */
import type { ChannelLogger } from './logger.ts'

export type QuotaPeriod = 'month' | 'day' | 'none'
export type QuotaEnforce = 'cut' | 'block' | 'off'

export interface QuotaConfig {
  /** 结算周期。`none` = 永不清零（手动重置）。默认 `month`。 */
  period?: QuotaPeriod
  /** 上限触顶后的动作。默认 `cut`。 */
  enforce?: QuotaEnforce
  /**
   * 每人每周期默认上限（字节）。**不写 = 不限制**（默认）。
   *
   * "默认不限制、由管理员配"是这套东西的常态：记账一直在跑（面板看得到谁用了多少），
   * 上限是管理员在面板上给某个人设的；只有设了上限的人才可能被挡住。
   */
  defaultBytes?: number
  /** 按人覆盖（`user:<owner>` 的上限）。 */
  owners?: Record<string, number>
  /** 是否落盘（默认 `false`：重启清零，与名册/票同一条纪律）。 */
  persist?: boolean
  /** 落盘路径（`persist: true` 时必须给；默认由装配方按配置文件目录补）。 */
  statePath?: string
}

/** 从磁盘读回的形状（只在 `persist: true` 时有）。 */
export interface MeteringState {
  v: 1
  /** `主体 → { 周期键, 已用字节 }`。 */
  meters: Record<string, { period: string; bytes: number }>
}

export interface MeterRow {
  subject: string
  used: number
  /** `null` = 不限制。 */
  limit: number | null
  period: string
}

export interface ChargeResult {
  over: boolean
  used: number
  /** `null` = 不限制。 */
  limit: number | null
}

export interface MeteringOptions {
  quota: QuotaConfig
  /** `connectorId → owner`。来自配置里的令牌条目（不是运行时状态）。 */
  ownerOf: (connectorId: string) => string | undefined
  now?: () => number
  /** 启动时读回的状态（周期对不上就按 0 起算）。 */
  state?: MeteringState
  log?: ChannelLogger
}

export interface Metering {
  readonly enforce: QuotaEnforce
  /** 结算周期（面板显示用）。 */
  readonly period: QuotaPeriod
  /** 这条连接器算在谁名下（额度主体）。 */
  subjectOf(connectorId: string): string
  /** 记一笔字节（帧边界调用，同步、无分配）。 */
  charge(connectorId: string, bytes: number): ChargeResult
  /** 现在超没超（不记账）。`enforce: 'off'` 时恒为 false —— 调用方据此只挡/只算。 */
  check(connectorId: string): { exceeded: boolean; retryAfterMs: number | null }
  usedOf(subject: string): number
  /** `null` = 不限制。 */
  limitOf(subject: string): number | null
  /** 近 60 分钟**整台中转**的字节数（面板的曲线；全局也只有一份，不按人拆）。 */
  traffic(): { perMinute: readonly number[]; total: number }
  /**
   * 运行时改上限（面板）：`null` = 取消上限。只改内存覆盖值，落盘由装配方负责。
   */
  setLimit(subject: string, bytes: number | null): void
  reset(subject: string): boolean
  snapshot(): readonly MeterRow[]
  /** 落盘用的快照（只含当前周期有效的行）。 */
  serialize(): MeteringState
  /** 清掉一次"已落盘"标记（由装配方在写成功后调用）。 */
  markClean(): void
  readonly dirty: boolean
}

/** 周期键：UTC。`none` 用一个固定键（永不清零）。 */
export function periodKeyOf(at: number, period: QuotaPeriod): string {
  if (period === 'none') return 'all'
  const iso = new Date(at).toISOString()
  return period === 'day' ? iso.slice(0, 10) : iso.slice(0, 7)
}

/** 下一个周期边界（毫秒时间戳）；`none` 返回 `undefined`（不会自行恢复）。 */
export function nextBoundaryOf(at: number, period: QuotaPeriod): number | undefined {
  if (period === 'none') return undefined
  const d = new Date(at)
  if (period === 'day') {
    return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1)
  }
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1)
}

export function createMetering(options: MeteringOptions): Metering {
  const { quota } = options
  const now = options.now ?? (() => Date.now())
  const period: QuotaPeriod = quota.period ?? 'month'
  const enforce: QuotaEnforce = quota.enforce ?? 'cut'
  /**
   * 运行时的上限覆盖（面板改的那一格）。**`has` 与值分开**：`null` 是"取消上限"，
   * 与"没覆盖过（回落到配置）"不是同一件事。
   *
   * 与配置里的 `quota.owners` **不是**两份真相：面板改完会把它写回配置（装配方负责），
   * 重启后从这里读回来的是配置值。内存里这份只是"不必重启就生效"的那一步。
   */
  const overrides = new Map<string, number | null>()
  const limitOfSubject = (subject: string): number | null => {
    if (overrides.has(subject)) return overrides.get(subject) ?? null
    if (subject.startsWith('user:')) {
      const owner = subject.slice('user:'.length)
      return quota.owners?.[owner] ?? quota.defaultBytes ?? null
    }
    return quota.defaultBytes ?? null
  }
  /**
   * `主体 → { 周期键, 已用 }`。
   *
   * 键来自**配置身份**（owner 或连接器 id），不来自请求内容 —— 所以这张表的大小
   * 由令牌条数封顶，扫描者无法给它灌内存。
   */
  const meters = new Map<string, { period: string; bytes: number }>()
  /**
   * 近 60 分钟的流量序列（整台服务）。只存 60 个整数，按分钟滚动；
   * 面板的曲线读它 —— **不是抽样、不是估算**，就是这段时间真正转发过的字节。
   */
  const TRAFFIC_MINUTES = 60
  const traffic = new Array<number>(TRAFFIC_MINUTES).fill(0)
  let trafficMinute = Math.floor(now() / 60_000)
  const rollTraffic = (minute: number): void => {
    if (minute === trafficMinute) return
    const gap = Math.min(TRAFFIC_MINUTES, minute - trafficMinute)
    if (gap >= TRAFFIC_MINUTES) traffic.fill(0)
    else {
      traffic.splice(0, gap)
      for (let index = 0; index < gap; index += 1) traffic.push(0)
    }
    trafficMinute = minute
  }
  let dirty = false

  if (options.state !== undefined) {
    const current = periodKeyOf(now(), period)
    for (const [subject, row] of Object.entries(options.state.meters)) {
      // 周期对不上就丢弃：那正是"上个月用了多少"不该算进这个月的意思。
      if (row.period !== current || typeof row.bytes !== 'number' || !Number.isFinite(row.bytes)) continue
      meters.set(subject, { period: row.period, bytes: row.bytes })
    }
  }

  const subjectOf = (connectorId: string): string => {
    const owner = options.ownerOf(connectorId)
    return owner === undefined || owner === '' ? `connector:${connectorId}` : `user:${owner}`
  }

  /** 惰性结算：周期变了就把这一行归零（不是"下次记账时才发现"）。 */
  const rowOf = (subject: string): { period: string; bytes: number } => {
    const current = periodKeyOf(now(), period)
    const row = meters.get(subject)
    if (row !== undefined && row.period === current) return row
    if (row !== undefined) {
      options.log?.debug(`额度周期滚动：${subject} 从 ${row.period} 归零`)
      dirty = true
    }
    const fresh = { period: current, bytes: 0 }
    meters.set(subject, fresh)
    return fresh
  }

  return {
    enforce,
    period,
    subjectOf,

    charge(connectorId, bytes) {
      const subject = subjectOf(connectorId)
      const row = rowOf(subject)
      row.bytes += bytes
      dirty = true
      const minute = Math.floor(now() / 60_000)
      rollTraffic(minute)
      traffic[TRAFFIC_MINUTES - 1] = (traffic[TRAFFIC_MINUTES - 1] ?? 0) + bytes
      const limit = limitOfSubject(subject)
      // **用满就算满**（`>=`）：到恰好上限时这个人已经没有额度了，下一帧必然超。
      // 与 `check` 同一个判据，否则会出现"charge 说没超、check 说超了"的两套话。
      // **没设上限（`null`）就永不超** —— 默认不限制。
      return { over: limit !== null && row.bytes >= limit, used: row.bytes, limit }
    },

    check(connectorId) {
      const subject = subjectOf(connectorId)
      const row = rowOf(subject)
      const limit = limitOfSubject(subject)
      const exceeded = enforce !== 'off' && limit !== null && row.bytes >= limit
      if (!exceeded) return { exceeded: false, retryAfterMs: null }
      const boundary = nextBoundaryOf(now(), period)
      // `none` 周期永不自行恢复 —— 如实回 `null`（与限流的"零补充"同义）。
      return { exceeded: true, retryAfterMs: boundary === undefined ? null : boundary - now() }
    },

    usedOf(subject) { return rowOf(subject).bytes },
    limitOf(subject) { return limitOfSubject(subject) },

    traffic() {
      rollTraffic(Math.floor(now() / 60_000))
      let total = 0
      for (const value of traffic) total += value
      return { perMinute: [...traffic], total }
    },

    setLimit(subject, bytes) {
      // 只接受**已知主体**：已有计数行，或配置里点名的人。面板不该成为"新额度主体"的入口。
      const known = meters.has(subject)
        || (subject.startsWith('user:') && Object.hasOwn(quota.owners ?? {}, subject.slice('user:'.length)))
      if (!known) throw new Error('没有这个额度主体')
      overrides.set(subject, bytes)
    },

    reset(subject) {
      const row = meters.get(subject)
      if (row === undefined) return false
      meters.set(subject, { period: periodKeyOf(now(), period), bytes: 0 })
      dirty = true
      return true
    },

    snapshot() {
      const rows: MeterRow[] = []
      for (const [subject, row] of meters) {
        rows.push({ subject, used: row.bytes, limit: limitOfSubject(subject), period: row.period })
      }
      // 配置里点名的、这个周期还没用过的也要出现在面板上（否则"上限 100 MB"那行
      // 要等对方传了字节才凭空冒出来）；键来自配置，不放大表。
      for (const owner of Object.keys(quota.owners ?? {})) {
        const subject = `user:${owner}`
        if (meters.has(subject)) continue
        rows.push({ subject, used: 0, limit: limitOfSubject(subject), period: periodKeyOf(now(), period) })
      }
      return rows
    },

    serialize() {
      const metersOut: MeteringState['meters'] = {}
      for (const [subject, row] of meters) metersOut[subject] = { period: row.period, bytes: row.bytes }
      return { v: 1, meters: metersOut }
    },

    markClean() { dirty = false },
    get dirty() { return dirty },
  }
}
