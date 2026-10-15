/**
 * 设备管理面的三个写操作：**停用/启用**、**删除（多选）**、**按状态删**。
 *
 * ## 为什么从 `index.ts` 里抽出来
 *
 * 这三件事装着管理面**全部的不变量**：停用只标 `revokedAt`、启用把它从行上拿掉、
 * 删除要不要跳过在线的。它们原先内联在 `start-transport` 的一串闭包里，于是
 * 「解禁到底有没有把 `revokedAt` 拿掉」「按状态清到底有没有跳过在线」只能靠读
 * 代码确认，没有任何单测能钉 —— 而这两条恰恰是 2026-10-15 事故（31 条记录被
 * 硬删）之后最不能错的地方。抽成一个不碰 cordis 的模块后，用一个内存设备表就能
 * 逐条断言。见 `.agents/notes/proposed/2026-10-15-device-identity-and-reconnect-discussion.md`；
 * 落地后的取舍（为何是一对布尔端点、为何删掉 offline scope、为何在线豁免按形状生效、
 * 被否方案）见 `.agents/notes/implemented/2026-10-15-device-admin-face-dsh-house-style.md`。
 *
 * ## 三条不变量
 *
 * 1. **停用是终态，启用是解禁**。`revokedAt` 存在即已停用 —— `presence.pairedAtOf`、
 *    `peerOf`、`publishDevices`、`sessionBuffer` 四处都按 `revokedAt !== undefined`
 *    判失效，所以"启用"必须把**键**从行上去掉，而不是写一个 `undefined`：
 *    域表的 `put` 不重新过 zod（`packages/storage/storage-domain/src/domain.ts:307-313`
 *    直接存对象、读时才校验），写 `undefined` 会让键留着、值悬空，只能靠读取处
 *    `!== undefined` 的判断碰巧救回来。解构剔除才是"这行没有被停用过"的如实表达。
 * 2. **在线豁免属于按状态批量，不属于显式点名的 id**（全文最重要的一条）。
 *    多选与按状态走的是同一条 `purge`，差别只在"要不要跳过在线的"这个开关，
 *    而它**由形状决定**：
 *    - `removeScope(scope)`（按状态清）**绝不碰在线的**。它的人口是**隐式**的
 *      （一整类），而 2026-10-15 事故的危险正来自隐式人口。注意"跳过在线"
 *      保护不了当时那台 —— 用户的手机是**离线**态，所以真正的修法是把 `offline`
 *      scope 删掉（见 `routes.ts`），不是把豁免做得更严。
 *    - `remove(devIds)`（显式）**可以删在线的**。操作者指着某一行、或者逐个勾的，
 *      意图无歧义。真实场景：手机丢了还在线，要立刻弄死它，为此先"让那台手机
 *      断开连接"是荒谬的。**悄悄收回一项既有能力比危险更糟** —— 改这条之前，
 *      单台删除一直是允许删在线的。
 *    - 于是 `skippedOnline` 对显式删除恒为 0（语义没变，只是不再触发）。
 * 3. **改完要重发名册**。中转按名册认设备（契约 §8.2 / I7），不重发的话
 *    停用的行还换得到票、删掉的行也还换得到票。停用/启用**每次**都发
 *    （整行被改写，名册必须跟着变）；删除只在**真删过**时才发 ——
 *    一台都没删就不打扰中转。
 */
import type { DeviceRecord } from '../store/index.js'

/**
 * `core` 域 `devices` 表在本模块用到的形状。
 *
 * 与 `KvTable<string, DeviceRecord>`
 * （`packages/storage/storage-domain/src/domain.ts:42-90`）结构一致 ——
 * `delete` 就在那个接口上，所以装配层 `core.table('devices')` 可以直接赋给这里，
 * 不需要 cast。这里重声明只是为了让本模块不依赖"域是怎么开出来的"。
 */
export interface DeviceTablePort {
  get(key: string): DeviceRecord | undefined
  keys(): Iterable<string>
  put(key: string, value: DeviceRecord): Promise<void>
  delete(key: string): Promise<boolean>
}

/** 一次删除的结果：真删了几台，以及**因在线而跳过**几台。 */
export interface PurgeResult {
  removed: number
  skippedOnline: number
}

export interface DeviceAdmin {
  /** 停用（`enabled: false`）或解禁（`enabled: true`）一台设备。 */
  setEnabled(devId: string, enabled: boolean): Promise<void>
  /** 真删除指定的几台。单台就是长度 1 的数组。 */
  remove(devIds: readonly string[]): Promise<PurgeResult>
  /** 按状态批量真删除。 */
  removeScope(scope: 'revoked' | 'all'): Promise<PurgeResult>
}

export interface DeviceAdminDeps {
  /** 设备表。装配早期是 null，写操作只可能发生在 `open-store` 之后。 */
  tableOf: () => DeviceTablePort | null
  /** 此刻在线的设备 id 集合（`presence` 的 live 表，重启即空）。 */
  onlineIds: () => ReadonlySet<string>
  /** 名册重发（§8.2 / I7）。 */
  publish: () => Promise<void>
}

/**
 * 造出管理面的三个写操作。
 *
 * 三个方法都**先取表再判空**：`devices 表尚未就绪` 只可能是装配顺序写错，
 * 而不是"还没准备好"，所以它是抛出来的断言，不是一条静默返回。
 */
export function createDeviceAdmin(deps: DeviceAdminDeps): DeviceAdmin {
  /**
   * 删除的**唯一**实现：多选与按状态共用，于是"跳过在线"的判据只有一处。
   *
   * `skippedOnline` 只数**本来要删、因在线而没删**的行：先判匹配再判在线。
   * 反过来写会把"这行不在筛选范围里、只是恰好在线"也算成跳过，界面就会报一个
   * 比真实情况大的数字（用户按"清掉已停用"却看到"跳过 3 台在线"而其中只有 1 台
   * 本来会被删）。
   *
   * @param matches - 这一行在不在删除范围里
   * @param skipOnline - **按状态批量才 true**（见文件头不变量 2）：显式点名的 id
   *   是操作者的明确目标，可以删在线的。
   */
  const purge = async (
    matches: (id: string, record: DeviceRecord) => boolean,
    skipOnline: boolean,
  ): Promise<PurgeResult> => {
    const table = deps.tableOf()
    if (table === null) throw new Error('devices 表尚未就绪：装配顺序有误')
    const online = deps.onlineIds()
    let removed = 0
    let skippedOnline = 0
    for (const id of table.keys()) {
      const record = table.get(id)
      if (record === undefined) continue
      if (!matches(id, record)) continue
      // **按状态批量时，在线的绝不删**：那台手机正在用。显式点名不跳。
      if (skipOnline && online.has(id)) {
        skippedOnline += 1
        continue
      }
      await table.delete(id)
      removed += 1
    }
    // 一台都没删就不重发：无事可报，不打扰中转。删过才发 —— 删掉的行不该再报给中转。
    if (removed > 0) await deps.publish()
    return { removed, skippedOnline }
  }

  return {
    async setEnabled(devId, enabled) {
      const table = deps.tableOf()
      if (table === null) throw new Error('devices 表尚未就绪：装配顺序有误')
      const record = table.get(devId)
      // 不认识的设备 id 不当成功：那会让页面显示"已停用"而实际上什么都没发生。
      if (record === undefined) throw new Error(`未知设备：${devId}`)
      if (enabled) {
        // 解禁：把 `revokedAt` 从行上**拿掉**（解构剔除，不是写 undefined）——
        // 理由见文件头不变量 1。
        const { revokedAt: _unset, ...rest } = record
        await table.put(devId, rest)
      } else {
        // 停用：**只标 revokedAt，不删行**。删了就没有"这台曾经配对过"的记录，
        // 而 `peerOf` / `presence.pairedAtOf` 都按 `revokedAt !== undefined` 判失效
        // —— 标记即停用（契约 §5.7 `devices.list` 那行的原文："吊销 = 不再把该设备
        // 报进名册 + 本地标 `revokedAt`"）。
        await table.put(devId, { ...record, revokedAt: Date.now() })
      }
      // 名册要重新发布：停用要摘掉、解禁要接回（中转按名册认设备）。
      await deps.publish()
    },

    // **显式**：操作者指着某一行 / 逐个勾的，意图无歧义 —— 不跳过在线的
    // （不变量 2）。手机丢了还在线，要立刻弄死它。
    remove: (devIds) => {
      const wanted = new Set(devIds)
      return purge((id) => wanted.has(id), false)
    },

    // **按状态**：人口是隐式的一整类，在线的绝不碰（不变量 2）。
    removeScope: (scope) =>
      purge((_id, record) => (scope === 'revoked' ? record.revokedAt !== undefined : true), true),
  }
}
