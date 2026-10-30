/**
 * 独占准入（1:1）与拒绝理由的回归。
 *
 * 这组用例钉的是**四条互不替代的判据**（不要合并成一条"大概不能连"）：
 *
 * 1. 没有人在服务 ⇒ 放行（第一台手机永远进得来）。
 * 2. **别的**有效设备在服务 ⇒ 拒，且说得出占用者是谁（`device/busy <名字>`）。
 * 3. **同一台设备**重连 ⇒ 放行（换网靠中转的 `replaced`，连接器不许再加门）——
 *    漏掉这条的症状是"换个 WiFi 就把自己挡在门外"。
 * 4. 已停用 / 已删除的行不占位（占坑 DoS：一台停用的旧手机不能永久挡住新手机）。
 *
 * 最后一条是关闭理由的形状：码必须是第一个空格之前的全部字节（手机按它查封闭表），
 * 总长 ≤ 120 字节（WS 硬上限 123，超了 `ws` 抛 RangeError，关闭路径整条失效）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createExclusiveAdmission, shortIdOf } from '../src/exclusive.js'
import { REFUSAL_REASON_MAX_BYTES, refusalReason } from '../src/protocol/close-reason.js'
import { createDevicePresence } from '../src/presence.js'

/** 一台"在服务"的设备 + 一份名册。`paired` 里没有 / 为 `undefined` = 未配对或已吊销。 */
function makeAdmission(paired: Record<string, number | undefined>, names: Record<string, string> = {}) {
  const presence = createDevicePresence({ pairedAtOf: (devId) => paired[devId] })
  const admission = createExclusiveAdmission({
    presence,
    nameOf: (devId) => names[devId],
  })
  return { presence, admission }
}

test('没有人在服务：放行（第一台手机永远进得来）', () => {
  const { admission } = makeAdmission({ 'dev-a': 100 })
  assert.equal(admission.occupantOf('dev-a'), undefined)
})

test('别的有效设备在服务：拒绝并给出占用者的名字', () => {
  const { presence, admission } = makeAdmission(
    { 'dev-a': 100, 'dev-b': 50 },
    { 'dev-a': '我的手机', 'dev-b': '平板' },
  )
  presence.online('dev-a')

  assert.equal(admission.occupantOf('dev-b'), '我的手机', '第二台被拒，理由里是占用者的名字')
  // 占用者自己不受影响（不踢人）。
  assert.equal(admission.occupantOf('dev-a'), undefined, '占用者本人的重连照旧放行')
})

test('两台同时在线（握手竞速那一瞬）：**任何一台别的**都算占用', () => {
  // 独占下不该有两条，但准入是防"两人同时进门"的那道闸：判据必须是
  // "所有在线设备里有没有别的"，而不是"serving() 的第一条是不是我"。
  const { presence, admission } = makeAdmission(
    { 'dev-a': 100, 'dev-b': 50 },
    { 'dev-a': '我的手机', 'dev-b': '平板' },
  )
  presence.online('dev-a')
  presence.online('dev-b')

  const occupant = admission.occupantOf('dev-c')
  assert.notEqual(occupant, undefined, '已有两台在线时必须拒第三台')
  // **在位者（先来的那台）照旧放行**：不踢人、也不锁死它自己的重连。
  assert.equal(admission.occupantOf('dev-a'), undefined, 'dev-a 是占用者本人')
  // 第二台本来就不该在里面：它现在也被判成"被占用"（不会因为它在位就放行下一台）。
  assert.equal(admission.occupantOf('dev-b'), '我的手机', '第二台那条是竞速的漏网之鱼')
})

test('同一台设备换网重连：旧通道还没 detach 也放行（连接器不再加门）', () => {
  const { presence, admission } = makeAdmission({ 'dev-a': 100 }, { 'dev-a': '我的手机' })
  presence.online('dev-a')

  // 旧连接仍在服务（presence 里只有一条记录），新连接带着**同一个 devId** 进来。
  // 换网的正确恢复路径在中转的 `replaced`（`relay/src/server.ts`），
  // 这里再拦一道就会出现"换个 WiFi 连不上自己"。
  assert.equal(admission.occupantOf('dev-a'), undefined)
})

test('已停用 / 已删除的行不占位（占坑 DoS 的判据）', () => {
  // dev-gone 连上来过，但名册里已吊销（`pairedAtOf` 返回 undefined）。
  const { presence, admission } = makeAdmission(
    { 'dev-a': 100, 'dev-gone': undefined },
    { 'dev-gone': '旧手机' },
  )
  presence.online('dev-gone')
  assert.equal(admission.occupantOf('dev-a'), undefined, '已吊销的旧手机挡住新手机 = 占坑 DoS')

  // 删除行与吊销同效：行没了，`pairedAtOf` 也回 undefined（同一条判据）。
  const deleted = makeAdmission({ 'dev-a': 100 })
  deleted.presence.online('dev-gone')
  assert.equal(deleted.admission.occupantOf('dev-a'), undefined)
})

test('名册里没有名字时用 devId 短码（展示值，不参与判据）', () => {
  const { presence, admission } = makeAdmission({ 'dev-a': 100 }, {})
  presence.online('dev-a')
  assert.equal(admission.occupantOf('dev-b'), shortIdOf('dev-a'))
  assert.equal(shortIdOf('0123456789abcdef'), '012345…cdef')
})

test('关闭理由：码在前、说明在后，换行压平，总长 ≤ 120 字节且不切断多字节字符', () => {
  assert.equal(refusalReason('device/busy'), 'device/busy')
  assert.equal(refusalReason('device/busy', ''), 'device/busy')
  assert.equal(refusalReason('device/busy', '我的手机'), 'device/busy 我的手机')
  // 换行会把关闭理由变成两行日志、两行界面。
  assert.equal(refusalReason('device/busy', '我的\n手机'), 'device/busy 我的 手机')

  const long = '很长的设备名'.repeat(40)
  const reason = refusalReason('device/busy', long)
  assert.ok(
    Buffer.byteLength(reason, 'utf8') <= REFUSAL_REASON_MAX_BYTES,
    `关闭理由超了上限：${Buffer.byteLength(reason, 'utf8')} 字节（WS 硬上限 123）`,
  )
  // 码必须逐字留在最前面：手机按第一个空格切出来查封闭表，切坏了会归成 internal。
  assert.equal(reason.split(' ')[0], 'device/busy')
  // 截断按码点做：不能出现替换字符（半个 UTF-8 字符）。
  assert.doesNotMatch(reason, /\uFFFD/)
})
