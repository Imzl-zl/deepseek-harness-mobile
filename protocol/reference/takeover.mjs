/**
 * 参考实现：审批接管的判定（协议契约 §6.2）。
 *
 * 纯函数：输入是"设备状态 + 档位"，输出"是否 claim、由谁接管"。
 * 之所以把它放进参考实现，是因为这条判定必须是**可机械验证**的：
 * 三档 × 设备状态的期望结果写在 fixture 16 里，两侧实现照同一张表写。
 *
 * 与 fixtures 的边界：本文件只做判定，不做 claim 之后的看护与 fail-closed
 * （那是连接层与产品行为，见契约 §6.2）。
 */

/** 档位：never 只通知 / foreground 默认 / always 只要在线就接管。 */
export const TAKEOVER_MODES = ['never', 'foreground', 'always']

/**
 * 确定性排序：最近与该会话交互的优先；并列取配对更早的；再并列取 id 升序。
 * 排序必须确定，否则"哪台手机接管"会随 Map 迭代顺序漂移，测试也就不可复现。
 */
function rank(devices, sid) {
  return [...devices]
    .filter((d) => d.online === true)
    .sort((a, b) => {
      const ai = a.lastInteractedAt?.[sid] ?? -1
      const bi = b.lastInteractedAt?.[sid] ?? -1
      if (ai !== bi) return bi - ai
      if (a.pairedAt !== b.pairedAt) return a.pairedAt - b.pairedAt
      return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
    })
}

/**
 * @param {object} input
 * @param {'never'|'foreground'|'always'} input.mode - 接管档位
 * @param {string} input.sid - 请求所属会话别名
 * @param {Array<{id:string,online:boolean,foreground:boolean,subscribed:string[],pairedAt:number,lastInteractedAt?:Record<string,number>}>} input.devices
 * @returns {{ claim: boolean, deviceId: string | null, reason: string }}
 */
export function decideTakeover({ mode, sid, devices }) {
  if (!TAKEOVER_MODES.includes(mode)) throw new Error(`未知接管档位: ${mode}`)
  if (mode === 'never') return { claim: false, deviceId: null, reason: 'mode-never' }

  const candidates = mode === 'always'
    ? rank(devices, sid)                                       // 在线即可
    : rank(devices, sid).filter((d) => d.foreground === true && (d.subscribed ?? []).includes(sid))

  if (candidates.length === 0) {
    return { claim: false, deviceId: null, reason: mode === 'always' ? 'no-online-device' : 'no-foreground-subscriber' }
  }
  return { claim: true, deviceId: candidates[0].id, reason: `${mode}-claimed` }
}
