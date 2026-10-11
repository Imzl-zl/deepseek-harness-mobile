/** 生产只用 WSS；本机明文必须由调用方显式允许。 */
export function relayUrlOf(value: string, allowInsecureLocal = false): URL {
  const url = new URL(value)
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
  if (url.username !== '' || url.password !== '' || url.hash !== '' || url.search !== '') {
    throw new Error('中转地址不能包含凭据、查询参数或片段')
  }
  if (url.protocol !== 'wss:' && !(allowInsecureLocal && loopback && url.protocol === 'ws:')) {
    throw new Error('中转必须使用 WSS；仅显式开启的本机调试允许明文')
  }
  return url
}
