// 中转控制面只有路由元数据；配对秘密与业务内容不得进入这里。
// 规范：docs/subsystems/pairing-v2.md。
import { createHash } from 'node:crypto';

export const MAX_DEVICE_NAME_BYTES = 256;
export const MAX_WIRE_BYTES = 8 * 1024 * 1024;
export const MAX_PENDING_BYTES = 64 * 1024;
export const MAX_PAIRING_CANDIDATES = 8;
export const CHANNEL_CONNECT_TIMEOUT_MS = 10_000;

const id = (value) => typeof value === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(value);
const token = (value) => typeof value === 'string' && /^[A-Za-z0-9_-]{22}$/.test(value);
const key = (value) => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const object = (value) => typeof value === 'object' && value !== null && !Array.isArray(value);

export function parsePairingCandidate(value) {
  if (!object(value) || !token(value.offerId) || !key(value.devPubEd) || !key(value.devPubDh)
    || typeof value.name !== 'string' || value.name.trim() === ''
    || Buffer.byteLength(value.name, 'utf8') > MAX_DEVICE_NAME_BYTES) return undefined;
  return { offerId: value.offerId, devPubEd: value.devPubEd, devPubDh: value.devPubDh, name: value.name };
}

export function deviceIdOf(candidate) {
  return createHash('sha256').update(candidate.devPubDh, 'utf8').digest().subarray(0, 16).toString('base64url');
}

export function parseDeviceBinding(value) {
  if (!object(value) || !id(value.connectorId) || !id(value.deviceId)) return undefined;
  if (value.purpose === 'paired') {
    return { connectorId: value.connectorId, deviceId: value.deviceId, purpose: 'paired' };
  }
  if (value.purpose !== 'pairing') return undefined;
  const candidate = parsePairingCandidate(value.candidate);
  if (candidate === undefined || value.deviceId !== deviceIdOf(candidate)) return undefined;
  return { connectorId: value.connectorId, deviceId: value.deviceId, purpose: 'pairing', candidate };
}

export function parseRelayControl(raw) {
  let value;
  try { value = JSON.parse(raw); } catch { return undefined; }
  if (!object(value) || value.v !== 1 || !id(value.channelId)) return undefined;
  if (value.t === 'relay.close') return { v: 1, t: 'relay.close', channelId: value.channelId };
  if (value.t !== 'relay.open') return undefined;
  const binding = parseDeviceBinding(value.binding);
  return binding === undefined ? undefined : { v: 1, t: 'relay.open', channelId: value.channelId, binding };
}
