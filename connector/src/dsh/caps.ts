/**
 * 能力位：由「服务是否存在」决定（契约 §7）。手机据此置灰按钮，不用错误码试探。
 *
 * 两个必须避开的坑（都来自 cordis 的服务解析语义）：
 *
 * - **裸读 `ctx.sessionController` 会抛异常**，不是返回 undefined
 *   （`vendor/cordis/src/reflect.ts:144` 与 `:159-161`），所以能力位一律走 `ctx.get`。
 * - **`inject = [...]` 里写了不存在的服务，插件不会被激活** —— 实测在 profile 里启动时
 *   DSH 会明确报出来：
 *
 *   ```text
 *   dsh: warning: 1 entry did not activate
 *   dsh-mobile-connector (@dsh-mobile/connector): pending (waiting for service: sessionController)
 *   ```
 *
 *   所以它**不是静默降级**（早先版本的注释说它"无异常、无日志"，那是错的，已按实测改正）。
 *   但仍然值得只把**必需**服务写进 `inject`：一行 warning 容易被淹没，
 *   而一个连会话都拿不到的桥接本来也没有存在意义。
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
 * 存在的意义是让「插件没激活」这件事在**插件自己的日志里**也留一条 ——
 * DSH 那行 `pending (waiting for service: ...)` 是有的（实测），但它混在启动日志里容易被淹没。
 *
 * @returns 缺失的必需服务键；空数组表示齐备。
 */
export function missingRequiredServices(ctx: Context): readonly string[] {
  return REQUIRED_SERVICES.filter((name) => !present(ctx, name))
}
