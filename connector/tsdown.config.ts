/**
 * 构建配置。
 *
 * `outDir` 与扩展名必须与 package.json 的 `main` / `exports` 一致:
 * tsdown 在 `platform: 'node'` 时 `fixedExtension` 默认 true,产物会是 `.mjs` / `.d.mts`,
 * 与文档声明的 `lib/index.js` 对不上(装上后入口不存在)。这里用 `outExtensions` 覆盖。
 * 依据:tsdown 自己的类型声明 node_modules/tsdown/dist/types-*.d.mts 的
 * `fixedExtension` / `outExtensions` 注释。
 */
import { defineConfig } from 'tsdown'

export default defineConfig({
  entry: ['src/index.ts'],
  outDir: 'lib',
  format: 'esm',
  platform: 'node',
  dts: true,
  clean: true,
  outExtensions: () => ({ js: '.js', dts: '.d.ts' }),
})
