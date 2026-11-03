/**
 * `connector/LICENSE` 是给 npm 包用的**副本**（`package.json` 的 `files` 里有它），
 * 根 `LICENSE` 才是正本。
 *
 * 换协议时最容易只改一半：根改了、副本忘了，tarball 里元数据与附带正文对不上，
 * 等于对外发了两份互相矛盾的授权文本。这条用例把两者钉死：必须逐字相同。
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
