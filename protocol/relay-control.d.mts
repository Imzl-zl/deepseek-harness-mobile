export const MAX_DEVICE_NAME_BYTES: number;
export const MAX_WIRE_BYTES: number;
export const MAX_PENDING_BYTES: number;
export const MAX_PAIRING_CANDIDATES: number;
export const CHANNEL_CONNECT_TIMEOUT_MS: number;
export interface PairingCandidate {
  readonly offerId: string;
  readonly devPubEd: string;
  readonly devPubDh: string;
  readonly name: string;
}
export type DeviceBinding =
  | { readonly connectorId: string; readonly deviceId: string; readonly purpose: 'paired' }
  | { readonly connectorId: string; readonly deviceId: string; readonly purpose: 'pairing'; readonly candidate: PairingCandidate };
export type RelayControl =
  | { readonly v: 1; readonly t: 'relay.open'; readonly channelId: string; readonly binding: DeviceBinding }
  | { readonly v: 1; readonly t: 'relay.close'; readonly channelId: string };
export function parsePairingCandidate(value: unknown): PairingCandidate | undefined;
export function deviceIdOf(candidate: Pick<PairingCandidate, 'devPubDh'>): string;
export function parseDeviceBinding(value: unknown): DeviceBinding | undefined;
export function parseRelayControl(raw: string): RelayControl | undefined;
