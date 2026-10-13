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
 *
 * `credentials` 在这里而不是"可选"里：电脑侧**身份种子**就存在凭据 seam 的记录面
 * （`dsh/identity.ts`），拿不到它连握手都构造不出来。它由 `@deepseek-ai/dsh-base` 提供
 * （`packages/bundle/base/cordis.patch.yml:117-118` 注册 `@deepseek-ai/dsh-credentials-local`），
 * 而 base 已经是任何可跑 profile 的前提（`storageDomain` 同理）。
 */
export const REQUIRED_SERVICES = ['sessionController', 'storageDomain', 'credentials'] as const

/**
 * **可选**能力。缺了只是对应功能置灰，不该让插件不加载，所以**不写进 `inject`**。
 *
 * 这份清单还是**服务键的登记处**：`dsh/` 下任何 `ctx.get('<键>')` 都必须在这里出现过，
 * 否则 `tests/layering.test.ts` 的 `service-key-registered` 会红 —— 那条规则盯的是
 * "拼错一个键就是一个永远 false 的能力位，且没有任何报错"。
 */
export const OPTIONAL_SERVICES = [
  'approval',
  'userQuestions',
  'jobs',
  'subagents',
  'settings',
  // 提问面的两个只读依赖（`dsh/questions.ts`）：`agents` 用来把会话 id 换成 live root agent，
  // `sessionProjections` 用来读 `userQuestions` 投影。两者都**不**决定能力位
  // （能力位看 `userQuestions`），缺了只是提问应答回 not-pending。
  'agents',
  'sessionProjections',
  // 模型面（`dsh/models.ts`）：`sessionController` 发目录（`@Remote('modelCatalog')`），
  // 另外两个键用来读 `modelSelection` 投影。三者都**不**决定能力位 ——
  // 缺了只是 `session.modelCatalog` 不出现、`session.list` 的行里没有 `model` 字段。
  'sessionController',
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
  /** 凭据面（手机侧只有设置页的密钥写面）。**必需服务**，所以通常为 true。 */
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
