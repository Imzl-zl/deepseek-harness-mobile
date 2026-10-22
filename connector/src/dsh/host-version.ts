/**
 * 宿主运行时的 DSH 版本（`repo.info.dshVersion`）。
 *
 * ## 为什么不能拿构建期常量冒充
 *
 * 连接器的 `package.json` 里锁着 `peerDependencies` 的版本范围（当前 `0.2.1-rc.2`），
 * 但那是**我们编译时对上的那一版**。用户升级 DSH 之后，同一个连接器产物会跑在新宿主上 ——
 * 排错时"手机连的是哪一版 DSH"必须回答**正在跑的那一版**，否则两个版本号会打架。
 *
 * ## 取法（从最真到最兜底）
 *
 * 1. **已加载的宿主包**：`@deepseek-ai/dsh-desktop-host`（`dsh.cmd` 的入口就是它，
 *    `resources/runtime/cli/bin/dsh.cmd` 那一行）—— 用 `createRequire(import.meta.url)`
 *    解析它的 `package.json`。这条路径随宿主升级而变，是运行时真值。
 *    DSH 自己也是这么判"运行时版本"的：`packages/boot/app-boot/src/plugin-compatibility.ts:24`
 *    的 `runtimeVersionOf`（从清单里取 `version`），而不是拿构建期常量。
 * 2. **桌面版的 `runtime.json`**：`<exe 所在目录>/resources/runtime/runtime.json` 里的
 *    `desktopVersion`（本机实测：`0.2.1-rc.2`）。只在桌面发行版里有。
 * 3. 都拿不到 ⇒ `undefined`。**不猜、不填一个看起来合理的版本号**（手机那边显示"未读到"）。
 */
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'

/** 候选宿主包：按"最可能带发行版本"的顺序试。 */
export const HOST_PACKAGES: readonly string[] = [
  '@deepseek-ai/dsh-desktop-host',
  '@deepseek-ai/dsh',
]

/** 读一个包的 manifest 版本；读不到回 `null`（不抛）。 */
function versionOfPackage(name: string, resolve: (specifier: string) => string): string | null {
  try {
    const manifest = JSON.parse(
      readFileSync(resolve(`${name}/package.json`), 'utf8'),
    ) as { version?: unknown }
    return typeof manifest.version === 'string' && manifest.version !== ''
      ? manifest.version
      : null
  } catch {
    return null
  }
}

/** 读桌面版 `runtime.json` 的 `desktopVersion`；读不到回 `null`。 */
function versionOfRuntimeJson(exePath: string): string | null {
  // 本机实测（2026-10-22）：`process.execPath` = `<安装目录>/DeepSeek Harness.exe`，
  // 版本在 `<安装目录>/resources/runtime/primary-runtime/runtime.json` 的
  // `desktopVersion` 字段（`0.2.1-rc.2`）。两种布局都试 —— 发行版之间挪过目录。
  const roots = [
    join(dirname(exePath), 'resources', 'runtime', 'primary-runtime'),
    join(dirname(exePath), 'resources', 'runtime'),
  ]
  for (const root of roots) {
    try {
      const runtime = JSON.parse(
        readFileSync(join(root, 'runtime.json'), 'utf8'),
      ) as { desktopVersion?: unknown }
      if (
        typeof runtime.desktopVersion === 'string' &&
        runtime.desktopVersion !== ''
      ) {
        return runtime.desktopVersion
      }
    } catch {
      // 下一个布局
    }
  }
  return null
}

/**
 * 宿主运行时的 DSH 版本；`undefined` = 这一层拿不到（调用方**不报这个字段**）。
 *
 * [resolve] 与 [exePath] 是给用例的缝：真机上分别是 `createRequire(import.meta.url).resolve`
 * 与 `process.execPath`。
 */
export function hostDshVersion(
  resolve: (specifier: string) => string = createRequire(import.meta.url).resolve,
  exePath: string = process.execPath,
): string | undefined {
  for (const name of HOST_PACKAGES) {
    const version = versionOfPackage(name, resolve)
    if (version !== null) return version
  }
  return versionOfRuntimeJson(exePath) ?? undefined
}
