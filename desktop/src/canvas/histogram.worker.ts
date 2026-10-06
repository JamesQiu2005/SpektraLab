import { computeHistogram } from './histogram';

self.onmessage = (e: MessageEvent<{ id: number; px: Uint8Array }>) => {
  const h = computeHistogram(e.data.px);
  (self as unknown as Worker).postMessage({ id: e.data.id, h });
};
