/**
 * 独占准入（1:1）：一台电脑同一时刻只服务**一台有效设备**。
 *
 * ## 它回答的唯一问题
 *
 * "这台设备现在能不能进来？" 不能的话，占用者是谁（说给手机听）。
 * 判据只有一个：`presence.serving()` —— 已经在线、已配对且未吊销的那一条。
 *
 * ## 三条硬约束
 *
 * 1. **不另立第二份状态**。占用位就是 `presence` 的在线记录：
 *    停用（`revokedAt`）与已删除的行被 `presence.devices()` 滤掉，自然不占位
 *    （否则一台被停用的旧手机在名册里留着就能永久挡住新手机 —— 占坑 DoS）；
 *    幽灵占用（旧手机掉线未 FIN）靠 keepalive 的半开判定收口，这里**不加定时器**。
 * 2. **同一 `devId` 的重连必须放行**。换网重连靠中转的 `replaced` 语义
 *    （`relay/src/server.ts` 对同一 `(connectorId, deviceId)` 先关旧再准入），
 *    连接器在这里再拦一道就会"换网把自己挡在门外"。所以判据是"**别的** devId"。
 * 3. **只做判定，不做抢占**。拒绝就是拒绝（`device/busy`），不踢占用者、
 *    不排队、不自动挑一台 —— 接管是操作者在面板上的显式动作
 *    （走 `admin/device-admin.ts` 既有的停用写路径）。
 *
 * 取舍与被否方案见 `.agents/notes/implemented/2026-10-30-exclusive-and-switch.md`。
 */

import type { DevicePresence } from './presence.js'

/** 准入判定面。握手驱动只认识这一个函数（`protocol/handshake-driver.ts` 的 `occupantOf`）。 */
export interface ExclusiveAdmission {
  /**
   * 这台设备能不能进来。`undefined` = 放行；
   * 否则返回**占用者的展示名**（进 `device/busy` 的关闭理由，契约 §4.1）。
   */
  occupantOf(devId: string): string | undefined
}

export interface ExclusiveAdmissionOptions {
  /** 占用位的事实来源（挂载级的那一份 `presence`）。 */
  presence: Pick<DevicePresence, 'serving'>
  /** 设备在名册里的名字（展示值；取不到就退回短码）。 */
  nameOf(devId: string): string | undefined
}

/**
 * 设备 id 的短码：前 6 + 后 4。
 *
 * 与手机侧区分同名电脑的做法同一种（Syncthing 显示 Device ID 的方式）：
 * 名字会重名、可改，短码不会。**只用于展示**，从不参与任何判据。
 */
export function shortIdOf(id: string): string {
  return id.length >= 10 ? `${id.slice(0, 6)}…${id.slice(-4)}` : id
}

export function createExclusiveAdmission(
  options: ExclusiveAdmissionOptions,
): ExclusiveAdmission {
  return {
    occupantOf(devId) {
      const serving = options.presence.serving()
      // **同一台设备的重连照旧放行**（见文件头约束 2）。
      if (serving === undefined || serving.id === devId) return undefined
      const name = options.nameOf(serving.id)
      return name === undefined || name === '' ? shortIdOf(serving.id) : name
    },
  }
}
