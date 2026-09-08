import { createHash } from 'node:crypto';
import { gunzipSync, gzipSync } from 'node:zlib';

const B45 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

/** RFC 9285 base45: every output character is in the QR alphanumeric set. */
export function base45Encode(buf: Buffer): string {
  let out = '';
  for (let i = 0; i < buf.length; i += 2) {
    if (i + 1 < buf.length) {
      const n = buf[i] * 256 + buf[i + 1];
      const e = Math.floor(n / (45 * 45)); const d = Math.floor((n % (45 * 45)) / 45); const c = n % 45;
      out += B45[c] + B45[d] + B45[e];
    } else {
      const n = buf[i]; out += B45[n % 45] + B45[Math.floor(n / 45)];
    }
  }
  return out;
}

export function base45Decode(text: string): Buffer {
  const vals = [...text].map((ch) => { const v = B45.indexOf(ch); if (v < 0) throw new Error(`invalid base45 char ${JSON.stringify(ch)}`); return v; });
  const out: number[] = [];
  for (let i = 0; i < vals.length; i += 3) {
    if (i + 2 < vals.length) {
      const n = vals[i] + vals[i + 1] * 45 + vals[i + 2] * 45 * 45;
      if (n > 0xffff) throw new Error('invalid base45 triplet');
      out.push(n >> 8, n & 0xff);
    } else if (i + 1 < vals.length) {
      const n = vals[i] + vals[i + 1] * 45;
      if (n > 0xff) throw new Error('invalid base45 pair');
      out.push(n);
    } else throw new Error('invalid base45 length');
  }
  return Buffer.from(out);
}

const CRC_TABLE = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n += 1) { let c = n; for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();

export function crc32(buf: Buffer | string): string {
  const b = typeof buf === 'string' ? Buffer.from(buf, 'utf8') : buf;
  let c = 0xffffffff;
  for (const byte of b) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return ((c ^ 0xffffffff) >>> 0).toString(16).toUpperCase().padStart(8, '0');
}

export const CHUNK_CHARS = 600;
export interface EncodeOptions { chunkChars?: number; maxFrames?: number }

/** `FRL2:<sha16>:<i>:<n>:<crc>:<chunk>` — all characters in the QR alphanumeric set. */
export function encodeFrames(value: unknown, options: EncodeOptions = {}): string[] {
  const chunkChars = options.chunkChars ?? CHUNK_CHARS;
  const json = Buffer.from(JSON.stringify(value), 'utf8');
  const text = base45Encode(gzipSync(json, { level: 9 }));
  const hash = createHash('sha256').update(json).digest('hex').slice(0, 16).toUpperCase();
  const total = Math.max(1, Math.ceil(text.length / chunkChars));
  if (options.maxFrames && total > options.maxFrames) throw new Error(`payload needs ${total} frames, more than ${options.maxFrames} frames; use LAN sync instead`);
  const frames: string[] = [];
  for (let i = 0; i < total; i += 1) {
    const chunk = text.slice(i * chunkChars, (i + 1) * chunkChars);
    const frame = `FRL2:${hash}:${i}:${total}:${crc32(chunk)}:${chunk}`;
    if (!/^[0-9A-Z $%*+\-./:]*$/.test(frame)) throw new Error('frame contains a non-alphanumeric-mode character');
    frames.push(frame);
  }
  return frames;
}

export type AddResult = 'added' | 'duplicate' | 'crc_mismatch' | 'different_payload' | 'malformed';

/** Accumulates scanned frames in any order and reports what is still missing. */
export class FrameSet {
  hash: string | null = null;
  total = 0;
  private chunks = new Map<number, string>();

  get received(): number { return this.chunks.size; }
  get isComplete(): boolean { return this.total > 0 && this.chunks.size === this.total; }
  missing(): number[] { return Array.from({ length: this.total }, (_, i) => i).filter((i) => !this.chunks.has(i)); }
  chunkAt(index: number): string | undefined { return this.chunks.get(index); }

  add(frame: string): AddResult {
    // base45 itself uses ':', so only the first five colons are delimiters.
    const parts = frame.split(':');
    if (parts.length < 6 || parts[0] !== 'FRL2') return 'malformed';
    const [, hash, iStr, nStr, crc] = parts;
    const chunk = parts.slice(5).join(':');
    const i = Number(iStr); const n = Number(nStr);
    if (!Number.isInteger(i) || !Number.isInteger(n) || i < 0 || i >= n) return 'malformed';
    if (this.hash && this.hash !== hash) return 'different_payload';
    if (crc32(chunk) !== crc) return 'crc_mismatch';
    if (!this.hash) { this.hash = hash; this.total = n; }
    if (this.chunks.has(i)) return 'duplicate';
    this.chunks.set(i, chunk);
    return 'added';
  }

  reset(): void { this.hash = null; this.total = 0; this.chunks.clear(); }
}

export function decodeFrames(set: FrameSet): unknown {
  if (!set.isComplete) throw new Error(`incomplete: missing frames ${set.missing().join(',')}`);
  const text = Array.from({ length: set.total }, (_, i) => set.chunkAt(i)!).join('');
  const json = gunzipSync(base45Decode(text));
  const hash = createHash('sha256').update(json).digest('hex').slice(0, 16).toUpperCase();
  if (hash !== set.hash) throw new Error('payload hash mismatch after reassembly');
  return JSON.parse(json.toString('utf8'));
}
