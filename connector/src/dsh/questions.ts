/**
 * 提问（含计划审查）适配：把 DSH 的 `userQuestions` 服务与 `userQuestions` 投影
 * 接成 {@link InteractionFaceDeps}（契约 §6.3.1）。
 *
 * ## 为什么是"适配"而不是"再实现一遍"
 *
 * `interaction-face.ts` 刻意**不 import DSH**（它要在纯 Node 下用假实现单测）。
 * 于是 DSH 那一半的全部知识集中在本文件，共三件：
 *
 * 1. **`answer()` 的服务键是 `userQuestions`**（`packages/interaction/user-questions/src/index.ts:85`
 *    注册；方法在 `:164-165`，带 `@Remote`）。它内部 `agent.steer()` 把答案注入为一条
 *    `source.kind='user-question-reply'` 的用户消息（`:186-200`）。
 * 2. **投影来源是 `sessionProjections.stateOf(session, 'userQuestions')`**（`:147` 的私有
 *    `continued()` 就是这么读的）。返回 `undefined` 表示这个会话当前没有投影快照。
 * 3. **`agent` 必须是 live root agent**（`assertLiveRoot`，`:131-144`）：`agents.get(id)`
 *    拿不到、或不在 `agents.roots()` 里，都答不了。子代理里的提问手机答不了 ——
 *    这不是我们的限制，是 DSH 的（源码原话见 `:139-142`）。
 *
 * ## `agentOf` 为什么收 `sid` 而不是 `dshSessionId`
 *
 * 内核的入参是通道别名（手机与中继只见 `sid`，契约 §5.1），所以别名→会话的解析在这一层做。
 * **会话不存在或已被替换时返回 `undefined`**，由内核映射成 `interaction/not-pending`
 * （§15：那正是"刷新待处理列表"的客户端动作）。
 */
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type {
  AskUserQuestionAnswer,
  AskUserQuestionAnswerItem,
  AskUserQuestionItem,
  UserQuestionProjectionView,
} from '@deepseek-ai/dsh-user-questions/types'

import type {
  AnswerBatch,
  AnswerItem,
  InteractionFaceDeps,
  QuestionAgent,
  QuestionProjection,
} from '../interaction-face.js'

/** DSH 的 `userQuestions` 服务面（收窄到本层真正用到的方法）。 */
interface UserQuestionsService {
  answer(agent: Agent, callId: string, answer: AskUserQuestionAnswer): boolean
}

/** `sessionProjections` 的读取面（服务键不在本插件的依赖里，所以按形状收窄）。 */
interface SessionProjectionsService {
  stateOf(
    session: unknown,
    key: 'userQuestions',
  ): { questions: UserQuestionProjectionView } | undefined
}

/** `agents` 注册表的读取面（`packages/core/agent/src/index.ts:566` 的 `get`）。 */
interface AgentsRegistry {
  get(id: Agent['id']): Agent | undefined
}

export interface QuestionFaceDeps {
  /** 通道别名 → DSH 会话 id（契约 §5.1）。不认识的别名返回 `undefined`。 */
  sessionOf(sid: string): string | undefined
}

/** 品牌类型的铸点：内核不认识 DSH 的 `Agent`，只有这一处知道"它就是 live root agent 的载体"。 */
function asQuestionAgent(agent: Agent): QuestionAgent {
  return agent as unknown as QuestionAgent
}

/**
 * 建提问面的 DSH 半边。
 *
 * @param ctx - cordis 上下文。三个服务键全部走 `ctx.get`（缺了就是能力位为 false，
 *   不是抛异常 —— 裸读 `ctx.userQuestions` 在服务缺失时抛，见 `dsh/caps.ts` 的文件头）。
 */
export function createQuestionFaceDeps(ctx: Context, deps: QuestionFaceDeps): InteractionFaceDeps {
  const agentsOf = (): AgentsRegistry | undefined =>
    (ctx.get('agents') as AgentsRegistry | undefined) ?? undefined
  const projectionsOf = (): SessionProjectionsService | undefined =>
    (ctx.get('sessionProjections') as SessionProjectionsService | undefined) ?? undefined

  /** 别名 → live root agent。任一环缺失都返回 `undefined`（内核据此回 not-pending）。 */
  const agentOf = (sid: string): QuestionAgent | undefined => {
    const dshSessionId = deps.sessionOf(sid)
    if (dshSessionId === undefined) return undefined
    const agents = agentsOf()
    if (agents === undefined) return undefined
    const agent = agents.get(dshSessionId as Agent['id'])
    // `agents.get` 已经保证"是活的注册表条目"；`roots()` 的判据交给 DSH 的
    // `assertLiveRoot`（它抛 `DELEGATED_CALLER`，由内核映射成 not-pending）——
    // 在这里先排掉无主子代理只会让同一件事有两个判据。
    return agent === undefined ? undefined : asQuestionAgent(agent)
  }

  return {
    answer(agent, callId, batch: AnswerBatch) {
      const questions = ctx.get('userQuestions') as UserQuestionsService | undefined
      if (questions === undefined) {
        throw new Error('userQuestions 服务不在：提问应答不可用')
      }
      // **批次原样转发，一个字段都不翻译**（契约 §6.3.1：翻译层就是漂移层）。
      // 内核已经校验过"每个问题恰好一项"，这里的形状与 DSH 的 `AskUserQuestionAnswer`
      // 逐字一致，所以直接结构化赋过去。
      const answer: AskUserQuestionAnswer = {
        answers: batch.answers.map(
          (item: AnswerItem): AskUserQuestionAnswerItem => ({
            id: item.id,
            selected: [...item.selected],
            ...(item.custom === undefined ? {} : { custom: item.custom }),
          }),
        ),
      }
      return questions.answer(agent as unknown as Agent, callId, answer)
    },

    agentOf,

    projectionOf(sid) {
      const agent = agentOf(sid)
      if (agent === undefined) return undefined
      const projections = projectionsOf()
      if (projections === undefined) return undefined
      const state = projections.stateOf((agent as unknown as Agent).session, 'userQuestions')
      const view = state?.questions
      if (view === undefined) return undefined
      const projection: QuestionProjection = {
        active: (view.active ?? []).map((question) => ({
          callId: question.callId,
          questions: question.questions as readonly AskUserQuestionItem[],
          state: question.state,
        })),
        settled: (view.settled ?? []).map((question) => ({
          callId: question.callId,
          answers: question.answers as readonly AnswerItem[],
        })),
      }
      return projection
    },
  }
}
