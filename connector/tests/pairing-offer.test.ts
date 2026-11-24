/**
 * 出码入口的回归（契约 §12.1 第 1 步）。
 *
 * 两组用例：
 * - **顺序与失败行为**（都不会报错，只会让人排查错方向）：登记成功才给码；
 *   登记失败且没有局域网退路才不给码；登记用的值必须与码同源。
 * - **判据**（`planPairingOffer`）：码里写哪几条路由能力决定，没有"给谁用"这一档。
 *
 * 2026-11-24 起**没有斜杠命令**：面板是唯一入口，所以这里直接钉 `issuePairingOffer`
 * 的产物（载荷、`lanOnly`、`lanUrls`、`expiresAt`），不再解析命令文本。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { PAIRING_TTL_MS, createPairing } from '../src/pairing.js'
import { issuePairingOffer, planPairingOffer } from '../src/pairing-offer.js'
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

const payloadOf = (offer: { payload: string }): Record<string, unknown> =>
  JSON.parse(offer.payload) as Record<string, unknown>

test('登记成功才出码：载荷带中转地址、电脑公钥与一次性码', async () => {
  const { pairing, register, registered } = setup()
  const before = Date.now()
  const offer = await issuePairingOffer({ pairing, register })

  const payload = payloadOf(offer)
  assert.equal(payload['relay'], 'wss://relay.example/ws')
  assert.equal(payload['pcPubEd'], 'a'.repeat(64))
  assert.equal(typeof payload['code'], 'string')

  // 登记用的必须是**这张码的公开邀请**（否则中转绑不上，手机扫了也配不上）。
  assert.deepEqual(registered, [offer.offerId])
  // 有效期从常量算（写死数字会变成一句撒谎的提示）。
  assert.ok(offer.expiresAt >= before + PAIRING_TTL_MS - 1_000)
  assert.ok(offer.expiresAt <= Date.now() + PAIRING_TTL_MS + 1_000)
})

test('登记失败且没有局域网退路：**不出码**，抛出带中转原话的失败', async () => {
  const { pairing } = setup()
  await assert.rejects(
    () =>
      issuePairingOffer({
        pairing,
        register: () => Promise.reject(new Error('中转连不上')),
      }),
    (error: Error) => {
      assert.match(error.message, /未生成二维码/)
      // 文案要带**中转的原话**：只写"检查中转是否在运行"会把人引偏
      // （2026-11-03 的真因是中转按另一个 id 找电脑，字面却像"你没启动中转"）。
      assert.match(error.message, /中转连不上/)
      assert.match(error.message, /直连监听/, '没有中转时该指出另一条活路')
      return true
    },
  )
})

test('登记失败但有局域网地址：仍然出码，载荷标 lanOnly 并留声', async () => {
  const warnings: string[] = []
  const lan = ['ws://192.168.1.5:8790', 'ws://10.0.0.7:8790']
  const { pairing } = setup(undefined, () => lan)
  const offer = await issuePairingOffer({
    pairing,
    register: () => Promise.reject(new Error('中转连不上')),
    log: { ...silentLogger, warn: (message: string) => { warnings.push(message) } },
  })

  const payload = payloadOf(offer)
  assert.deepEqual(payload['lan'], lan, '二维码里必须带着**全部**局域网地址')
  // **降级必须写进载荷**（契约 §12.1）：手机据此显式提示，并跳过一条注定失败的换票。
  assert.equal(payload['lanOnly'], true, '载荷要标 lanOnly，不能只进日志')
  assert.equal(offer.lanOnly, true)
  assert.deepEqual(offer.routes, ['lan'], '码里不该还留着一个死掉的中转')

  assert.equal(warnings.length, 1, '降级要留声（否则"跨网配不上"没人知道为什么）')
  assert.match(warnings[0] ?? '', /只能走局域网直连/)
  assert.match(warnings[0] ?? '', /lanOnly/, '日志要能解释手机侧那条提示从哪来')

  // **登记仍然先试过**：中转可用时同一张码在跨网也能用，不能因为"有 lan"就跳过登记。
  const { pairing: healthy, register, registered } = setup(undefined, () => lan)
  const ok = await issuePairingOffer({ pairing: healthy, register })
  assert.deepEqual(registered, [ok.offerId])
  assert.equal(ok.lanOnly, false, '登记成功时不降级')
  assert.deepEqual(ok.routes, ['lan', 'relay'], '正面也要说：两条路都在')
})

test('一次出码只登记一次，且用的是**这一次**的邀请（重新出码换一个）', async () => {
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

  await issuePairingOffer({ pairing, register })
  await issuePairingOffer({ pairing: pairing2, register })
  assert.equal(registered.length, 2)
  assert.notEqual(registered[0], registered[1], '两次出码的邀请不同（码不同）')
})

// ---- 此刻有哪几条腿（2026-11-13：出码不再永远带中转） ----

test('此刻没有中转那条腿（withRelay=false）：**不登记**，载荷 routes 只留 lan', async () => {
  const lan = ['ws://192.168.1.5:8790']
  const { pairing } = setup(undefined, () => lan)
  let registered = 0
  const offer = await issuePairingOffer({
    pairing,
    register: () => {
      registered += 1
      return Promise.resolve()
    },
    withRelay: false,
  })

  assert.deepEqual(payloadOf(offer)['routes'], ['lan'], '码里不该还留着一个 relay')
  assert.equal(payloadOf(offer)['lanOnly'], true, '只有局域网那一档的显式标记')
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
  const offer = await issuePairingOffer({
    pairing,
    register: () => {
      registered += 1
      return Promise.resolve()
    },
  })

  assert.deepEqual(payloadOf(offer)['routes'], ['lan'], '承诺必须与"此刻活着"一致')
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

test('直连开着但没有局域网地址：文案必须复述这个原因，不能笼统说"没开"', () => {
  const reason = '直连监听已启动，但没有局域网 IPv4 地址'
  assert.throws(
    () => planPairingOffer({ lanAvailable: false, relayConnected: false, lanReason: reason }),
    (error: Error) => error.message.includes(reason)
      && !error.message.includes('直连监听未启动'),
  )
})
