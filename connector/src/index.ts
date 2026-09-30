/**
 * 插件入口:装配、发布服务、dispose。
 *
 * 生命周期见 docs/subsystems/connector-and-relay.md §1.3;导出形式见 DSH
 * packages/preset/agent-preset/skills/cordis-plugin-development/references/host-plugin.md:47-54
 * (`export function apply(ctx, config)`,可配 `export const Config` / `export const inject`)。
 *
 * 当前是第 2 步的骨架:只装配配置。适配层(src/dsh/)、传输(src/transport/)与
 * 存储(src/store/)按 docs/cookbook/channel-bootstrap.md 的第 3–4 步接入。
 *
 * 工程形态与版本策略见 .agents/notes/implemented/2026-10-01-connector-workspace-shape.md
 */
import type { Context } from '@deepseek-ai/cordis'
import type { ConnectorConfig } from './config.js'

export { Config } from './config.js'

// `inject` 在第 4 步接适配层时补:要声明的服务键必须以 DSH 源码为准,
// 现在写等于猜。对照表见 docs/subsystems/remote-channel.md §2.2。

/** 装配插件。所有注册都走 ctx.effect / ctx.on,由 ctx 在 dispose 时回收。 */
export function apply(ctx: Context, config: ConnectorConfig): void {
  ctx.effect(() => {
    ctx.logger.info('dsh-mobile connector mounted (骨架:store / transport / dsh 适配层未接入)')
    return () => {
      ctx.logger.info('dsh-mobile connector disposed')
    }
  })

  void config
}
