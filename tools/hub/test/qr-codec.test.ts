import { randomBytes } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { base45Decode, base45Encode, crc32, decodeFrames, encodeFrames, FrameSet } from '../src/qr-codec.js';

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
