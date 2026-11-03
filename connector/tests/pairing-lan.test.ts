/**
 * 局域网配对的**请求形状**（`?pair=<offerId>&cand=<候选>`）。
 *
 * 这一层的价值全在"两侧各拼一遍"：手机按 `pairingDialUrl` 拼、电脑按 `readPairingRequest` 解，
 * 任何一侧的编码差异（padding、编码族、JSON 字段名）都只会表现成"握手超时"，
 * 而超时不会指向真因。所以往返必须逐字相等，且**解不出来时不许猜**。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { decodeCandidate, encodeCandidate, pairingDialUrl, readPairingRequest } from '../src/pairing-lan.js'
import type { PairingCandidate } from '../src/pairing.js'

const OFFER_ID = 'zyXWvUTSrqPONMLKjihgfe'
const candidate: PairingCandidate = {
  offerId: OFFER_ID,
  devPubEd: 'c'.repeat(64),
  devPubDh: 'd'.repeat(64),
  name: '我的手机',
}

/** 拨号地址 → 服务端看到的 `request.url`（只有路径与查询串）。 */
const requestUrlOf = (dialUrl: string): string => {
  const url = new URL(dialUrl)
  return `${url.pathname}${url.search}`
}

test('往返：手机拼出来的地址，电脑解得回同一个候选（含中文设备名）', () => {
  const dial = pairingDialUrl('ws://192.168.1.5:8790', candidate)
  const parsed = new URL(dial)
  assert.equal(parsed.protocol, 'ws:')
  assert.equal(parsed.host, '192.168.1.5:8790', '局域网地址原样保留（端口不能丢）')
  assert.equal(parsed.pathname, '/')

  const query = readPairingRequest(requestUrlOf(dial))
  assert.equal(query.offerId, OFFER_ID)
  assert.deepEqual(query.candidate, candidate, '解回来的候选必须逐字相等')
})

test('带路径的直连地址（反代后面）也照原样保留', () => {
  const dial = pairingDialUrl('wss://pc.example/direct', candidate)
  assert.equal(new URL(dial).pathname, '/direct')
  assert.deepEqual(readPairingRequest(requestUrlOf(dial)).candidate, candidate)
})

test('没有 ?pair= 的连接不是配对连接（普通直连照旧）', () => {
  assert.deepEqual(readPairingRequest('/'), { offerId: undefined, candidate: undefined })
  assert.deepEqual(readPairingRequest('/?foo=bar'), { offerId: undefined, candidate: undefined })
})

test('有 ?pair= 但候选解不出来：只报 offerId，不猜一个候选出来', () => {
  const cases = [
    `/?pair=${OFFER_ID}`,                                   // 缺 cand
    `/?pair=${OFFER_ID}&cand=`,                             // 空 cand
    `/?pair=${OFFER_ID}&cand=not-base64-json`,              // 解不开
    `/?pair=${OFFER_ID}&cand=${encodeCandidate({ ...candidate, offerId: 'AAAAAAAAAAAAAAAAAAAAAA' })}`, // 与 pair 不是同一个邀请
    `/?pair=${OFFER_ID}&cand=${encodeCandidate({ ...candidate, devPubEd: 'zz' })}`,                    // 公钥形状不对
    `/?pair=${OFFER_ID}&cand=${encodeCandidate({ ...candidate, name: 'x'.repeat(300) })}`,             // 设备名超长
  ]
  for (const url of cases) {
    const query = readPairingRequest(url)
    assert.equal(query.offerId, OFFER_ID, `${url} 的 offerId 要读出来（日志要靠它）`)
    assert.equal(query.candidate, undefined, `${url} 不该解出一个候选`)
  }
})

test('畸形请求不抛（监听面不能被一条坏 URL 带走）', () => {
  assert.doesNotThrow(() => readPairingRequest('http://[bad'))
  assert.doesNotThrow(() => readPairingRequest(''))
  assert.deepEqual(readPairingRequest('http://[bad'), { offerId: undefined, candidate: undefined })
})

test('候选编解码是纯函数：往返相等，坏输入回 undefined', () => {
  assert.deepEqual(decodeCandidate(encodeCandidate(candidate)), candidate)
  assert.equal(decodeCandidate('!!!'), undefined)
  assert.equal(decodeCandidate(Buffer.from('{"offerId":"x"}').toString('base64url')), undefined)
})
