/**
 * 最小 SMTP 客户端（只为发验证码邮件）。
 *
 * ## 为什么手写，不引 nodemailer
 *
 * 中转的运行时依赖一直只有 `ws` 一个。这封邮件只需要：EHLO、STARTTLS 或隐式 TLS、
 * AUTH PLAIN/LOGIN、MAIL/RCPT/DATA、QUIT。把这几步写出来约 200 行，边界都能用
 * 一个进程内假 SMTP 服务器测到；引一个包会多一条供应链，而它的模板/附件/池化
 * 我们一个都不用。
 *
 * ## 明确支持的子集
 *
 * - 465：隐式 TLS（`secure: true`）
 * - 587 / 2525 / 25：明文 + STARTTLS（`starttls: true`）
 * - AUTH PLAIN；服务器不认时退回 AUTH LOGIN
 * - 单收件人、UTF-8 主题（RFC 2047）、`multipart/alternative`（纯文本 + HTML）
 *
 * 不支持的（Outlook NTLM、OAuth2、批量收件人、附件）会在握手处明确失败，
 * 不静默退回"看起来发出去了"。
 */
import { once } from 'node:events'
import { connect as netConnect, type Socket } from 'node:net'
import { connect as tlsConnect, type TLSSocket } from 'node:tls'

export interface SmtpConfig {
  host: string
  port: number
  /** 465 的隐式 TLS。 */
  secure: boolean
  /** 587/25 的 STARTTLS。`secure` 为真时忽略。 */
  starttls: boolean
  user?: string
  pass?: string
  from: string
  fromName?: string
  timeoutMs?: number
}

export interface SmtpMessage {
  to: string
  subject: string
  text: string
  html: string
}

const b64 = (value: string): string => Buffer.from(value, 'utf8').toString('base64')
const wrap76 = (value: string): string => value.replace(/.{1,76}/g, (line) => `${line}\r\n`).trimEnd()
const encodedHeader = (value: string): string =>
  /^[\x20-\x7e]*$/.test(value) ? value : `=?UTF-8?B?${b64(value)}?=`

const assertHeaderSafe = (name: string, value: string): void => {
  if (/[\r\n]/.test(value)) throw new Error(`SMTP 头 ${name} 里有换行`)
}

function messageOf(config: SmtpConfig, message: SmtpMessage): string {
  assertHeaderSafe('From', config.from)
  assertHeaderSafe('FromName', config.fromName ?? '')
  assertHeaderSafe('To', message.to)
  assertHeaderSafe('Subject', message.subject)
  const boundary = `dsh-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`
  const fromName = config.fromName === undefined || config.fromName === ''
    ? ''
    : `${encodedHeader(config.fromName)} `
  const headers = [
    `From: ${fromName}<${config.from}>`,
    `To: <${message.to}>`,
    `Subject: ${encodedHeader(message.subject)}`,
    `Date: ${new Date().toUTCString()}`,
    `Message-ID: <${Date.now()}.${Math.random().toString(36).slice(2)}@${config.from.split('@')[1] ?? 'relay'}>`,
    'MIME-Version: 1.0',
    `Content-Type: multipart/alternative; boundary="${boundary}"`,
  ]
  const body = [
    '',
    `--${boundary}`,
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    wrap76(b64(message.text)),
    `--${boundary}`,
    'Content-Type: text/html; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    wrap76(b64(message.html)),
    `--${boundary}--`,
    '',
  ].join('\r\n')
  return `${headers.join('\r\n')}\r\n${body}`
}

/** 行读取器：SMTP 是行协议，先把 `\r\n` 切出来再谈状态机。 */
function lineReader(socket: Socket | TLSSocket): { readLine(): Promise<string> } {
  let buffer = ''
  let failure: Error | undefined
  let pending: { resolve: (line: string) => void; reject: (error: Error) => void } | undefined

  const flush = (): void => {
    if (pending === undefined) return
    const index = buffer.indexOf('\r\n')
    if (index === -1) return
    const line = buffer.slice(0, index)
    buffer = buffer.slice(index + 2)
    const waiter = pending
    pending = undefined
    waiter.resolve(line)
  }

  socket.on('data', (chunk: Buffer) => {
    buffer += chunk.toString('utf8')
    flush()
  })
  socket.on('error', (error: Error) => {
    failure = error
    const waiter = pending
    pending = undefined
    waiter?.reject(error)
  })
  socket.on('close', () => {
    const error = failure ?? new Error('SMTP 连接已关闭')
    const waiter = pending
    pending = undefined
    waiter?.reject(error)
  })

  return {
    readLine() {
      if (failure !== undefined) return Promise.reject(failure)
      const index = buffer.indexOf('\r\n')
      if (index !== -1) {
        const line = buffer.slice(0, index)
        buffer = buffer.slice(index + 2)
        return Promise.resolve(line)
      }
      return new Promise<string>((resolve, reject) => { pending = { resolve, reject } })
    },
  }
}

interface Reply { code: number; lines: string[] }

async function readReply(reader: { readLine(): Promise<string> }): Promise<Reply> {
  const lines: string[] = []
  for (;;) {
    const line = await reader.readLine()
    lines.push(line)
    if (/^\d{3}(?: |$)/.test(line)) return { code: Number(line.slice(0, 3)), lines }
    if (!/^\d{3}-/.test(line)) throw new Error(`SMTP 响应格式不认识：${line.slice(0, 120)}`)
  }
}

function describe(reply: Reply): string {
  return reply.lines.map((line) => line.slice(4)).join(' | ').slice(0, 300)
}

async function command(
  socket: Socket | TLSSocket,
  reader: { readLine(): Promise<string> },
  line: string,
  expected: readonly number[],
): Promise<Reply> {
  socket.write(`${line}\r\n`)
  const reply = await readReply(reader)
  if (!expected.includes(reply.code)) {
    throw new Error(`SMTP ${line.split(' ')[0]} 失败（${reply.code}）：${describe(reply)}`)
  }
  return reply
}

function connectSocket(config: SmtpConfig): Promise<Socket | TLSSocket> {
  return new Promise((resolve, reject) => {
    const socket = config.secure
      ? tlsConnect({ host: config.host, port: config.port, servername: config.host })
      : netConnect({ host: config.host, port: config.port })
    const event = config.secure ? 'secureConnect' : 'connect'
    const timer = setTimeout(() => {
      socket.destroy()
      reject(new Error(`SMTP 连接超时（${config.host}:${config.port}）`))
    }, config.timeoutMs ?? 10_000)
    socket.once(event, () => { clearTimeout(timer); resolve(socket) })
    socket.once('error', (error) => { clearTimeout(timer); reject(error) })
  })
}

async function authenticate(
  socket: Socket | TLSSocket,
  reader: { readLine(): Promise<string> },
  user: string,
  pass: string,
): Promise<void> {
  // PLAIN 优先：AhaSend/QQ/163 都认。
  const plain = await command(socket, reader, `AUTH PLAIN ${b64(`\u0000${user}\u0000${pass}`)}`, [235, 503]).catch(
    (error: unknown) => error,
  )
  if (!(plain instanceof Error)) return
  // 有些服务器要求先回 334 再给初始响应；再试一次不带参数的 PLAIN。
  try {
    const challenge = await command(socket, reader, 'AUTH PLAIN', [334])
    void challenge
    await command(socket, reader, b64(`\u0000${user}\u0000${pass}`), [235, 503])
    return
  } catch {
    // 最后退回 LOGIN（Outlook 系与部分老服务器）。
  }
  await command(socket, reader, 'AUTH LOGIN', [334])
  await command(socket, reader, b64(user), [334])
  await command(socket, reader, b64(pass), [235, 503])
}

/** 发一封。失败抛错（调用方决定是 502 还是记日志）。 */
export async function sendSmtpMail(config: SmtpConfig, message: SmtpMessage): Promise<void> {
  let socket: Socket | TLSSocket | undefined
  const timer = setTimeout(() => { socket?.destroy(new Error('SMTP 发送超时')) }, config.timeoutMs ?? 10_000)
  try {
    socket = await connectSocket(config)
    let reader = lineReader(socket)
    const greeting = await readReply(reader)
    if (greeting.code !== 220) throw new Error(`SMTP 问候失败（${greeting.code}）：${describe(greeting)}`)

    const ehlo = async (): Promise<void> => {
      const reply = await command(socket as Socket | TLSSocket, reader, 'EHLO dsh-relay', [250]).catch(
        async () => command(socket as Socket | TLSSocket, reader, 'HELO dsh-relay', [250]),
      )
      void reply
    }
    await ehlo()

    if (!config.secure && config.starttls) {
      await command(socket, reader, 'STARTTLS', [220])
      // 升级前摘掉旧监听：缓冲里剩下的字节属于明文段，TLS 握手之后由新 reader 接。
      socket.removeAllListeners('data')
      socket.removeAllListeners('error')
      socket.removeAllListeners('close')
      const upgraded = tlsConnect({ socket, servername: config.host })
      await once(upgraded, 'secureConnect')
      socket = upgraded
      reader = lineReader(socket)
      await ehlo()
    }

    if (config.user !== undefined && config.user !== '' && config.pass !== undefined && config.pass !== '') {
      await authenticate(socket, reader, config.user, config.pass)
    }

    await command(socket, reader, `MAIL FROM:<${config.from}>`, [250])
    await command(socket, reader, `RCPT TO:<${message.to}>`, [250, 251])
    await command(socket, reader, 'DATA', [354])

    const payload = messageOf(config, message)
    // 点填充：SMTP 的结束符是单独一行 `.`，正文里以点开头的行要再加一个点。
    const stuffed = payload.replace(/(^|\r\n)\./g, '$1..')
    socket.write(`${stuffed}\r\n.\r\n`)
    const accepted = await readReply(reader)
    if (accepted.code !== 250) throw new Error(`SMTP 拒收（${accepted.code}）：${describe(accepted)}`)

    socket.write('QUIT\r\n')
    await readReply(reader).catch(() => undefined)
  } finally {
    clearTimeout(timer)
    socket?.destroy()
  }
}

export function createSmtpMailer(config: SmtpConfig): { send(message: SmtpMessage): Promise<void> } {
  return {
    send(message) { return sendSmtpMail(config, message) },
  }
}
