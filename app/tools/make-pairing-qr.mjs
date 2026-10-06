/**
 * 出一张**真的**配对二维码载荷（调用真实的 connector 实现）。
 *
 * 用途：给安卓模拟器喂一份真载荷，验证"粘贴 → 解析 → 显示 SAS → 存密钥"这条链
 * 在真机上真的通（向量只证明了算法一致，没证明接线通）。
 *
 * 跑法：`node app/tools/make-pairing-qr.mjs`
 */
import { createPairing } from '../../connector/src/pairing.ts'

const pairing = createPairing({
  relayUrl: 'wss://relay.example.test/ws/connector',
  // 电脑侧公钥（固定值，便于两端对照 —— 真实运行时是随机生成的）。
  pcPubEd: 'aa'.repeat(32),
  pcPubDh: 'bb'.repeat(32),
})

const offer = pairing.offer()
console.log(offer.payload)
