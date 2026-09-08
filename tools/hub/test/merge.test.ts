import { describe, expect, it } from 'vitest';
import { merge } from '../src/merge.js';
import { emptyDocument, type SyncDocumentJson } from '../src/model.js';

const doc = (extra: Partial<SyncDocumentJson> = {}): SyncDocumentJson => ({
  ...emptyDocument('hub-0000', new Date('2026-09-08T00:00:00.000Z')),
  ...extra,
});

describe('merge envelope timestamps', () => {
  it('does not adopt a +09:00 purgedBefore that is earlier than the hub Z value', () => {
    // '2026-09-08T09:00:00+09:00' sorts after '2026-09-08T06:00:00.000Z'
    // lexicographically but is the earlier instant (00:00Z vs 06:00Z).
    const hub = doc({ purgedBefore: '2026-09-08T06:00:00.000Z' });
    const phone = doc({ purgedBefore: '2026-09-08T09:00:00+09:00' });
    expect(merge(hub, phone).document.purgedBefore).toBe('2026-09-08T06:00:00.000Z');
  });

  it('normalizes an adopted offset purgedBefore to UTC ISO', () => {
    const hub = doc({ purgedBefore: '2026-09-08T00:00:00.000Z' });
    const phone = doc({ purgedBefore: '2026-09-08T18:00:00+09:00' });
    expect(merge(hub, phone).document.purgedBefore).toBe('2026-09-08T09:00:00.000Z');
  });

  it('adopts a far-future purgedBefore from the phone (max is monotonic by design)', () => {
    const hub = doc({ purgedBefore: '2026-09-08T00:00:00.000Z' });
    const phone = doc({ purgedBefore: '2099-01-01T00:00:00.000Z' });
    expect(merge(hub, phone).document.purgedBefore).toBe('2099-01-01T00:00:00.000Z');
  });

  it('keeps the parsable side when the other purgedBefore is unparsable or null', () => {
    const good = '2026-09-08T00:00:00.000Z';
    expect(merge(doc({ purgedBefore: good }), doc({ purgedBefore: 'not-a-date' })).document.purgedBefore).toBe(good);
    expect(merge(doc({ purgedBefore: 'not-a-date' }), doc({ purgedBefore: good })).document.purgedBefore).toBe(good);
    expect(merge(doc({ purgedBefore: good }), doc({ purgedBefore: null })).document.purgedBefore).toBe(good);
    expect(merge(doc({ purgedBefore: null }), doc({ purgedBefore: good })).document.purgedBefore).toBe(good);
    expect(merge(doc({ purgedBefore: null }), doc({ purgedBefore: null })).document.purgedBefore).toBeNull();
  });

  it('compares exportedAt as an instant, not lexicographically', () => {
    const hub = doc({ exportedAt: '2026-09-08T06:00:00.000Z' });
    const phone = doc({ exportedAt: '2026-09-08T09:00:00+09:00' });
    expect(merge(hub, phone).document.exportedAt).toBe('2026-09-08T06:00:00.000Z');
    expect(merge(phone, hub).document.exportedAt).toBe('2026-09-08T06:00:00.000Z');
  });
});
