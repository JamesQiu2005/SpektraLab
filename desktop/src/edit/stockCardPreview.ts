import { useEffect, useMemo, useRef, useState } from 'react';
import { rgbaToURL } from '../state/frames';
import { sessionStore, stockCardJob, useSession } from '../state/session';
import { JobEnded, runJob, scheduler } from '../scheduler';
import { imageReply, type RgbaImage } from '../host/replies';

const cache = new Map<string, RgbaImage>();
const CACHE_LIMIT = 64;

export function useStockCardPreview(kind: 'film' | 'paper', id: string | null, enabled: boolean) {
  const [element, ref] = useState<HTMLButtonElement | null>(null);
  const [visible, setVisible] = useState(false);
  const [display, setDisplay] = useState<{ key: string; url: string } | null>(null);
  const sidecar = useSession((s) => s.sidecar);
  const frame = useSession((s) => s.selection);
  const sid = useSession((s) => s.engineSession);
  const space = useSession((s) => s.displaySpace);
  const pair = useSession((s) => s.pair);
  const pairInfo = useSession((s) => s.pairInfo);
  const ready = useSession((s) => !!s.badge && !s.developing && !s.redecoding && !s.exportOpen && !s.batchExporting &&
    !s.pairPlacing && !!s.hello?.methods?.includes('render_stock_card') && (kind === 'film' || !s.sidecar.noFilm));

  useEffect(() => {
    if (!element || !enabled || !ready) return;
    const observer = new IntersectionObserver(([entry]) => setVisible(entry?.isIntersecting === true));
    observer.observe(element);
    return () => { observer.disconnect(); setVisible(false); };
  }, [element, enabled, ready]);

  // The reactive inputs cover both the source and the adjustments. Each card's key
  // is from the effective recipe so the independent row can reuse its previews.
  const card = useMemo(() => {
    const state = sessionStore.getState();
    if (!visible || !enabled || !ready || !sid || !frame || state.sidecar !== sidecar ||
        state.displaySpace !== space || state.pair !== pair || state.pairInfo !== pairInfo) return null;
    return stockCardJob(state, kind, id);
  }, [visible, enabled, ready, sid, frame, sidecar, space, pair, pairInfo, kind, id]);
  const key = card?.key ?? null;
  const job = useRef(card);
  useEffect(() => { job.current = card; }, [card]);

  useEffect(() => {
    if (!key) return;
    let disposed = false;
    let jobId: string | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let url: string | null = null;
    const load = async (retry = false) => {
      timer = undefined;
      let image = cache.get(key);
      if (!image) {
        const request = job.current;
        if (!request || request.key !== key) return;
        try {
          const result = await runJob(request.job, (id) => {
            if (disposed) void scheduler().cancel(id);
            else jobId = id;
          });
          if (disposed) return;
          image = imageReply(result.result, result.payload);
          if (image.width < 1 || image.height < 1 || Math.max(image.width, image.height) > 192) return;
        } catch (error) {
          if (!disposed && !retry && error instanceof JobEnded && error.cancelled)
            timer = setTimeout(() => void load(true), 240);
          return;
        } finally {
          jobId = undefined;
        }
      }
      cache.delete(key);
      cache.set(key, image);
      if (cache.size > CACHE_LIMIT) cache.delete(cache.keys().next().value!);
      const encoded = await rgbaToURL(image, 192);
      if (!encoded) return;
      if (disposed) URL.revokeObjectURL(encoded);
      else { url = encoded; setDisplay({ key, url }); }
    };

    timer = setTimeout(() => void load(), cache.has(key) ? 0 : 180);
    return () => {
      disposed = true;
      if (timer !== undefined) clearTimeout(timer);
      if (jobId) void scheduler().cancel(jobId);
      if (url) URL.revokeObjectURL(url);
    };
  }, [key, job]);

  return { ref, url: key && display?.key === key ? display.url : null };
}