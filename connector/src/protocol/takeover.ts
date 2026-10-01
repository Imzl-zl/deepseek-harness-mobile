/**
 * 审批接管的判定（协议契约 §6.2）。
 *
 * 纯函数：输入是「设备状态 + 档位」，输出「是否 claim、由谁接管」。
 * 这条判定必须是**可机械验证**的：三档 × 设备状态的期望结果写在 fixture 16 里，
 * 两侧实现照同一张表写。
 *
 * 与 fixtures 的边界：本文件只做判定，不做 claim 之后的看护与 fail-closed
 * （那是连接层与产品行为，见契约 §6.2）。
 *
 * 移植源：`protocol/reference/takeover.mjs`。
 */

/** 档位：`never` 只通知 / `foreground` 默认 / `always` 只要在线就接管。 */
export const TAKEOVER_MODES = ['never', 'foreground', 'always'] as const

export type TakeoverMode = (typeof TAKEOVER_MODES)[number]

export interface TakeoverDevice {
  id: string
  online: boolean
  foreground: boolean
  subscribed: readonly string[]
  pairedAt: number
  lastInteractedAt?: Record<string, number>
}

export interface TakeoverInput {
  /** 从配置 / 线上来的原始值，非法值要抛错而不是静默降级。 */
  mode: string
  sid: string
  devices: readonly TakeoverDevice[]
}

export interface TakeoverDecision {
  claim: boolean
  deviceId: string | null
  reason: string
}

/**
 * 确定性排序：最近与该会话交互的优先；并列取配对更早的；再并列取 id 升序。
 * 排序必须确定，否则「哪台手机接管」会随 Map 迭代顺序漂移，测试也就不可复现。
 */
function rank(devices: readonly TakeoverDevice[], sid: string): TakeoverDevice[] {
  return [...devices]
    .filter((device) => device.online === true)
    .sort((a, b) => {
      const ai = a.lastInteractedAt?.[sid] ?? -1
      const bi = b.lastInteractedAt?.[sid] ?? -1
      if (ai !== bi) return bi - ai
      if (a.pairedAt !== b.pairedAt) return a.pairedAt - b.pairedAt
      return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
    })
}

export function decideTakeover({ mode, sid, devices }: TakeoverInput): TakeoverDecision {
  if (!(TAKEOVER_MODES as readonly string[]).includes(mode)) {
    throw new Error(`未知接管档位: ${mode}`)
  }
  if (mode === 'never') return { claim: false, deviceId: null, reason: 'mode-never' }

  const candidates = (mode === 'always'
    ? rank(devices, sid) // 在线即可
    : rank(devices, sid).filter(
        (device) => device.foreground === true && (device.subscribed ?? []).includes(sid),
      )
  )

  const winner = candidates[0]
  if (winner === undefined) {
    return {
      claim: false,
      deviceId: null,
      reason: mode === 'always' ? 'no-online-device' : 'no-foreground-subscriber',
    }
  }
  return { claim: true, deviceId: winner.id, reason: `${mode}-claimed` }
}
