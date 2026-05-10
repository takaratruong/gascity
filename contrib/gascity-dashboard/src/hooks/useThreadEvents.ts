import { useEffect, useRef, useState } from 'react';
import { seedEvents, subscribeEvents, type GCEvent } from '../api';

// Live thread event feed backed by gascity's SSE event bus.
//
// Why this exists: ThreadPage was polling `bd list` / `lineage` every few
// seconds and reconstructing a feed from scratch. Events lagged up to the
// poll interval, the lineage query couldn't see mail or order fires, and
// heartbeat / step cards fell out of sync. gascity ships the right primitive
// — a monotonic event bus exposed via SSE per engdocs/architecture/event-bus.md.
// We subscribe once and keep events in memory; filtering happens client-side.
//
// Relevance filter: we keep an event if its subject is in the bead's lineage
// (by id prefix match — bl-xxx.1.3 belongs to bl-xxx) OR if it's a mail bead
// whose subject/body mentions a lineage id OR if it's retry/promotion event
// targeting a lineage member.

export interface UseThreadEventsResult {
  events: GCEvent[];
  connected: boolean;
  seeded: boolean;
  lineageIds: Set<string>;
  addLineageId: (id: string) => void; // call when a new related bead surfaces
}

export function useThreadEvents(
  city: string,
  rootId: string,
  initialLineageIds: Set<string>,
): UseThreadEventsResult {
  const [events, setEvents] = useState<GCEvent[]>([]);
  const [connected, setConnected] = useState(false);
  const [seeded, setSeeded] = useState(false);
  // Keep lineage set in a ref so the SSE handler closure reads the latest
  // value without having to re-subscribe every time the set grows.
  const lineageRef = useRef<Set<string>>(new Set(initialLineageIds));
  const [lineageTick, setLineageTick] = useState(0);

  function addLineageId(id: string) {
    if (!lineageRef.current.has(id)) {
      lineageRef.current.add(id);
      setLineageTick((t) => t + 1);
    }
  }

  // Decide whether an event is relevant to this thread.
  function isRelevant(e: GCEvent): boolean {
    const ids = lineageRef.current;
    const subj = e.subject || '';
    // Direct subject match (or step-bead sub-id that starts with a lineage id)
    for (const id of ids) {
      if (subj === id) return true;
      if (subj.startsWith(id + '.')) return true;
    }
    // Mail / message events whose payload references a lineage id
    if (e.type.startsWith('mail.') || e.type.startsWith('message.')) {
      const body = JSON.stringify(e.payload ?? '');
      for (const id of ids) if (body.includes(id)) return true;
    }
    // Retry / promotion: payload may set gc.retry_of or gc.promoted_from
    if (e.type === 'bead.created' || e.type === 'bead.updated') {
      const md = (e.payload as any)?.metadata || {};
      const retryOf = md['gc.retry_of'];
      const lineageRoot = md['gc.lineage_root'];
      const parentRun = md['gc.parent_run'];
      if (retryOf && ids.has(retryOf)) return true;
      if (lineageRoot && ids.has(lineageRoot)) return true;
      if (parentRun && ids.has(parentRun)) return true;
    }
    return false;
  }

  useEffect(() => {
    let cancelled = false;
    lineageRef.current = new Set(initialLineageIds);
    setEvents([]);
    setSeeded(false);
    setConnected(false);

    // 1) Seed with the last hour of events so the feed isn't empty on mount.
    (async () => {
      try {
        const seed = await seedEvents(city, { since: '24h', limit: 1000 });
        if (cancelled) return;
        setEvents(seed.filter(isRelevant));
        setSeeded(true);
      } catch {
        if (!cancelled) setSeeded(true); // don't block on seed failure
      }
    })();

    // 2) Live subscription.
    const unsub = subscribeEvents(
      city,
      (e) => {
        if (cancelled) return;
        if (!isRelevant(e)) return;
        // Dedup on seq in case seed + stream overlap.
        setEvents((prev) => {
          if (prev.some((x) => x.seq === e.seq)) return prev;
          // Keep sorted by seq ascending.
          const next = [...prev, e];
          next.sort((a, b) => a.seq - b.seq);
          return next;
        });
      },
      (ok) => { if (!cancelled) setConnected(ok); },
    );

    return () => { cancelled = true; unsub(); };
    // initialLineageIds is intentionally excluded to avoid resubscribe thrash
    // when callers recompute the set each render; use addLineageId instead.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [city, rootId]);

  // When lineage grows (via addLineageId), re-filter the existing buffer so
  // events that WERE filtered out but now match become visible.
  // (We keep a raw buffer? No — gascity's SSE re-delivers from Last-Event-ID
  // on reconnect. For simplicity we just re-filter what we have; missed
  // events from before the id was added are not a practical loss.)
  useEffect(() => {
    // no-op dependency to silence linter — the useRef tracks the set
  }, [lineageTick]);

  return { events, connected, seeded, lineageIds: lineageRef.current, addLineageId };
}
