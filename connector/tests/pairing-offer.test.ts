/**
 * 出码入口的回归（契约 §12.1 第 1 步）。
 *
 * 两组用例：
 * - **顺序与失败行为**（都不会报错，只会让人排查错方向）：登记成功才给码；
 *   登记失败且没有局域网退路才不给码；登记用的值必须与码同源。
 * - **判据**（`planPairingOffer`）：码里写哪几条路由能力决定，没有"给谁用"这一档。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { PAIRING_TTL_MS, createPairing, pairingCodeHash } from '../src/pairing.js'
import { offerForScanning, issuePairingOffer, planPairingOffer } from '../src/pairing-offer.js'
import { silentLogger } from '../src/observability.js'

function setup(registerImpl?: (codeHash: string) => Promise<void>, lanUrls?: () => readonly string[]) {
  let sequence = 0
  const pairing = createPairing({
    pcId: 'pc-1',
    relayUrl: 'wss://relay.example/ws',
    pcPubEd: 'a'.repeat(64),
    pcPubDh: 'b'.repeat(64),
    randomBytes: (size) => Uint8Array.from({ length: size }, () => ++sequence % 256),
    ...(lanUrls === undefined ? {} : { lanUrls }),
  })
  const registered: string[] = []
  const register =
    registerImpl ??
    ((codeHash: string) => {
      registered.push(codeHash)
      return Promise.resolve()
    })
  return { pairing, register, registered }
}

test('登记成功才出码：命令结果里带二维码载荷（含码与电脑公钥）', async () => {
  const { pairing, register, registered } = setup()
  const result = await offerForScanning({ pairing, register })

  assert.equal(result.kind, 'success')
  const payload = JSON.parse(result.text.split('\n')[1] ?? '') as Record<string, unknown>
  assert.equal(payload['relay'], 'wss://relay.example/ws')
  assert.equal(payload['pcPubEd'], 'a'.repeat(64))
  assert.equal(typeof payload['code'], 'string')

  // 登记用的必须是**这张码的哈希**（否则中转绑不上，手机扫了也配不上）。
  assert.deepEqual(registered, [payload['offerId']])
  assert.notEqual(registered[0], pairingCodeHash(String(payload['code'])), '登记值不能充当授权校验值')
  // 没有局域网地址时也要说清"这条码走中转，且已登记"（正面提示，不只是失败时说话）。
  assert.match(result.text, /路径：仅中转（已登记）/)
})

test('登记失败：**不出码**，回一个说明原因的结果（而不是给一张配不上的二维码）', async () => {
  const { pairing } = setup(() => Promise.reject(new Error('中转连不上')))
  const result = await offerForScanning({ pairing, register: () => Promise.reject(new Error('中转连不上')) })

  assert.equal(result.kind, 'error')
  assert.match(result.text, /未生成二维码/)
  // 文案里要带上**中转的原话**：只写"检查中转是否在运行"会把人引偏
  // （2026-11-03 的真因是中转按另一个 id 找电脑，字面却像"你没启动中转"）。
  assert.match(result.text, /中转连不上/)
  assert.match(result.text, /直连监听/, '没有中转时该指出另一条活路')
  // 关键：失败结果里**不许**夹带任何码/载荷（否则操作者可能照着它去扫）。
  assert.equal(/[A-Za-z0-9_-]{22}/.test(result.text), false, '失败文案里不许出现码')
  assert.equal(result.text.includes('pcPubEd'), false, '也不许出现载荷片段')
})

test('登记失败但有局域网地址：仍然出码，但载荷标 lanOnly，且三处都说清"只能局域网"', async () => {
  const warnings: string[] = []
  const lan = ['ws://192.168.1.5:8790', 'ws://10.0.0.7:8790']
  const { pairing } = setup(() => Promise.reject(new Error('中转连不上')), () => lan)
  const result = await offerForScanning({
    pairing,
    register: () => Promise.reject(new Error('中转连不上')),
    log: { ...silentLogger, warn: (message) => { warnings.push(message) } },
  })

  assert.equal(result.kind, 'success', '手机能直连，就不该把出码拦下来')
  const payload = JSON.parse(result.text.split('\n')[1] ?? '') as Record<string, unknown>
  assert.deepEqual(payload['lan'], lan, '二维码里必须带着局域网地址')
  // **降级必须写进载荷**（契约 §12.1）：手机据此显式提示，并跳过一条注定失败的换票。
  assert.equal(payload['lanOnly'], true, '载荷要标 lanOnly，不能只进日志')
  assert.match(result.text, /须在同一 WiFi 下扫码/, '命令输出要说明这次降级了')
  assert.match(result.text, /局域网直连/, '仍要给出这张码实际能走的地址')

  assert.equal(warnings.length, 1, '降级要留声（否则"跨网配不上"没人知道为什么）')
  assert.match(warnings[0] ?? '', /只能走局域网直连/)
  assert.match(warnings[0] ?? '', /lanOnly/, '日志要能解释手机侧那条提示从哪来')

  // **登记仍然先试过**：中转可用时同一张码在跨网也能用，不能因为"有 lan"就跳过登记。
  const { pairing: healthy, register, registered } = setup(undefined, () => lan)
  const ok = await offerForScanning({ pairing: healthy, register })
  const okPayload = JSON.parse(ok.kind === 'success' ? ok.text.split('\n')[1] ?? '' : '{}') as Record<string, unknown>
  assert.deepEqual(registered, [okPayload['offerId']])
  assert.equal(okPayload['lanOnly'], undefined, '登记成功时载荷里不该出现 lanOnly')
  // **正面也要说**：用户要能判断"出门还能不能用"，而不是从"没有警告"去猜。
  assert.match(
    ok.kind === 'success' ? ok.text : '',
    /路径：局域网直连 \+ 中转（已登记）/,
  )
})

test('成功文案里的有效期**从常量算**（写死数字会变成一句撒谎的提示）', async () => {
  const { pairing, register } = setup()
  const result = await offerForScanning({ pairing, register })
  assert.equal(result.kind, 'success')
  const minutes = Math.round(PAIRING_TTL_MS / 60_000)
  assert.match(
    result.text,
    new RegExp(`${minutes} 分钟`),
    '文案与 PAIRING_TTL_MS 必须同源：改常量而不改文案，操作者会按过期的时间安排',
  )
})

test('一次出码只登记一次，且用的是**这一次**的哈希（重新出码换哈希）', async () => {
  const { pairing, register, registered } = setup()
  let round = 0
  const pairing2 = createPairing({
    pcId: 'pc-1',
    relayUrl: 'wss://relay.example/ws',
    pcPubEd: 'a'.repeat(64),
    pcPubDh: 'b'.repeat(64),
    randomBytes: (size) => {
      round += 1
      return Uint8Array.from({ length: size }, (_, i) => (round * 53 + i) % 256)
    },
  })

  await offerForScanning({ pairing, register })
  await offerForScanning({ pairing: pairing2, register })
  assert.equal(registered.length, 2)
  assert.notEqual(registered[0], registered[1], '两次出码的哈希不同（码不同）')
})

// ---- 这张码给谁用（2026-11-13：出码不再永远带中转） ----

test('此刻没有中转那条腿（withRelay=false）：**不登记**，载荷 routes 只留 lan', async () => {
  const lan = ['ws://192.168.1.5:8790']
  const { pairing } = setup(undefined, () => lan)
  let registered = 0
  const result = await offerForScanning({
    pairing,
    register: () => {
      registered += 1
      return Promise.resolve()
    },
    withRelay: false,
  })

  assert.equal(result.kind, 'success')
  const payload = JSON.parse(result.text.split('\n')[1] ?? '') as Record<string, unknown>
  assert.deepEqual(payload['routes'], ['lan'], '码里不该还留着一个 relay')
  assert.equal(payload['lanOnly'], true, '只有局域网那一档的显式标记')
  assert.equal(registered, 0, '没人会去换的票不该登记')
})

test('中转没连上（relayAvailable=false）：码里不含 relay，即使登记会成功', async () => {
  const lan = ['ws://192.168.1.5:8790']
  let sequence = 0
  const pairing = createPairing({
    pcId: 'pc-1',
    relayUrl: 'wss://relay.example/ws',
    pcPubEd: 'a'.repeat(64),
    pcPubDh: 'b'.repeat(64),
    randomBytes: (size) => Uint8Array.from({ length: size }, () => ++sequence % 256),
    lanUrls: () => lan,
    // 控制面没连上：登记仍可能成功（只验令牌），但那张票换来的路是死的。
    relayAvailable: () => false,
  })
  let registered = 0
  const result = await offerForScanning({
    pairing,
    register: () => {
      registered += 1
      return Promise.resolve()
    },
  })

  assert.equal(result.kind, 'success')
  const payload = JSON.parse(result.text.split('\n')[1] ?? '') as Record<string, unknown>
  assert.deepEqual(payload['routes'], ['lan'], '承诺必须与"此刻活着"一致')
  assert.equal(registered, 0, '中转那条腿不在，登记没有意义')
})

// ---- 出码判据（planPairingOffer）：没有"这张码给谁用"这一档，只看能力 ----

test('两条腿都在：带中转、登记（这是唯一会登记的情形）', () => {
  assert.deepEqual(
    planPairingOffer({ lanAvailable: true, relayConnected: true }),
    { withRelay: true },
  )
})

test('只有直连：不带中转，也不登记', () => {
  assert.deepEqual(
    planPairingOffer({ lanAvailable: true, relayConnected: false }),
    { withRelay: false },
  )
})

test('只有中转：照出（直连没开不是拒绝出码的理由）', () => {
  assert.deepEqual(
    planPairingOffer({ lanAvailable: false, relayConnected: true }),
    { withRelay: true },
  )
})

test('两条都没有：拒绝出码，且分别说清缺哪条', () => {
  assert.throws(
    () => planPairingOffer({ lanAvailable: false, relayConnected: false, lanReason: '直连监听未启动' }),
    (error: Error) => /无法生成配对码/.test(error.message)
      && /直连监听未启动/.test(error.message)
      && /中转未连接/.test(error.message),
  )
})

test('直连开着但没有可上报地址：文案必须复述这个原因，不能笼统说"没开"', () => {
  const reason = '直连监听已启动，但没有可上报的地址（默认路由不可用，或主地址已被隐藏）'
  assert.throws(
    () => planPairingOffer({ lanAvailable: false, relayConnected: false, lanReason: reason }),
    (error: Error) => error.message.includes(reason)
      && !error.message.includes('直连监听未启动'),
  )
})
