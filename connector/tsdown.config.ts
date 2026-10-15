/**
 * 构建配置。
 *
 * **只有 Node 一个入口**：`src/index.ts` → `lib/index.js`。
 *
 * 浏览器半侧（DSH Web GUI 里的插件面板）**不经过这里** —— 它是包根手写的
 * `client.js`（`window.__ModuleLoader__.load({id, factory})` 格式），
 * 由 `exports['./client']` 直接指向。理由见那个文件的头注释：DSH 的 client bundle
 * 必须是闭包工厂格式，而产出它的共享 tsdown 预设在 DSH 仓库里、依赖 lightningcss
 * 与仓库内相对路径，我们这个独立工程用不了。
 *
 * `outDir` 与扩展名必须与 package.json 的 `main` / `exports` 一致:
 * tsdown 在 `platform: 'node'` 时 `fixedExtension` 默认 true,产物会是 `.mjs` / `.d.mts`,
 * 与文档声明的 `lib/index.js` 对不上(装上后入口不存在)。这里用 `outExtensions` 覆盖。
 */
import { defineConfig } from 'tsdown'

export default defineConfig({
  entry: { index: 'src/index.ts' },
  outDir: 'lib',
  format: 'esm',
  platform: 'node',
  dts: true,
  clean: true,
  outExtensions: () => ({ js: '.js', dts: '.d.ts' }),
})
