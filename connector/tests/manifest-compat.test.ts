/**
 * `engines.dsh` 的上界必须写成 `<X.Y.Z-0`，不能写成 `<X.Y.Z`。
 *
 * 判据是 `semver.satisfies(runtime, range, { includePrerelease: true })`
 * （`packages/boot/app-boot/src/plugin-compatibility.ts:52`）。开了 `includePrerelease`
 * 之后 `0.2.2-alpha.2 < 0.2.2` 成立，于是 `<0.2.2` 会放行**整条 0.2.2 预发布线** ——
 * 恰好是 `docs/upgrade-guide/v0.2.2-alpha.2/` 那批破坏所在的区间；而等到 `0.2.2`
 * 正式版反而被拒。`<0.2.2-0` 才是「只支持 0.2.1 这条线」的写法：`0.2.2-0` 是 0.2.2
 * 全部预发布的下界，排他上界把它连同其后每一个预发布一起挡在门外。
 *
 * 取舍与代价见 `.agents/notes/implemented/2026-11-05-connector-engines-upper-bound.md`。
 * 「为什么两条宿主线各发一个版本、而不是放宽这一条范围」见
 * `.agents/notes/implemented/2026-11-05-dual-track-host-version-lines.md`。
 */
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { createRequire } from "node:module"
import { fileURLToPath } from "node:url"
import { test } from "node:test"

/** `semver` 不带类型声明；这里只借三个函数，签名按 semver 7 的实际行为写。 */
const semver = createRequire(import.meta.url)("semver") as {
  parse: (version: string) => { major: number; minor: number; patch: number } | null
  satisfies: (version: string, range: string, options: { includePrerelease: boolean }) => boolean
  minVersion: (range: string) => { version: string } | null
}

interface Manifest {
  engines?: { dsh?: string }
  peerDependencies?: Record<string, string>
  devDependencies?: Record<string, string>
}

const manifest = JSON.parse(
  readFileSync(fileURLToPath(new URL("../package.json", import.meta.url)), "utf8"),
) as Manifest

/** DSH 兼容性判定认的包名：`@deepseek-ai/dsh` 与 `@deepseek-ai/dsh-*`。 */
const isDshPackage = (name: string): boolean => /^@deepseek-ai\/dsh(?:-|$)/u.test(name)

/** peer 与 dev 里声明的全部 DSH 版本（应当只有一个值）。 */
const dshVersions = (): string[] =>
  Object.entries({ ...manifest.peerDependencies, ...manifest.devDependencies })
    .filter(([name]) => isDshPackage(name))
    .map(([, version]) => version)

test("所有 DSH 依赖钉同一个精确版本", () => {
  const versions = new Set(dshVersions())

  assert.equal(versions.size, 1, `DSH 依赖版本不统一：${[...versions].join(" / ")}`)
})

test("engines.dsh 的下界就是被测版本，上界挡住下一条线的全部预发布", () => {
  const range = manifest.engines?.dsh
  assert.ok(range !== undefined && range !== "", "package.json 缺少 engines.dsh")
  const [pinned] = dshVersions()
  assert.ok(pinned !== undefined, "没有找到任何 @deepseek-ai/dsh* 依赖")

  // 下界：测的是哪一版就 claim 到哪一版。写得更低等于 claim 一个没测过的旧版本。
  assert.equal(
    semver.minVersion(range)?.version,
    pinned,
    `engines.dsh 的下界不是被测版本 ${pinned}`,
  )
  // 被测版本必须落在自己的声明范围内，否则插件在开发机上就会被拒。
  assert.ok(
    semver.satisfies(pinned, range, { includePrerelease: true }),
    `engines.dsh 不包含被测版本 ${pinned}`,
  )

  // 上界：下一条线（patch + 1）的预发布与正式版一律不许放行。
  const parsed = semver.parse(pinned)
  assert.ok(parsed !== null, `无法解析版本 ${pinned}`)
  const nextLine = `${String(parsed.major)}.${String(parsed.minor)}.${String(parsed.patch + 1)}`
  for (const probe of [`${nextLine}-0`, `${nextLine}-alpha.0`, `${nextLine}-rc.1`, nextLine]) {
    // 探针本身必须是合法版本：写错了会让下面的断言空转，等于没有这条用例。
    assert.ok(semver.parse(probe) !== null, `探针 ${probe} 不是合法版本`)
    assert.equal(
      semver.satisfies(probe, range, { includePrerelease: true }),
      false,
      `engines.dsh 放行了没测过的 ${probe}（上界要写成 <${nextLine}-0）`,
    )
  }
})
