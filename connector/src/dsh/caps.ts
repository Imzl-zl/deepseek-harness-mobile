/**
 * 能力位：由「服务是否存在」决定（契约 §7）。手机据此置灰按钮，不用错误码试探。
 *
 * 两个必须避开的坑（都来自 cordis 的服务解析语义）：
 *
 * - **裸读 `ctx.sessionController` 会抛异常**，不是返回 undefined
 *   （`vendor/cordis/src/reflect.ts:144` 与 `:159-161`），所以能力位一律走 `ctx.get`。
 * - **`inject = [...]` 里写了不存在的服务 = fiber 永远 PENDING**，无异常、无日志、
 *   无 UI 报错（`vendor/cordis/src/fiber.ts:611-623`）。所以只有**必需**服务才写进
 *   `inject`，可选能力一律在这里 `ctx.get` 读出来；否则一个拼错的服务名会让整个插件
 *   静默地永不加载。
 *
 * `ctx.get('拼错的键')` 同样静默返回 undefined（`reflect.ts:237-243`），所以本文件把
 * 服务键集中成常量，供 `index.ts` 的 `inject` 与能力位共用一处定义。
 */
import type { Context } from '@deepseek-ai/cordis'

/**
 * 本插件**必需**的服务键 —— 缺任何一个，桥接都没有存在意义。
 * `index.ts` 的 `inject` 直接用这一份，避免两处各写一遍后拼错。
 */
export const REQUIRED_SERVICES = ['sessionController', 'storageDomain'] as const

/**
 * **可选**能力。缺了只是对应功能置灰，不该让插件不加载，所以**不写进 `inject`**。
 */
export const OPTIONAL_SERVICES = [
  'approval',
  'userQuestions',
  'jobs',
  'subagents',
  'settings',
  'credentials',
] as const

/** 通道对外公布的能力位。 */
export interface Caps {
  /** 会话流与历史。必需服务缺失时插件不会加载，所以这里通常为 true。 */
  sessions: boolean
  /** 增量缓冲与幂等表落盘；缺它保证不了 I7 / I8。 */
  storage: boolean
  /** 审批接管。 */
  approval: boolean
  /** 提问（含计划审查）。 */
  questions: boolean
  /** 后台任务列表与停止。 */
  jobs: boolean
  /** 子代理树。 */
  subagents: boolean
  /** 设置读写面。 */
  settings: boolean
  /** 凭据写面（只有写面，见 `settings.ts`）。 */
  credentials: boolean
}

const present = (ctx: Context, name: string): boolean => ctx.get(name) !== undefined

export function readCaps(ctx: Context): Caps {
  return {
    sessions: present(ctx, 'sessionController'),
    storage: present(ctx, 'storageDomain'),
    approval: present(ctx, 'approval'),
    questions: present(ctx, 'userQuestions'),
    jobs: present(ctx, 'jobs'),
    subagents: present(ctx, 'subagents'),
    settings: present(ctx, 'settings'),
    credentials: present(ctx, 'credentials'),
  }
}

/**
 * 启动时自报健康：列出**必需**服务的缺失情况。
 *
 * 存在的意义是把 `inject` 那个静默降级口子变得可见 —— 服务名拼错时 fiber 会永远停在
 * PENDING，插件一个日志都不会打；调用方拿这个结果主动记录/上报，就能看见。
 *
 * @returns 缺失的必需服务键；空数组表示齐备。
 */
export function missingRequiredServices(ctx: Context): readonly string[] {
  return REQUIRED_SERVICES.filter((name) => !present(ctx, name))
}
