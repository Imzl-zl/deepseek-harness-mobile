/** 配对 v2 不能借旧的明文路径绕过握手。 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { waitFor } from './support/peer.js'
import { start } from './support/secure-connection.js'

test('旧明文 pair 在真实连接上被拒绝，不交给业务层', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  f.watchClose()
  f.peer.send({ v: 1, t: 'pair', id: 'p1', box: '{"codeHash":"abc"}' } as never)
  await waitFor('旧配对路径关闭', () => f.closes.length > 0)
  assert.deepEqual(f.frames, [])
})

test('新 pair-commit 在握手前同样被拒绝，不能明文提交秘密', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  f.watchClose()
  f.peer.send({ v: 1, t: 'pair-commit', id: 'p1', fc: 0, box: '{}' })
  await waitFor('未加密配对被关闭', () => f.closes.length > 0)
  assert.deepEqual(f.frames, [])
})

test('出帧只有握手后的加密路径，业务和配对都不能提前发送', async (t) => {
  const f = await start(t)
  f.connection.start()
  await waitFor('进入 handshake', () => f.connection.state === 'handshake')
  assert.equal('sendPairingFrame' in f.connection, false)
  assert.equal(f.connection.send({ v: 1, t: 'req', id: 'r1', box: '{}' }), false)
  assert.equal(f.connection.send({ v: 1, t: 'pair-result', id: 'p1', box: '{}' }), false)
  assert.deepEqual(f.peer.received, [])
})
