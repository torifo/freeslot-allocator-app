import { randomBytes } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { base45Decode, base45Encode, crc32, decodeFrames, encodeFrames, FrameSet, MAX_FRAMES } from '../src/qr-codec.js';

const ALNUM = /^[0-9A-Z $%*+\-./:]*$/;

describe('base45', () => {
  it('round-trips RFC 9285 vectors', () => {
    expect(base45Encode(Buffer.from('AB'))).toBe('BB8');
    expect(base45Encode(Buffer.from('Hello!!'))).toBe('%69 VD92EX0');
    expect(base45Encode(Buffer.from('base-45'))).toBe('UJCLQE7W581');
    expect(base45Decode('QED8WEX0').toString()).toBe('ietf!');
    expect(() => base45Decode('GGW')).toThrow();
  });
});

describe('crc32', () => {
  it('matches the standard check value', () => {
    expect(crc32(Buffer.from('123456789'))).toBe('CBF43926');
  });
});

describe('frames', () => {
  const doc = { version: 2, taskMaster: { tasks: Array.from({ length: 200 }, (_, i) => ({ id: `t${i}`, title: `タスク ${i}`, memo: 'x'.repeat(40) })) } };

  it('encodes into alphanumeric-only frames of <= 600 payload chars and decodes in any order', () => {
    const frames = encodeFrames(doc);
    expect(frames.length).toBeGreaterThan(1);
    for (const f of frames) { expect(f).toMatch(ALNUM); expect(f.split(':')[5].length).toBeLessThanOrEqual(600); expect(f.startsWith('FRL2:')).toBe(true); }
    const set = new FrameSet();
    for (const f of [...frames].reverse()) set.add(f);
    expect(set.isComplete).toBe(true);
    expect(set.received).toBe(frames.length);
    expect(decodeFrames(set)).toEqual(doc);
  });

  it('reports progress and ignores corrupted or foreign frames', () => {
    const frames = encodeFrames(doc);
    const set = new FrameSet();
    set.add(frames[0]);
    expect(set.total).toBe(frames.length);
    expect(set.missing()).toEqual(Array.from({ length: frames.length - 1 }, (_, i) => i + 1));
    const corrupted = frames[1].slice(0, -1) + (frames[1].endsWith('A') ? 'B' : 'A');
    expect(set.add(corrupted)).toBe('crc_mismatch');
    const foreign = encodeFrames({ other: true })[0];
    expect(set.add(foreign)).toBe('different_payload');
    expect(set.add(frames[0])).toBe('duplicate');
  });

  it('warns above 80 frames', () => {
    // Incompressible: a repeated character would gzip down to a single frame.
    const big = { blob: randomBytes(80 * 600).toString('hex').toUpperCase() };
    expect(() => encodeFrames(big, { maxFrames: 80 })).toThrow(/80 frames/);
  });
});

describe('frame validation', () => {
  const frame = (hash: string, i: number, n: number, chunk: string) => `FRL2:${hash}:${i}:${n}:${crc32(chunk)}:${chunk}`;

  it('rejects an absurd frame total instead of allocating it', () => {
    const set = new FrameSet();
    expect(set.add(frame('0123456789ABCDEF', 0, 2000000000, 'AB'))).toBe('malformed');
    expect(set.total).toBe(0);
    const started = Date.now();
    expect(set.missing()).toEqual([]);
    expect(Date.now() - started).toBeLessThan(500);
    expect(set.add(frame('0123456789ABCDEF', 0, MAX_FRAMES + 1, 'AB'))).toBe('malformed');
    expect(set.add(frame('0123456789ABCDEF', 0, MAX_FRAMES, 'AB'))).toBe('added');
  });

  it('rejects whitespace-padded or non-decimal indices', () => {
    const set = new FrameSet();
    expect(set.add('FRL2:0123456789ABCDEF: 1:3:00000000:')).toBe('malformed');
    expect(set.add('FRL2:0123456789ABCDEF:1: 3:00000000:')).toBe('malformed');
    expect(set.add('FRL2:0123456789ABCDEF:0x1:3:00000000:')).toBe('malformed');
    expect(set.add('FRL2:0123456789ABCDEF:-1:3:00000000:')).toBe('malformed');
    expect(set.add('FRL2:0123456789ABCDEF:1e2:3:00000000:')).toBe('malformed');
    expect(set.add(frame('0123456789ABCDEF', 0, 0, 'AB'))).toBe('malformed');
  });

  it('rejects a later frame whose total disagrees with the first frame', () => {
    const set = new FrameSet();
    expect(set.add(frame('0123456789ABCDEF', 0, 3, 'AB'))).toBe('added');
    expect(set.add(frame('0123456789ABCDEF', 1, 4, 'CD'))).toBe('different_payload');
    expect(set.total).toBe(3);
    expect(set.add(frame('0123456789ABCDEF', 1, 3, 'CD'))).toBe('added');
  });
});

describe('decode edge cases', () => {
  it('rejects a reassembled payload whose hash does not match the frames', () => {
    const frames = encodeFrames({ a: 1 });
    expect(frames.length).toBe(1);
    const parts = frames[0].split(':');
    const set = new FrameSet();
    expect(set.add(['FRL2', 'FFFFFFFFFFFFFFFF', parts[2], parts[3], parts[4], ...parts.slice(5)].join(':'))).toBe('added');
    expect(set.isComplete).toBe(true);
    expect(() => decodeFrames(set)).toThrow(/hash mismatch/);
  });

  it('handles empty and odd base45 input', () => {
    expect(base45Decode('').length).toBe(0);
    expect(() => base45Decode('0')).toThrow(/invalid base45 length/);
  });

  it('reassembles many single-character frames', () => {
    const doc = { hello: 'world', n: 42 };
    const frames = encodeFrames(doc, { chunkChars: 1 });
    expect(frames.length).toBeGreaterThan(20);
    expect(frames.length).toBeLessThanOrEqual(512);
    const set = new FrameSet();
    for (const f of [...frames].sort()) set.add(f);
    expect(decodeFrames(set)).toEqual(doc);
  });

  it('round-trips a frame whose chunk contains a colon', () => {
    const doc = { blob: randomBytes(400).toString('base64') };
    const frames = encodeFrames(doc);
    expect(frames.some((f) => f.split(':').slice(5).join(':').includes(':'))).toBe(true);
    const set = new FrameSet();
    for (const f of frames) expect(set.add(f)).toBe('added');
    expect(decodeFrames(set)).toEqual(doc);
  });
});
