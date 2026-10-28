/**
 * 文件面的宿主拒绝要**抬成协议错误**，而不是降成 `internal` + 英文原文。
 *
 * 判据：§3.1 的封闭表里有四个 `workspace-file/*` 码（桌面按它们换文案 —
 * `ui-sidebar-documentpreview/src/client/failure-line.ts:24-35`），
 * 而 `protocol/methods.ts:361-370` 只保留 `ProtocolError` 自己的码。
 * 所以适配层必须抬一遍（`protocol/errors.ts` 的 `asProtocolError`）。
 *
 * 反过来也要钉住：**表里没有的码**不许透传（例如宿主新加的
 * `workspace-file/whatever`），否则手机收到一个不认识的码。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createFilesFace } from '../src/dsh/files.js'
import { ProtocolError } from '../src/protocol/errors.js'

interface FakeCtx {
  get(name: string): unknown
}

/** 一个最小的宿主替身：`workspaceFiles.read` 抛什么由用例决定。 */
function faceWith(readError: unknown) {
  const scope = { root: '/w' }
  const ctx = {
    get: (name: string) =>
      name === 'workspaceFiles'
        ? {
            read: async () => {
              throw readError
            },
            list: async () => {
              throw readError
            },
          }
        : name === 'typert'
          ? {
              lookups: new Map([
                ['workspaceFileScope', { resolve: async () => scope }],
              ]),
            }
          : undefined,
  } satisfies FakeCtx
  return createFilesFace(ctx as never, {
    sessionOf: (sid: string) => (sid === 's1' ? 'dsh-session-1' : undefined),
  })
}

test('workspace-file/not-text 抬成同码协议错误（原文进 message）', async () => {
  const error = Object.assign(new Error('not a text file'), {
    code: 'workspace-file/not-text',
  })
  const face = faceWith(error)
  await assert.rejects(
    () => face.read('s1', 'a.png', {}),
    (thrown: unknown) => {
      assert.ok(thrown instanceof ProtocolError)
      assert.equal(thrown.code, 'workspace-file/not-text')
      assert.equal(thrown.message, 'not a text file')
      return true
    },
  )
})

test('四个码都抬（不只 not-text）', async () => {
  for (const code of [
    'workspace-file/not-text',
    'workspace-file/too-large',
    'workspace-file/not-found',
    'workspace-file/not-regular-file',
  ]) {
    const face = faceWith(Object.assign(new Error('x'), { code }))
    await assert.rejects(
      () => face.read('s1', 'a', {}),
      (thrown: unknown) => {
        assert.ok(thrown instanceof ProtocolError, code)
        assert.equal(thrown.code, code)
        return true
      },
    )
  }
})

test('表外的宿主码**不改写**：原样抛给 dispatcher 归一成 internal', async () => {
  // `asProtocolError` 只认封闭表里的码；表外的原样抛，由
  // `protocol/methods.ts:361-370` 统一降成 `internal`（原文进 message）。
  // 这一条钉的是"适配层不许自己发明码"，与 flow.test.ts 那条归一断言互补。
  const error = Object.assign(new Error('weird'), {
    code: 'workspace-file/whatever',
  })
  const face = faceWith(error)
  await assert.rejects(
    () => face.read('s1', 'a', {}),
    (thrown: unknown) => {
      assert.equal(thrown, error)
      return true
    },
  )
})
