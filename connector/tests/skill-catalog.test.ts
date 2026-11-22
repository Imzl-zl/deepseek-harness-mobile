/// 技能目录（`skill.catalog`，契约 §5.7）：桌面 `/` 菜单的另一半。
/// 钉四件事：
///
/// 1. **形状**：宿主给 `{skills: [...]}`，过线只留 `name` / `description?` /
///    `modelInvocable?`；名字不是字符串的行**丢掉**（一条坏行不该让整张菜单消失），
///    空说明视同没给（线上就是"这个键不出现"）。
/// 2. **别名**：`sid` 由连接器换成 DSH 会话 id；不认识的别名回 `session/not-found`
///    （与 `session.projections` 同一个码）。
/// 3. **按能力位挂**：`sessionSkillCatalog` 不在 ⇒ 方法不挂、`caps.skills` false
///    —— 手机菜单里没有"技能"那一段，而不是一个必然失败的候选。
/// 4. **与桌面同一条**：技能是"插进消息的引用"，不是命令 —— 所以这个方法**只读**、
///    不带幂等键（`command.execute` 才是那条写路径）。
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import { skillsAvailable } from '../src/dsh/caps.js'
import { createSkillCatalogPort } from '../src/dsh/skills.js'
import { IDEMPOTENT_METHODS, METHODS } from '../src/protocol/methods.js'

/** 最小可用的假 DSH 上下文：只按形状回答本插件问到的那几个键。 */
function fakeCtx(services: Record<string, unknown>) {
  return { get: (key: string) => services[key] } as never
}

const SID = 'sid_1'
const DSH_ID = 'dsh-session-1'
const ALIASES = {
  ensure: async () => SID,
  sessionOf: (sid: string) => (sid === SID ? DSH_ID : undefined),
} as never

test('方法在封闭集里，且是读方法（不带幂等键）', () => {
  assert.equal(METHODS.includes('skill.catalog'), true)
  assert.equal(
    IDEMPOTENT_METHODS.has('skill.catalog'),
    false,
    '技能目录是只读的：它没有第二次副作用，也就不需要幂等键',
  )
})

test('形状：只留三样字段；坏行丢掉；空说明不带', async () => {
  const asked: unknown[] = []
  const port = createSkillCatalogPort(
    fakeCtx({
      sessionSkillCatalog: {
        list: async (request: unknown) => {
          asked.push(request)
          return {
            skills: [
              { name: 'write-ppt', description: '做 PPT', modelInvocable: true, path: '/x/SKILL.md', whenToUse: '桌面侧的东西' },
              { name: 'quiet-one', description: '', modelInvocable: false },
              { name: 7 },
              { description: '没有名字' },
              'not-an-object',
            ],
          }
        },
      },
    }),
    { sessionOf: (sid) => (sid === SID ? DSH_ID : undefined) },
  )

  const view = await port.of(SID)

  // 别名在连接器里换；请求形状是宿主的 `{sessionId}`。
  assert.deepEqual(asked, [{ sessionId: DSH_ID }])
  assert.deepEqual(view.skills, [
    { name: 'write-ppt', description: '做 PPT', modelInvocable: true },
    { name: 'quiet-one', modelInvocable: false },
  ])
})

test('别名未知 ⇒ session/not-found（不是空列表）', async () => {
  const port = createSkillCatalogPort(
    fakeCtx({ sessionSkillCatalog: { list: async () => ({ skills: [] }) } }),
    { sessionOf: () => undefined },
  )
  await assert.rejects(port.of('sid_unknown'), (error: { code?: string }) => {
    assert.equal(error.code, 'session/not-found')
    return true
  })
})

test('按能力位挂：服务在 ⇒ 方法挂 + caps.skills true；不在 ⇒ 都不出现', async () => {
  const present = fakeCtx({
    sessionSkillCatalog: { list: async () => ({ skills: [] }) },
  })
  const absent = fakeCtx({})
  assert.equal(skillsAvailable(present), true)
  assert.equal(skillsAvailable(absent), false, '能力位与挂载判据是同一个函数')

  const port = createSkillCatalogPort(present, {
    sessionOf: (sid) => (sid === SID ? DSH_ID : undefined),
  })
  const deps = {
    sessions: { list: async () => [] },
    aliases: ALIASES,
    skills: port,
  } as unknown as HandlerDeps
  const withSkills = createHandlers(deps)
  assert.notEqual(withSkills['skill.catalog'], undefined)

  const withoutSkills = createHandlers({
    sessions: { list: async () => [] },
    aliases: ALIASES,
  } as unknown as HandlerDeps)
  assert.equal(withoutSkills['skill.catalog'], undefined, '缺服务就不挂：手机看到的是"方法不存在"')
})

test('handler：别名不认识回 session/not-found；认识就把目录交出去', async () => {
  const port = createSkillCatalogPort(
    fakeCtx({
      sessionSkillCatalog: {
        list: async () => ({ skills: [{ name: 'write-ppt', description: '做 PPT' }] }),
      },
    }),
    { sessionOf: (sid) => (sid === SID ? DSH_ID : undefined) },
  )
  const handlers = createHandlers({
    sessions: { list: async () => [] },
    aliases: ALIASES,
    skills: port,
  } as unknown as HandlerDeps)

  assert.deepEqual(await handlers['skill.catalog']!({ sid: SID }, undefined as never), {
    skills: [{ name: 'write-ppt', description: '做 PPT' }],
  })

  await assert.rejects(
    async () => handlers['skill.catalog']!({ sid: 'sid_unknown' }, undefined as never),
    (error: { code?: string }) => {
      assert.equal(error.code, 'session/not-found')
      return true
    },
  )
})
