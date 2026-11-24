/** 同ABI实际versionCode = Flutter ABI偏移 + 基础计数；不可把两者误当同一值。 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

const pubspec = readFileSync(new URL('../../app/pubspec.yaml', import.meta.url), 'utf8')
const workflow = readFileSync(new URL('../../.github/workflows/release.yml', import.meta.url), 'utf8')
const baseline = JSON.parse(readFileSync(new URL('./fixtures/android-release-baseline-v0.2.23.json', import.meta.url), 'utf8')) as {
  versionCode: number; versionName: string; abi: string; abiVersionCode: number; abiMultiplier: number
}
const version = /^version:\s*([^+\s]+)\+(\d+)\s*$/m.exec(pubspec)
assert.ok(version !== null, 'pubspec必须声明基础build number')

test('同ABI拆包实际code高于上一正式APK，不误将基础build number当ARM64实际码', { timeout: 60_000 }, () => {
  const actualAbiCode = baseline.abiVersionCode * baseline.abiMultiplier + Number(version[2])
  assert.ok(actualAbiCode > baseline.versionCode,
    `${baseline.abi}新预期code=${actualAbiCode}不能覆盖${baseline.versionName}实际code=${baseline.versionCode}`)
})

test('release保留SDK split-per-abi和基础run计数，ABI偏移由Flutter统一添加', { timeout: 60_000 }, () => {
  assert.match(workflow, /flutter build apk --release --split-per-abi/)
  assert.match(workflow, /--build-number=[^\n]*GITHUB_RUN_NUMBER/)
})
