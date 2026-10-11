/** 监听面、中转数据面和集成测试共用的真实设备装配。
 * 待配对身份只存在于该连接，不能进入普通方法面。
 */
import type { DeviceBinding } from '../../protocol/relay-control.mjs'
import { createConnectionScope, type ConnectionScope, type ConnectionScopeDeps } from './connection-scope.js'
import { createConnection, type Connection } from './transport/connection.js'
import { createHandshakeDriver, type HandshakePeer } from './protocol/handshake-driver.js'
import { createBoxCodec } from './protocol/box.js'
import { type deriveIdentity } from './protocol/crypto.js'
import { PAIRING_KEY_INFO, pairingHandshakeContext, type Pairing } from './pairing.js'
import type { PairingEndpoint } from './pairing-endpoint.js'
import { METRIC } from './observability.js'

export interface DeviceConnectionOptions {
  identity: ReturnType<typeof deriveIdentity>
  pcId: string
  peerOf(devId: string): HandshakePeer | undefined
  pairing: Pairing
  enrollment: PairingEndpoint
  scope: ConnectionScopeDeps
  binding?: DeviceBinding
}

export function createDeviceConnection(options: DeviceConnectionOptions): Connection {
  const { identity, binding, scope: deps } = options
  const candidate = binding?.purpose === 'pairing' ? binding.candidate : undefined
  let scope: ConnectionScope | null = null
  const scopeOf = (): ConnectionScope => {
    if (scope === null) throw new Error('设备连接在装配就绪前收到回调')
    return scope
  }
  const connection = createConnection({
    url: '',
    dial: () => { throw new Error('数据连接必须由监听面或中转控制面建立') },
    log: deps.logger,
    secure: {
      handshake: createHandshakeDriver({
        identity: { dh: identity.dh, signSeedHex: identity.signSeedHex },
        pcId: options.pcId,
        peerOf: (devId) => {
          if (binding !== undefined && devId !== binding.deviceId) return undefined
          if (candidate !== undefined) {
            if (!options.pairing.allows(candidate)) return undefined
            return { edPubHex: candidate.devPubEd, dhPubHex: candidate.devPubDh, pairingId: candidate.offerId }
          }
          return options.peerOf(devId)
        },
        ...(candidate === undefined ? {} : {
          keyInfo: PAIRING_KEY_INFO,
          transcriptContext: pairingHandshakeContext({
            pcId: options.pcId, pcPubEd: identity.sign.publicKeyHex, pcPubDh: identity.dh.publicKeyHex,
          }, candidate),
        }),
      }),
      createCipher: (keys) => createBoxCodec({ keys, role: 'responder' }),
    },
    onEstablished: ({ devId }) => {
      deps.metrics.increment(METRIC.handshakesEstablished)
      if (candidate === undefined) {
        scopeOf().deviceEstablished(devId)
        deps.logger.info(`设备 ${devId} 已建立业务加密连接`)
      } else {
        scopeOf().pairingEstablished()
        deps.logger.info('候选已建立受限配对通道，尚未授予业务权限')
      }
    },
    onStateChange: (from, to) => {
      deps.metrics.increment(METRIC.stateTransitions)
      if (to === 'connecting') deps.metrics.increment(METRIC.connects)
      if (from === 'serving' && to !== 'serving') scopeOf().servingEnded()
    },
    onFrame: (frame) => {
      deps.metrics.increment(METRIC.inboundFrames)
      scopeOf().handleFrame(frame)
    },
  })
  scope = createConnectionScope(connection, deps,
    candidate === undefined ? undefined : { candidate, endpoint: options.enrollment })
  return connection
}
