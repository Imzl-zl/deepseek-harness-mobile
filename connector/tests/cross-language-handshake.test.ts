/**
 * 跨实现一致性：**产品的 Dart 实现** ⇄ **产品的 TS 实现**真打一次。
 *
 * ## 为什么值得一条专门的用例
 *
 * 此前两条链各自自洽:手机的用例对着 Dart 写的电脑替身(`app/test/support/fake_pc.dart`),
 * 电脑侧的用例对着 TS 写的手机替身(`connector/tests/support/phone.ts`)。
 * 两边都绿,可一旦 transcript 拼串顺序、AAD 规范化或箱容器有偏差,症状是
 * "验签失败 / 箱解不开",而错误信息会说"公钥被替换"——真因在一处拼串上,
 * 报出来的却像中间人攻击,**单测抓不到**(各自自洽)。
 *
 * 本用例让**两边产品代码**直接对上:Dart 侧跑 `app/tool/cross_initiator.dart`
 * (真 `createHandshakeDriver` + 真 `BoxCodec`),TS 侧用本文件的真
 * `createHandshakeDriver` + 真 `createBoxCodec`。比对四件事:
 *
 * 1. TS 驱动器真的验过 Dart 的 `sigA` 与 `transcriptHash`(任不过即失败);
 * 2. 双方**派生的会话密钥**逐字节相同(证明 transcript 拼串与 HKDF 输入一致);
 * 3. Dart 封的业务帧 TS 解得开(证明 AAD 规范化与箱容器一致);
 * 4. TS 封的应答 Dart 解得开(反方向再来一次)。
 *
 * 交互走 stdio(一行一帧),不起 socket —— 少一个时序来源,失败也更好读。
 */
import assert from 'node:assert/strict'
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import { deriveIdentity, type SessionKeys } from '../src/protocol/crypto.js'
import { createHandshakeDriver } from '../src/protocol/handshake-driver.js'
import { createBoxCodec } from '../src/protocol/box.js'

const APP_DIR = new URL('../../app', import.meta.url)

/** 与 `app/tool/cross_initiator.dart` 逐字相同的固定种子。 */
const MASTER_SEED = '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20'
const PC_SEED = 'a1'.repeat(32)
const PAIRING_ID = 'cHJhY3RpY2UtaWQtcHJhY3RpY2UtaWQtcHJhY3RpY2U'
const DEV_ID = 'tsJs6UgOJFdyfpazdZSQpQ'

const waitFor = async (what: string, check: () => boolean, timeoutMs = 30_000): Promise<void> => {
  const started = Date.now()
  while (!check()) {
    if (Date.now() - started > timeoutMs) throw new Error(`等待超时：${what}`)
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
}

/** 起 Dart 探针，返回它的 stdio 与"读一行"辅助。 */
function startProbe(): {
  child: ChildProcessWithoutNullStreams
  /** 读下一行**帧**。 */
  readFrame: () => Promise<Record<string, unknown>>
  writeLine: (line: string) => void
  /** Dart 侧写到 stderr 的内容(它失败时的唯一线索)。 */
  stderrText: () => string
} {
  // Windows 上 `dart` 是 `flutter\bin\dart.bat`(shim),而 Node 出于安全原因
  // **拒绝直接 spawn `.bat`/`.cmd`**(CVE 之后的限制)——于是报 `spawn dart ENOENT`,
  // 看起来像"没装 Dart",其实装得好好的。所以这里走 `shell: true`;
  // 参数里没有空格与引号,不涉及 shell 转义问题。
  const child = spawn('dart', ['run', 'tool/cross_initiator.dart'], {
    cwd: fileURLToPath(APP_DIR),
    stdio: ['pipe', 'pipe', 'pipe'],
    shell: true,
  })
  let stderr = ''
  child.stderr.on('data', (chunk: Buffer) => {
    stderr += chunk.toString('utf8')
  })
  const queue: string[] = []
  let waiter: ((line: string) => void) | null = null
  let buffer = ''
  child.stdout.on('data', (chunk: Buffer) => {
    buffer += chunk.toString('utf8')
    for (;;) {
      const index = buffer.indexOf('\n')
      if (index === -1) break
      const line = buffer.slice(0, index)
      buffer = buffer.slice(index + 1)
      if (waiter !== null) {
        const settle = waiter
        waiter = null
        settle(line)
      } else {
        queue.push(line)
      }
    }
  })
  const readLine = (): Promise<string> =>
    new Promise((resolve, reject) => {
      const taken = queue.shift()
      if (taken !== undefined) {
        resolve(taken)
        return
      }
      // Dart 首次 `run` 要编译 + 跑 build hooks,给宽一点;真跑起来之后是毫秒级。
      const timer = setTimeout(() => {
        waiter = null
        reject(new Error(`等 Dart 探针输出超时。stderr:\n${stderr}`))
      }, 180_000)
      waiter = (line) => {
        clearTimeout(timer)
        resolve(line)
      }
    })
  return {
    child,
    readFrame: async () => {
      for (;;) {
        const line = await readLine()
        // `dart run` 的 "Running build hooks…" 前缀**不带换行**,于是它和第一帧挤在
        // 同一行里。所以不能"整行跳过",要从第一个 `{` 开始解析;解析不了才跳过
        // (那才是纯噪声行)。这不是宽容解析——帧一定是 JSON 对象,噪声一定不是。
        const start = line.indexOf('{')
        if (start === -1) continue
        try {
          return JSON.parse(line.slice(start)) as Record<string, unknown>
        } catch {
          continue
        }
      }
    },
    writeLine: (line) => child.stdin.write(`${line}\n`),
    stderrText: () => stderr,
  }
}

test('跨实现:Dart 发起方与 TS 应答方真打一次,密钥与双向封箱都一致', async (t) => {
  const pc = deriveIdentity(PC_SEED)
  // 手机侧身份从**同一份主种子**派生 —— 驱动器要拿它的 Ed25519 公钥验 `sigA`,
  // 所以这不是"自己证明自己":验不过这条用例就红。
  const phone = deriveIdentity(MASTER_SEED)

  const probe = startProbe()
  // 收干净:子进程与它的 stdio 都要关,否则 `node --test` 会一直等(表现为"用例绿了但进程不退")。
  t.after(() => {
    probe.child.stdin.destroy()
    probe.child.stdout.destroy()
    probe.child.stderr.destroy()
    probe.child.kill()
  })

  // ---- TS 侧:产品的应答驱动器 ----
  // 用对象容器而不是两个 `let`:回调里赋值后 TS 的控制流分析会把 `let` 收窄成
  // `never`(它不知道回调已经跑过),于是后面处处编译不过。
  const state: { keys: SessionKeys | null; failure: string | null } = { keys: null, failure: null }
  const driver = createHandshakeDriver({
    identity: { dh: pc.dh, signSeedHex: pc.signSeedHex },
    pcId: 'conn-1',
    peerOf: (devId) =>
      devId === DEV_ID
        ? {
            edPubHex: phone.sign.publicKeyHex,
            dhPubHex: phone.dh.publicKeyHex,
            pairingId: PAIRING_ID,
          }
        : undefined,
  })
  const session = driver({
    send: (frame) => probe.writeLine(JSON.stringify(frame)),
    established: (result) => {
      state.keys = result.keys
    },
    // **不在这里抛**:先记下,等把 Dart 侧的 stderr 一起带上再抛 ——
    // 否则看到的是"TS 超时",而真因往往是 Dart 侧先拒了 TS 的签名(两边各自实现
    // 同一套协议时,这正是最想第一时间看到的)。
    failed: (reason) => {
      if (state.failure === null) state.failure = String(reason)
    },
    schedule: (fn, ms) => {
      const timer = setTimeout(fn, ms)
      return () => clearTimeout(timer)
    },
  })

  // ① Dart 的 hello → TS 驱动器(它自己验设备、生成临时密钥、签 transcript、回 ack)。
  const hello = await probe.readFrame()
  assert.equal(hello['t'], 'hello')
  session.onFrame(hello as never)

  // ② Dart 的 confirm → TS 驱动器的两道校验 + 派生。
  const confirm = await probe.readFrame()
  assert.equal(confirm['t'], 'confirm')
  session.onFrame(confirm as never)
  await waitFor('TS 侧派生密钥', () => state.keys !== null || state.failure !== null)
  if (state.keys === null) {
    throw new Error(
      `握手没成立。TS 侧原因:${state.failure ?? '(未报)'}\nDart 侧 stderr:\n${probe.stderrText() || '(空)'}`,
    )
  }
  const tsKeys = state.keys

  // ③ Dart 封的业务帧 → TS 用**产品的箱**解开。
  const req = await probe.readFrame()
  assert.equal(req['t'], 'req')
  assert.equal(req['fc'], 0, '握手后第一帧业务帧的 fc 仍是 0')
  const tsCodec = createBoxCodec({ keys: tsKeys!, role: 'responder' })
  const opened = await tsCodec.openFrame(req as never, String(req['box']))
  assert.deepEqual(JSON.parse(opened), { method: 'repo.info' }, 'TS 解开了 Dart 封的那一箱')

  // ④ TS 封一个应答 → Dart 解开它(反方向)。
  // `sealFrame` 要的是**完整** WireFrame(它从帧上取 AAD 字段),所以 `ok` 与 `box`
  // 占位都要在;返回的箱再由我们替换上去。
  const replyHeader = {
    v: 1 as const,
    t: 'res' as const,
    id: String(req['id']),
    fc: 0,
    ok: true as const,
    box: '',
  }
  const replyBox = await tsCodec.sealFrame(replyHeader, JSON.stringify({ ok: true, protocol: 1 }))
  probe.writeLine(JSON.stringify({ ...replyHeader, box: replyBox }))

  // ⑤ Dart 打印双方派生密钥与解开的明文。
  const summary = await probe.readFrame()
  assert.equal(summary['master'], tsKeys!.master, '主密钥逐字节相同 —— transcript 拼串与 HKDF 输入一致')
  assert.equal(summary['kA2B'], tsKeys!.kA2B, 'A→B 方向密钥一致')
  assert.equal(summary['kB2A'], tsKeys!.kB2A, 'B→A 方向密钥一致')
  assert.deepEqual(
    JSON.parse(String(summary['opened'])),
    { ok: true, protocol: 1 },
    'Dart 解开了 TS 封的那一箱',
  )
})
