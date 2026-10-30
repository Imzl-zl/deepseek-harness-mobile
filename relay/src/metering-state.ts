/**
 * 额度计数器的落盘（可选）。
 *
 * ## 为什么默认不落盘
 *
 * 中转是单实例内存态（契约 §8.2 的"本期实现如实记录"）：名册、票、通道全在进程里。
 * 额度计数跟着同一条纪律 —— 默认重启清零，代价是"重启一次送一次额度"。
 * 要跨重启就得显式打开 `persist`，并接受多一个要挂载/备份的文件。
 *
 * ## 两条边界（都显式，不静默）
 *
 * 1. **写失败不吞**：记 `error` 日志并让调用方知道（面板那次写操作会回 500）。
 * 2. **读失败/损坏不清空**：先把坏文件改名 `.corrupt` 留证，再从零起算 ——
 *    计数器坏了不该让整台中转起不来。
 *
 * 写入是**原子替换**（tmp + rename）且**串行**：两个写请求同时来也不会写出半个 JSON。
 */
import { readFile, rename, writeFile } from 'node:fs/promises'

import type { MeteringState } from './metering.ts'
import type { ChannelLogger } from './logger.ts'

/** 节流窗口：5 s 一次，够便宜也够新（面板 2 s 轮询看的是内存值，不是文件）。 */
export const FLUSH_EVERY_MS = 5_000

const isState = (value: unknown): value is MeteringState => {
  if (typeof value !== 'object' || value === null) return false
  const record = value as Record<string, unknown>
  if (record['v'] !== 1) return false
  const meters = record['meters']
  if (typeof meters !== 'object' || meters === null) return false
  for (const row of Object.values(meters as Record<string, unknown>)) {
    if (typeof row !== 'object' || row === null) return false
    const entry = row as Record<string, unknown>
    if (typeof entry['period'] !== 'string' || typeof entry['bytes'] !== 'number') return false
  }
  return true
}

/**
 * 读回状态。文件不存在 → `undefined`（首次启动）；损坏 → 改名留证后 `undefined`。
 */
export async function readMeteringState(
  path: string,
  log?: ChannelLogger,
): Promise<MeteringState | undefined> {
  let raw: string
  try {
    raw = await readFile(path, 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined
    log?.error('额度状态文件读不了，本次从零起算', error)
    return undefined
  }
  try {
    const parsed: unknown = JSON.parse(raw)
    if (!isState(parsed)) throw new Error('形状不对')
    return parsed
  } catch (error) {
    try {
      await rename(path, `${path}.corrupt`)
      log?.error(`额度状态文件损坏，已改名为 ${path}.corrupt，本次从零起算`, error)
    } catch (renameError) {
      log?.error('额度状态文件损坏且改名失败，本次从零起算', renameError)
    }
    return undefined
  }
}

export interface MeteringStateWriter {
  /** 排一次写（串行：上一次写完才写下一次）。节流由调用方的定时器负责。 */
  save(state: MeteringState): void
  /** 等所有已排队的写完成（关闭前调用）。 */
  flush(): Promise<void>
}

export function createMeteringStateWriter(options: {
  path: string
  log?: ChannelLogger
}): MeteringStateWriter {
  /** 串行链：上一次写完之后再写下一次（禁止两个 rename 抢同一个 tmp）。 */
  let chain: Promise<void> = Promise.resolve()

  return {
    save(state) {
      chain = chain
        .then(async () => {
          const tmp = `${options.path}.tmp`
          await writeFile(tmp, `${JSON.stringify(state)}\n`, 'utf8')
          await rename(tmp, options.path)
        })
        .catch((error: unknown) => { options.log?.error('额度状态落盘失败（计数仍在内存里）', error) })
    },
    async flush() {
      await chain
    },
  }
}
