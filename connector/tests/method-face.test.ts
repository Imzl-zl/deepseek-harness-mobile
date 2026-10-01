/**
 * 方法面的回归（契约 §5.7、§9）。
 *
 * 这一层的失效方式都很安静：`id` 没回带 → 手机永远等不到回应；`ok` 头与信封不一致 →
 * 手机按头分支、按信封显示，两处说法不同；handler 抛错被吞成"成功" → 表面正常而操作没生效。
 * 所以下面每条都在钉**这些**形状，而不是"能跑通"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createMethodFace, resFrame } from '../src/method-face.js'
import type { WireFrame } from '../src/protocol/frame.js'
import type { MethodHandler } from '../src/protocol/methods.js'

const req = (box: string, extra: { id?: string; sid?: string } = {}): WireFrame => ({
  v: 1,
  t: 'req',
  id: extra.id ?? 'req_0123456789ab',
  ...(extra.sid === undefined ? {} : { sid: extra.sid }),
  fc: 0,
  box,
})

/** 解 `res` 帧的载荷（测试里当成手机侧：拿到的就是明文）。 */
function envelopeOf(frame: { box: string }): { ok: boolean; result?: unknown; code?: string; message?: string } {
  return JSON.parse(frame.box) as never
}

test('req → res：回带同一个 id，ok 与信封同源', async () => {
  const face = createMethodFace({ handlers: { 'repo.info': () => ({ hello: 'world' }) } })
  const res = await face.handle(req('{"method":"repo.info"}'))

  assert.ok(res !== null && res.t === 'res')
  assert.equal(res.id, 'req_0123456789ab', 'id 必须原样回带 —— 它就是请求与应答的唯一关联')
  assert.equal(res.ok, true)
  const envelope = envelopeOf(res)
  assert.equal(envelope.ok, res.ok, '帧头的 ok 与信封里的 ok 必须同源')
  assert.deepEqual(envelope.result, { hello: 'world' })
})

test('sid：有就回带，没有就不带（它是中继路由字段，凭空加一个会让路由错）', async () => {
  const face = createMethodFace({ handlers: { 'repo.info': () => ({}) } })

  const withSid = await face.handle(req('{"method":"repo.info"}', { sid: 'sid_0123456789ab' }))
  assert.ok(withSid !== null)
  assert.equal('sid' in withSid && withSid.sid, 'sid_0123456789ab')

  const without = await face.handle(req('{"method":"repo.info"}'))
  assert.ok(without !== null)
  assert.equal('sid' in without, false)
})

test('不认识的方法：回 connector/unsupported，而不是断连', async () => {
  const face = createMethodFace({ handlers: {} })
  const res = await face.handle(req('{"method":"session.typo"}'))
  assert.ok(res !== null && res.t === 'res')
  assert.equal(res.ok, false)
  assert.equal(envelopeOf(res).code, 'connector/unsupported')
})

test('幂等键强制：漏键的方法在分发前就被拦', async () => {
  let called = false
  const handler: MethodHandler = () => {
    called = true
    return {}
  }
  const face = createMethodFace({ handlers: { 'session.prompt': handler } })

  const res = await face.handle(req('{"method":"session.prompt","params":{}}'))
  assert.ok(res !== null && res.ok === false)
  assert.equal(envelopeOf(res).code, 'protocol/bad-frame')
  assert.equal(called, false, '漏键时 handler 根本不该被执行 —— 否则就成了"第二次发消息"')

  const withKey = await face.handle(req('{"method":"session.prompt","requestId":"k1"}'))
  assert.ok(withKey !== null && withKey.ok === true)
  assert.equal(called, true)
})

test('handler 抛错：变成 internal 信封，绝不吞成成功', async () => {
  const face = createMethodFace({
    handlers: {
      'repo.info': () => {
        throw new Error('服务炸了')
      },
    },
  })
  const res = await face.handle(req('{"method":"repo.info"}'))
  assert.ok(res !== null && res.ok === false)
  assert.equal(envelopeOf(res).code, 'internal')
  assert.match(envelopeOf(res).message ?? '', /服务炸了/)
})

test('载荷坏：回 protocol/bad-frame，且从不抛（关连接不是它的权力）', async () => {
  const face = createMethodFace({ handlers: {} })

  for (const box of ['not json', '[]', '{"params":{}}']) {
    const res = await face.handle(req(box))
    assert.ok(res !== null && res.t === 'res', `${box} 应当得到错误信封而不是异常`)
    assert.equal(res.ok, false)
    assert.equal(envelopeOf(res).code, 'protocol/bad-frame')
  }
})

test('不归方法面管的帧：返回 null，不制造应答', async () => {
  const face = createMethodFace({ handlers: {} })
  for (const frame of [
    { v: 1, t: 'ping', fc: 0, box: '' },
    { v: 1, t: 'credit', fc: 0, box: '' },
  ] as WireFrame[]) {
    assert.equal(await face.handle(frame), null)
  }
})

test('implemented：报的是表里真有的方法', () => {
  const face = createMethodFace({
    handlers: { 'repo.info': () => ({}), 'devices.list': () => ({}) },
  })
  assert.deepEqual([...face.implemented].sort(), ['devices.list', 'repo.info'])
})

test('resFrame：信封只在这一处被拆成帧头 + 载荷', () => {
  const frame = resFrame({ id: 'r1' }, { ok: true, result: 42 })
  assert.deepEqual(frame, { v: 1, t: 'res', id: 'r1', ok: true, box: '{"ok":true,"result":42}' })

  const failed = resFrame({ id: 'r2', sid: 'sid_x' }, { ok: false, code: 'internal' })
  assert.deepEqual(failed, {
    v: 1,
    t: 'res',
    id: 'r2',
    sid: 'sid_x',
    ok: false,
    box: '{"ok":false,"code":"internal"}',
  })
})
