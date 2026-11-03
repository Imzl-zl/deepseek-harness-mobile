/**
 * `connector/LICENSE` 是给 npm 包用的**副本**（`package.json` 的 `files` 里有它），
 * 根 `LICENSE` 才是正本。
 *
 * 2026-11-03 换协议时就踩过：根换成了 PolyForm，副本还是 MIT，于是 0.1.17 的
 * tarball 里 `package.json` 说 PolyForm、附带的 LICENSE 正文却是 MIT —— 对外
 * 授权的文本自相矛盾。这条用例把那两者钉死：副本与正本必须逐字相同。
 */
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { test } from "node:test"

const readLicense = (relative: string): string =>
  readFileSync(fileURLToPath(new URL(relative, import.meta.url)), "utf8")

test("包里的 LICENSE 副本与仓库根的正本逐字相同", () => {
  const root = readLicense("../../LICENSE")
  const shipped = readLicense("../LICENSE")

  assert.match(root, /^MIT License/, "根 LICENSE 不是 MIT")
  assert.equal(shipped, root, "connector/LICENSE 与根 LICENSE 漂移了（npm 包会带错协议）")
})
