/**
 * 帧编解码的回归（契约 §3）。
 *
 * 这里钉的都是「写错了不会报错」的规则：超限、版本不符、未知类型带不带 id、
 * 握手门禁、id/sid 的字符集。它们的共同点是**失败方式不显眼** ——
 * 字符集写松了表现是"解不开"而不是"字段非法"，超限写松了表现是内存涨。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { ProtocolError } from '../src/protocol/errors.js'
import { ID_PATTERN, MAX_FRAME_BYTES, newFrameId, type WireFrame } from '../src/protocol/frame.js'
import {
  assertHandshakePhase,
  createLineSplitter,
  decodeFrame,
  encodeFrame,
  isHandshakeFrame,
} from '../src/transport/codec.js'

const ping = (fc: number): WireFrame => ({ v: 1, t: 'ping', fc, box: '' })

test('帧 id：生成点产出的东西必须过得了自己的字符集校验', () => {
  // `newFrameId` 与 `ID_PATTERN` 放在同一个文件就是为了这条：分开写迟早出现
  // 手拼 base64 的代码（带 `+` `/` `=`），而症状是 AAD 两端不一致 —— "解不开"，不是"字段非法"。
  for (let i = 0; i < 50; i += 1) {
    const id = newFrameId()
    assert.match(id, ID_PATTERN, `生成的 id 不合规：${id}`)
    // 16 字节 base64url = 22 个字符（无填充）。
    assert.equal(id.length, 22)
  }
  assert.notEqual(newFrameId(), newFrameId(), '两次生成不该撞上')
})

test('isHandshakeFrame：握手帧的判据只有一处', () => {
  for (const frame of [
    { v: 1, t: 'hello', id: 'a', box: '' },
    { v: 1, t: 'hello-ack', id: 'a', box: '' },
    { v: 1, t: 'confirm', id: 'a', box: '' },
  ] as WireFrame[]) {
    assert.equal(isHandshakeFrame(frame), true, `${frame.t} 是握手帧`)
  }
  for (const frame of [ping(0), { v: 1, t: 'credit', fc: 0 }] as WireFrame[]) {
    assert.equal(isHandshakeFrame(frame), false, `${frame.t} 不是握手帧`)
  }
})

test('编码：往返一致，超限直接抛', () => {
  const frame = ping(7)
  // 编码侧必须带行分隔符 —— 契约 §3 是"行级"JSON，漏了它对端会一直当半行缓冲。
  assert.equal(encodeFrame(frame), '{"v":1,"t":"ping","fc":7,"box":""}\n')
  assert.deepEqual(decodeFrame(encodeFrame(frame)), { kind: 'frame', frame })

  // 超限不给"先发了再说"的机会。
  const huge = { v: 1, t: 'ev', sid: 's', seq: 1, fc: 1, box: 'x'.repeat(MAX_FRAME_BYTES) } as WireFrame
  assert.throws(() => encodeFrame(huge), (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/bad-frame')
})

test('解码：坏输入都归到封闭错误码', () => {
  const cases: [string, string][] = [
    ['不是 JSON', 'not json at all'],
    ['是数组不是对象', '[1,2,3]'],
    ['是字面量不是对象', '"hello"'],
    ['缺 t', '{"v":1}'],
    ['版本不符', '{"v":2,"t":"ping","fc":0}'],
  ]
  for (const [label, line] of cases) {
    assert.throws(
      () => decodeFrame(line),
      (e: unknown) => e instanceof ProtocolError,
      `${label} 应该抛 ProtocolError`,
    )
  }
  // 版本不符要给专门的码 —— 让对端知道该升级，而不是在"帧不合法"上瞎猜。
  assert.throws(
    () => decodeFrame('{"v":2,"t":"ping"}'),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/unsupported-version',
  )
  assert.throws(
    () => decodeFrame('x'.repeat(MAX_FRAME_BYTES + 1)),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/bad-frame',
  )
})

test('未知帧类型：不带 id 就忽略，带 id 必须回不支持', () => {
  // 向前兼容：不认识就不认识，不要因为对端版本新就断连。
  assert.deepEqual(decodeFrame('{"v":1,"t":"future-thing"}'), {
    kind: 'ignored',
    type: 'future-thing',
  })
  // 但带 id 说明对端在等一个应答 —— 沉默会让它永远挂着。
  assert.deepEqual(decodeFrame('{"v":1,"t":"future-thing","id":"abc-123"}'), {
    kind: 'unsupported',
    id: 'abc-123',
    type: 'future-thing',
  })
})

test('id / sid 的 ASCII 安全字符集必须在解码处拦', () => {
  // AAD 是把字段拼串再哈希：放进一个需要 JSON 转义的字符，两端算出的 AAD 可能不同，
  // 而症状是"解不开"，不是"字段非法" —— 所以要在最外层就拒绝。
  assert.throws(() => decodeFrame('{"v":1,"t":"req","id":"has space","fc":0,"box":""}'))
  assert.throws(() => decodeFrame('{"v":1,"t":"req","id":"中文","fc":0,"box":""}'))
  assert.throws(() => decodeFrame('{"v":1,"t":"ev","sid":"a/b","seq":1,"fc":0,"box":""}'))

  const ok = decodeFrame('{"v":1,"t":"req","id":"aB0_-x","fc":0,"box":""}')
  assert.equal(ok.kind, 'frame')
})

test('握手门禁：未完成握手只收握手帧', () => {
  // 握手三帧照收。`confirm` 必须在列内：它是 §4.1 的第三条消息（手机 → 电脑），
  // 应答方要收到它才能判定握手完成 —— 漏了它的症状是"手机永远停在握手"。
  assert.doesNotThrow(() => assertHandshakePhase({ v: 1, t: 'hello', id: 'a', box: '' }, false))
  assert.doesNotThrow(() => assertHandshakePhase({ v: 1, t: 'hello-ack', id: 'a', box: '' }, false))
  assert.doesNotThrow(() => assertHandshakePhase({ v: 1, t: 'confirm', id: 'a', box: '' }, false))

  // 业务帧在握手前到达是攻击面，必须拦。
  for (const frame of [ping(0), { v: 1, t: 'credit', fc: 0 } as WireFrame]) {
    assert.throws(
      () => assertHandshakePhase(frame, false),
      (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/bad-frame',
      `${frame.t} 在握手前应被拦下`,
    )
  }

  // 握手完成后不再限制。
  assert.doesNotThrow(() => assertHandshakePhase(ping(0), true))
})

test('行级分帧：多行、半行、空行与超长未闭合', () => {
  const split = createLineSplitter()

  assert.deepEqual(split('{"a":1}\n{"b":2}\n'), ['{"a":1}', '{"b":2}'])
  // 半行留到下一片 —— 否则会在网络分片处解出半个 JSON。
  assert.deepEqual(split('{"c":'), [])
  assert.deepEqual(split('3}\n'), ['{"c":3}'])
  // 空行与纯空白不算帧。
  assert.deepEqual(split('\n  \n{"d":4}\n'), ['{"d":4}'])

  // 未闭合的行一旦超限就在拼完之前拦掉，别让不走空格的输入把内存吃光。
  const flood = createLineSplitter()
  assert.throws(
    () => flood('x'.repeat(MAX_FRAME_BYTES + 1)),
    (e: unknown) => e instanceof ProtocolError && e.code === 'protocol/bad-frame',
  )
})
