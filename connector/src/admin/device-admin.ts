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
 * 2. **删除只允许作用在已停用的行上**（全文最重要的一条）。
 *    多选与按状态走的是同一条 `purge`，三档规则：
 *    - `remove(devIds)`（显式点名）：**没停用的一律拒**，整批都不删
 *      （`refusedActive` 原样回给界面）。手机唯一能"知道被移除"的通道是换票 401
 *      带原因，而那只在**行还在名册里**时成立 —— 硬删活跃行会把撤销记录一起抹掉，
 *      那台手机只会拿到 `device-unknown`（与"名册还没同步"同一个症状）并一直重试。
 *      「手机丢了还在线，要立刻弄死它」现在是**停用**的事：停用会立刻收连接，
 *      删除只负责清理。取舍见 `implemented/2026-10-30-revoke-then-purge.md`。
 *    - `removeScope('revoked')`（清掉已停用）**绝不碰在线的**。它的人口是**隐式**的
 *      （一整类），而 2026-10-15 事故的危险正来自隐式人口。注意"跳过在线"
 *      保护不了当时那台 —— 用户的手机是**离线**态，所以真正的修法是把 `offline`
 *      scope 删掉（见 `routes.ts`），不是把豁免做得更严。
 *    - `removeScope('all')`（重置这台电脑）是唯一还能删"未停用但离线"的口子：
 *      那些手机会一直重试到重新配对，界面上有单独的、写明后果的确认框。
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
  /**
   * **没停用就被点名删除**的设备（显式删除时）。非空 = 这一批**一台都没删**。
   *
   * 为什么拒绝：手机唯一能"知道被移除"的通道是换票 401 带原因，而那只在
   * **行还在名册里**时成立。硬删一行 = 连撤销记录一起删掉，那台手机只会拿到
   * `device-unknown`（与"名册还没同步"同一个症状）→ 一直重试、永远回不到配对页。
   * 正确顺序是**先停用（它立刻下线、手机拿到终态）→ 再删除**（清理）。
   */
  refusedActive: readonly string[]
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
  /**
   * 停掉这些设备**已经建立的连接**（装配层给：`devId → Connection.stop()`）。
   *
   * 为什么必须有：独占 1:1 的占用位是"在线且未吊销"，所以停用/删除一行的同时
   * **必须真的把那条连接收掉** —— 否则它的 socket 还活着、还在收发，而占用位
   * 已经释放，下一台手机就会被放进来（两台同时在服务）。
   * 这一步也让面板的「接管」名副其实：接管 = 停用占用者 = 它立刻下线。
   */
  disconnect?: (devIds: readonly string[]) => void
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
    refuseActive: boolean,
  ): Promise<PurgeResult> => {
    const table = deps.tableOf()
    if (table === null) throw new Error('devices 表尚未就绪：装配顺序有误')
    const online = deps.onlineIds()
    // **显式删除先整批判一遍**（全有或全无）：只要有没停用的行，就一台都不删 ——
    // 半成功会让操作者以为"删了的那几台手机知道了"，而它们其实拿不到任何终态信号。
    if (refuseActive) {
      const refused = [...table.keys()].filter((id) => {
        const record = table.get(id)
        return record !== undefined && matches(id, record) && record.revokedAt === undefined
      })
      if (refused.length > 0) {
        return { removed: 0, skippedOnline: 0, refusedActive: refused }
      }
    }
    let removed = 0
    let skippedOnline = 0
    const deleted: string[] = []
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
      deleted.push(id)
      removed += 1
    }
    // 行没了 ⇒ 那台设备的连接也必须收掉（占用位是"在线且未吊销"，
    // 不收就会出现"占用位已释放、旧 socket 还在收发"）。
    if (deleted.length > 0) deps.disconnect?.(deleted)
    // 一台都没删就不重发：无事可报，不打扰中转。删过才发 —— 删掉的行不该再报给中转。
    if (removed > 0) await deps.publish()
    return { removed, skippedOnline, refusedActive: [] }
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
        // 停用 = 立刻下线（见 `disconnect` 的说明）：占用位随"未吊销"一起消失，
        // 而那条连接不能还活着。
        deps.disconnect?.([devId])
      }
      // 名册要重新发布：停用要摘掉、解禁要接回（中转按名册认设备）。
      await deps.publish()
    },

    // **显式**：处理器指着某一行 / 逐个勾的。**只允许删已停用的行**
    // （不变量 2 改写：先停用再删除）。「手机丢了还在线，要立刻弄死它」现在是
    // 停用的事 —— 停用会立刻收掉那条连接，而删除只负责清理记录。
    remove: (devIds) => {
      const wanted = new Set(devIds)
      return purge((id) => wanted.has(id), false, true)
    },

    // **按状态**：人口是隐式的一整类，在线的绝不碰（不变量 2）。
    // `revoked` 是清理的唯一常规入口；`all` 是"重置这台电脑"，会连还在用的
    // 离线设备一起删（那些手机只会重试到重新配对）—— 界面上有单独的确认框。
    removeScope: (scope) =>
      purge((_id, record) => (scope === 'revoked' ? record.revokedAt !== undefined : true), true, false),
  }
}
