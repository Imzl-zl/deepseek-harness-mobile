/**
 * 起传输时的**容忍判据**：哪两种缺席是"配置里本来就允许的"，其余一律照旧吵。
 *
 * ## 两条规则，各有出处
 *
 * 1. **凭据里还没有连接器令牌** → 只让中转通道起不来（不再拒绝挂载）。
 *    理由很硬：令牌可以在面板里删，而管理面（`/api/dsh-mobile/*`）挂在
 *    `start-transport` **之后** —— 一旦这条失败让整个 mount 失败，"删掉令牌"这个
 *    做出来的动作就把人锁在门外：重启后连把令牌贴回去的界面都打不开。
 *    见 `.agents/notes/implemented/2026-10-29-panel-connection-card.md` 的「无令牌可挂载」。
 * 2. **`listenPort = 0`** → 用户明说"不监听"（`config.ts:26-29`），不是失败，
 *    也不该被当成"起成功了"（所以是"不调"，不是"调了再看"）。
 *
 * 别的失败（坏地址、端口被占、宿主抛出来的东西）**整体抛出**：静默半挂的插件会让
 * 手机端一直连不上而电脑侧没有线索。
 *
 * ## 为什么单开一层
 *
 * 这条规则当时的证明只有一次隔离实例手工 e2e（面板删令牌 → 重启 → 面板仍能打开），
 * 而它恰恰是**最容易被人"顺手收紧"**的那类代码：把 `instanceof RelayTokenError`
 * 放宽成 `catch {}`，坏地址与端口被占就一起被吞掉，门禁却全绿。所以判据与起停
 * 顺序都放在这里，由 `tests/transport-startup.test.ts` 钉住；装配层只提供端口。
 * 取舍见 `.agents/notes/implemented/2026-10-29-assembly-regression-net.md`。
 */
import { RelayTokenError } from '../dsh/relay-token.js'

/**
 * 中转起不来时，这个失败算不算"配置里本来就允许的缺席"。
 *
 * **只认 `RelayTokenError`**（`readRelayToken` 在记录缺失/形状不对时抛它）。
 * 不用"错误信息里带没带令牌字样"或 `instanceof Error` 这类更宽的判据：
 * 前者按文案判、后者等于全放过。
 */
export function toleratesRelayStartFailure(error: unknown): boolean {
  return error instanceof RelayTokenError
}

/** 起传输需要的东西（都是装配层现成的函数，本模块不认识连接细节）。 */
export interface StartupPorts {
  /** 起中转通道。失败抛出（含 `RelayTokenError`）。 */
  startRelay(): Promise<void>
  /** 起直连监听面。失败抛出（端口被占）。 */
  startDirect(): Promise<void>
  /** 直连端口：`0` = 配置明说"不监听"。**每次调用现读**（面板能热改）。 */
  listenPort(): number
  /** 容忍时的留痕口（日志 + 「连接」卡的原因）。 */
  onTolerated(error: unknown): void
}

/**
 * 建"起传输"这一步。
 *
 * 顺序是**中转 → 直连**，而且中转被容忍之后直连照常起：两条通道各自独立
 * （见 `channels.ts` 文件头），缺令牌只让"经中转"这条路不通，"同一网络直连"
 * 反而是那条时候唯一能用的路 —— 先起成功的那条，用户就还有入口。
 */
export function createTransportStarter(ports: StartupPorts): () => Promise<void> {
  return async () => {
    await ports.startRelay().catch((error: unknown) => {
      // 唯一的例外在这里（见文件头两条）。注意顺序：判据不通过时**原样抛出**，
      // 于是下面那行不会执行 —— 真故障不该继续起下一条通道（半挂比不挂更难查）。
      if (!toleratesRelayStartFailure(error)) throw error
      ports.onTolerated(error)
    })
    if (ports.listenPort() !== 0) await ports.startDirect()
  }
}
