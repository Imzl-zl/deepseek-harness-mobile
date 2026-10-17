/**
 * 管理面的装配：只注册 **RPC 端点**（`ctx.connection.fetch.register`）。
 *
 * ## 为什么没有"页面"这一路
 *
 * 2026-10-15 做过一版独立网页（`ctx.webServer.register({kind:'prefix', path:'/dsh-mobile'})`
 * + 内联 HTML），**已删**。删的理由：
 *
 * 1. 它与插件面板功能完全重复（状态 / 出码 / 停用启用删除），留着的"兜底"说法
 *    （扫码时 DSH 界面未必是全屏那一个）很弱，而代价是两套 UI 两个维护点 ——
 *    正是这套代码一直在避的"两处会漂移"。
 * 2. **它并不额外起进程**：`webServer.register` 是往 DSH 已有的 web server 上挂
 *    前缀路由，RPC 与 client bundle 也同在同一个 server 上。所以"独立网页"从来
 *    只是"同一个 server 上的第二条路由"，不是独立的服务 —— 留它没有隔离收益。
 * 3. 插件往 DSH 界面里贡献 UI 的机制是 **Slots**，入口 `plugins.bundle.config`
 *    （`client.js`）。以 `experimental/inspector` 的自起路由当先例是**以偏概全**：
 *    那是个自起路由的调试工具，不是插件 UI 的正道。
 *
 * ## 认证
 *
 * 各端点走在 Connection 的 `/api` 共享通道上，准入**白拿**：
 * Host/Origin 栅栏 + 浏览器 cookie（`rpc-host.ts:107-117`）。
 * 所以这里不自己实现令牌 —— 自己实现只会更弱，且多一处"两个认证答案"。
 *
 * ## 只有一个服务是可选的
 *
 * `connection` 缺席（这个部署没有 Web UI）就整体不挂：管理面本来就只服务于
 * 浏览器里的操作者。
 */
import type { Context } from '@deepseek-ai/cordis'

import type { Caps } from '../dsh/caps.js'
import { createAdminRoutes, type AdminDeps, type ConnectionFetchRoute } from './routes.js'

/**
 * 装配层要给的一切。**就是 {@link AdminDeps} 加一个可选的日志出口** ——
 * 两处各抄一份字段清单，迟早会漂（这次改端点形状时就是两处一起改的）。
 */
export interface AdminMountDeps extends AdminDeps {
  log?: (message: string, detail?: unknown) => void
}

/** `ctx.connection` 只取本模块用到的方法。 */
interface ConnectionService {
  fetch: { register(route: ConnectionFetchRoute): () => Promise<void> }
}

/**
 * 挂管理面的 RPC。
 *
 * ## 为什么不用 `ctx.effect`
 *
 * 本插件的装配是 `mount(buildSteps(...))`（`lifecycle.ts` 的引擎），
 * `start-transport` 的 `run()` 是**异步**的 —— 而 `apply()` 里那个
 * `ctx.effect(() => { const started = mount(...)… })` 的 execute 在 `mount()`
 * 返回 Promise 时就已结束。此时再调 `ctx.effect` 挂上去的清理会**静默失效**
 * （fiber 已走过那个阶段），症状就是路由 404 而没有任何报错。
 *
 * 所以这里**同步返回 disposer**，由 `start-transport` 的 `undo()` 与 abort
 * 监听清理 —— 与同一步里的 `unregisterPairingCommand` 同一个模式。
 */
export function mountAdminFace(ctx: Context, deps: AdminMountDeps): (() => void) | undefined {
  const connection = ctx.get('connection') as ConnectionService | undefined
  if (connection === undefined) {
    // `ctx.logger` 的输出到不了 CLI 的 stdout（实测，见 `tools.md` 的 Pitfalls），
    // 而"管理面没挂上"的症状是端点 404、没有任何报错 —— 所以这里必须用
    // **能出来的那个出口**，否则下次排查还是从零开始。
    console.error('[dsh-mobile] 管理面 RPC 未挂：connection 服务缺席（这个部署没有 Web UI）')
    deps.log?.('管理面未挂：connection 服务不在')
    return undefined
  }

  const disposers: Array<() => unknown> = []
  // `deps` 结构上就是 `AdminDeps`（`AdminMountDeps extends AdminDeps`），直接交给路由层。
  for (const route of createAdminRoutes(deps)) {
    // `register` **同步**返回 disposer，而那个 disposer 返回 Promise
    // （`rpc.ts:162`）——cordis 只认同步 disposer，所以包一层收起来。
    const disposeRoute = connection.fetch.register(route)
    disposers.push(() => void disposeRoute())
  }
  console.error('[dsh-mobile] 管理面 RPC 已挂：/api/dsh-mobile/{status,pair,transport,devices/enabled,devices/remove}')

  return () => {
    // 反序清：后注册的先摘，避免摘的过程中还有请求打到一个半拆的路由。
    for (const dispose of disposers.reverse()) dispose()
  }
}
