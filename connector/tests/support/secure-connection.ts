/**
 * 安全连接夹具：一台**真的**电脑侧连接 + 一个**独立实现**的手机侧替身。
 *
 * 从 `connection-handshake.test.ts` 抽出来，因为握手之外的用例（封箱、流控）要用同一套东西 ——
 * 两份拷贝会各自漂移，而漂移的症状是"只有某一组测试能过"。
 *
 * 三件事在这里一次定义好，测试文件只管自己要断言的行为：
 *
 * 1. **电脑侧真跑 `createConnection`**（含握手驱动器与箱密码器），不是桩；
 * 2. **手机侧走真 WebSocket**，封箱用 `support/phone.ts` 里自己那份实现（不 import 产品代码）；
 * 3. **清理挂在测试上下文上**：`waitFor` 超时抛错后，后面的 `stop()` 不会执行，
 *    而连接内部的定时器链会把测试进程吊住不退出（表现是"失败了但命令不返回"）。
 */
import assert from 'node:assert/strict'

import { createBoxCodec } from '../../src/protocol/box.js'
import { deriveIdentity, type SessionKeys } from '../../src/protocol/crypto.js'
import type { WireFrame } from '../../src/protocol/frame.js'
import {
  createHandshakeDriver,
  type HandshakeEstablishment,
} from '../../src/protocol/handshake-driver.js'
import type { MethodHandler, MethodName } from '../../src/protocol/methods.js'
import type { Idempotency } from '../../src/idempotency.js'
import {
  createJobSubscriptions,
  type JobFollowSource,
  type JobSubscriptions,
} from '../../src/job-subscriptions.js'
import {
  createSessionSubscriptions,
  type SessionFollowSource,
  type SessionSubscriptions,
} from '../../src/session-subscriptions.js'
import { createMethodFace } from '../../src/method-face.js'
import { createConnection, type Connection } from '../../src/transport/connection.js'
import { startPeer, waitFor, type Peer } from './peer.js'
import { createPhone, type Phone } from './phone.js'

/** 固定的 32 字节种子。 */
export const seed = (n: number): string => n.toString(16).padStart(2, '0').repeat(32)

export const PC_SEED = seed(0xa1)
export const PC_ID = 'pc-1'
export const PHONE_SEED = seed(0xb2)
export const DEV_ID = 'dev-1'
export const PAIRING = 'pair-1'

export type Cleanup = { after(fn: () => void | Promise<void>): void }

export interface Fixture {
  connection: Connection
  peer: Peer
  phone: Phone
  established: HandshakeEstablishment[]
  /** 连接层交给上层的业务帧（握手帧不该出现在这里）。 */
  frames: WireFrame[]
  /** 服务端看到的关闭帧（`code` / `reason`）。 */
  closes: { code: number; reason: string }[]
  /** 在握手阶段就挂上关闭监听 —— 连接被关得很快，晚了就抓不到。 */
  watchClose(): void
  /** 任务输出订阅注册表（只在给了 `jobSource` 时非空）。 */
  subscriptions: JobSubscriptions | null
  /** 会话订阅注册表（只在给了 sessionSource 时非空）。 */
  sessionSubscriptions: SessionSubscriptions | null
}

/** 起对端 + 连接，并注册清理。 */
export async function start(
  t: Cleanup,
  options: {
    /**
     * 方法表。
     *
     * 两种写法都收：直接给表（多数用例），或给一个"拿到订阅注册表再建表"的工厂
     * （订阅要往连接里出帧，而注册表必须先于方法面建出来 —— 见 `jobSource`）。
     */
    handlers?:
      | Partial<Record<MethodName, MethodHandler>>
      | ((registries: {
          job: JobSubscriptions | null
          session: SessionSubscriptions | null
        }) => Partial<Record<MethodName, MethodHandler>>)
    /** 给了它就装幂等执行（与 `index.ts` 的装配一致）。 */
    idempotency?: Idempotency
    /**
     * 给了它就装任务输出订阅注册表（与 `index.ts` 的装配一致）。
     *
     * **可变引用是必需的**：注册表要往连接里出帧，而连接在注册表之后才建出来。
     * 产品代码里两者都在同一个 `start-transport` 步骤里（`next` 已在手），
     * 只有 fixture 需要这样绕一下。
     */
    jobSource?: JobFollowSource
    /** 给了它就装会话订阅注册表（与 `index.ts` 的装配一致）。 */
    sessionSource?: SessionFollowSource
  } = {},
): Promise<Fixture> {
  const pc = deriveIdentity(PC_SEED)
  const phoneIdentity = deriveIdentity(PHONE_SEED)
  const phone = createPhone({
    devId: DEV_ID,
    staticSeedHex: phoneIdentity.dhSeedHex,
    signSeedHex: phoneIdentity.signSeedHex,
    ephSeedHex: seed(0xd4),
    nonceA: seed(0xc3),
    pairingId: PAIRING,
    pcSignPubHex: pc.sign.publicKeyHex,
    pcDhPubHex: pc.dh.publicKeyHex,
  })

  const established: HandshakeEstablishment[] = []
  const frames: WireFrame[] = []
  const closes: { code: number; reason: string }[] = []
  /** 连接晚于注册表建出来，所以注册表通过这两个闭包引用它（见 `jobSource` 的说明）。 */
  let wired: Connection | null = null
  const subscriptions =
    options.jobSource === undefined
      ? null
      : createJobSubscriptions({
          source: options.jobSource,
          send: (sid, output) => {
            if (wired === null || wired.state !== 'serving') return 'closed'
            return wired.send({ v: 1, t: 'job', sid, box: JSON.stringify(output) }) ? 'sent' : 'paused'
          },
          waitWritable: () => (wired === null ? Promise.resolve() : wired.whenWritable('job')),
        })
  const sessionSubscriptions =
    options.sessionSource === undefined
      ? null
      : createSessionSubscriptions({
          source: options.sessionSource,
          send: (out) => {
            if (wired === null || wired.state !== 'serving') return 'closed'
            const body = JSON.stringify(out.payload)
            const frame =
              out.t === 'ev'
                ? { v: 1 as const, t: 'ev' as const, sid: out.sid, seq: out.seq, box: body }
                : {
                    v: 1 as const,
                    t: 'live' as const,
                    sid: out.sid,
                    stream: out.stream,
                    rev: out.rev,
                    box: body,
                  }
            return wired.send(frame) ? 'sent' : 'paused'
          },
          waitWritable: () => (wired === null ? Promise.resolve() : wired.whenWritable('ev')),
        })
  /** 给了 handlers 才装方法面 —— 握手与流控那两组用例不需要它。 */
  const handlerTable =
    typeof options.handlers === 'function'
      ? options.handlers({ job: subscriptions, session: sessionSubscriptions })
      : options.handlers
  const face =
    handlerTable === undefined
      ? null
      : createMethodFace({
          handlers: handlerTable,
          ...(options.idempotency === undefined ? {} : { idempotency: options.idempotency }),
        })

  const peer = await startPeer()
  const connection = createConnection({
    url: peer.url,
    dial: (target) => new WebSocket(target) as never,
    secure: {
      handshake: createHandshakeDriver({
        identity: { dh: pc.dh, signSeedHex: pc.signSeedHex },
        pcId: PC_ID,
        peerOf: (devId) =>
          devId === DEV_ID
            ? {
                edPubHex: phoneIdentity.sign.publicKeyHex,
                dhPubHex: phoneIdentity.dh.publicKeyHex,
                pairingId: PAIRING,
              }
            : undefined,
        timeoutMs: 2_000,
      }),
      // 电脑侧 = 应答方：`kA2B` 解入站、`kB2A` 封出站。
      createCipher: (keys) => createBoxCodec({ keys, role: 'responder' }),
    },
    onEstablished: (result) => established.push(result),
    onFrame: (frame) => {
      frames.push(frame)
      // 与 `index.ts` 的装配一致：`req` 归方法面，应答走同一条出帧路径（由连接层分配 `fc` 与封箱）。
      if (face !== null && frame.t === 'req') {
        void face.handle(frame).then((response) => {
          if (response !== null) connection.send(response)
        })
      }
    },
    heartbeatMs: 5_000,
    batchMs: 30,
    // 与产品装配一致：连接离开服务态即终止任务输出订阅（手机收不到，它重连后自己按 from 重订）。
    onStateChange: (from, to) => {
      if (from === 'serving' && to !== 'serving') {
        subscriptions?.stopAll()
        sessionSubscriptions?.stopAll()
      }
    },
  })
  wired = connection
  t.after(async () => {
    subscriptions?.stopAll()
    connection.stop()
    await peer.close()
  })

  return {
    connection,
    peer,
    phone,
    established,
    frames,
    closes,
    subscriptions,
    sessionSubscriptions,
    watchClose: () => {
      peer.sockets.at(-1)?.on('close', (code: number, reason: Buffer) => {
        closes.push({ code, reason: reason.toString() })
      })
    },
  }
}

/** 手机 → 电脑：`hello`。 */
export function sendHello(f: Fixture): void {
  f.peer.send({ v: 1, t: 'hello', id: 'h1', box: f.phone.helloBox() })
}

/** 等电脑侧的 `hello-ack`，顺带断言握手帧的线上形状（§3：没有 `fc`、没有 `sid`）。 */
export async function waitHelloAck(f: Fixture): Promise<string> {
  await waitFor('收到 hello-ack', () => f.peer.received.some((frame) => frame.t === 'hello-ack'))
  const frame = f.peer.received.find((candidate) => candidate.t === 'hello-ack')
  assert.ok(frame !== undefined && frame.t === 'hello-ack')
  assert.equal('fc' in frame, false, '握手帧不带 fc')
  assert.equal('sid' in frame, false, '握手帧不挂会话别名')
  return frame.box
}

/** 手机 → 电脑：`confirm`。 */
export function sendConfirm(f: Fixture, box: string): void {
  f.peer.send({ v: 1, t: 'confirm', id: 'c1', box })
}

/** 走完三帧，返回手机侧独立派生出来的会话密钥。 */
export async function completeHandshake(f: Fixture): Promise<SessionKeys> {
  sendHello(f)
  const accepted = f.phone.acceptAck(await waitHelloAck(f))
  sendConfirm(f, accepted.confirmBox)
  await waitFor('进入 serving', () => f.connection.state === 'serving')
  return accepted.keys
}
