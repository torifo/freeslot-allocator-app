import { compareStrings } from './hlc.js';
import { isDeleted, type Entity, type SyncDocumentJson } from './model.js';

export interface Violation {
  code: string;
  message: string;
}

/**
 * The rules the app UI otherwise guarantees, mirroring
 * lib/services/sync/invariant_checker.dart. Tombstones are ignored: the Dart
 * checker only sees live records. All times are UTC ISO strings, so string
 * comparison gives the right order.
 */
export function checkInvariants(doc: SyncDocumentJson): Violation[] {
  const out: Violation[] = [];
  const live = (list: Entity[] | undefined): Entity[] => (list ?? []).filter((e) => !isDeleted(e));

  const categories = (list: Entity[], kind: string) => {
    const names = new Set<string>();
    for (const c of live(list)) {
      const name = String(c.name);
      if (names.has(name)) {
        out.push({ code: 'duplicate_category_name', message: `${kind} has duplicate category "${name}"` });
        return;
      }
      names.add(name);
    }
  };
  categories(doc.taskMaster.mustDoCategories, 'mustDo');
  categories(doc.taskMaster.wantToDoCategories, 'wantToDo');

  const slots = live(doc.dailyPlan.slots);
  const slotById = new Map(slots.map((s) => [s.id, s]));
  for (const s of slots) {
    if (String(s.endAt) <= String(s.startAt)) {
      out.push({ code: 'slot_time_reversed', message: `slot ${s.id} ends before it starts` });
    }
  }

  const bySlot = new Map<string, Entity[]>();
  for (const a of live(doc.dailyPlan.assignments)) {
    const slotId = String(a.slotId);
    const list = bySlot.get(slotId) ?? [];
    list.push(a);
    bySlot.set(slotId, list);
    const slot = slotById.get(slotId);
    if (slot && (String(a.startAt) < String(slot.startAt) || String(a.endAt) > String(slot.endAt))) {
      out.push({ code: 'assignment_outside_slot', message: `assignment ${a.id} exceeds slot ${slot.id}` });
    }
  }
  for (const [slotId, list] of bySlot) {
    const byOrder = [...list].sort((x, y) => Number(x.sortOrder) - Number(y.sortOrder));
    if (byOrder.some((a, i) => Number(a.sortOrder) !== i)) {
      out.push({ code: 'sort_order_not_contiguous', message: `slot ${slotId} has gaps in sortOrder` });
    }
    const byStart = [...list].sort((x, y) => compareStrings(String(x.startAt), String(y.startAt)));
    for (let i = 1; i < byStart.length; i += 1) {
      if (String(byStart[i].startAt) < String(byStart[i - 1].endAt)) {
        out.push({ code: 'assignment_overlap', message: `assignments ${byStart[i - 1].id} and ${byStart[i].id} overlap` });
        break;
      }
    }
  }
  return out;
}
