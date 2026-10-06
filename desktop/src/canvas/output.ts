// output.ts — the canvas's output, small (geometry + Layer 2 applied), for the
// surfaces that must show the canvas's frame: the navigator (and the
// histogram, which `Canvas` computes from the same pixels).

import { useSyncExternalStore } from 'react';

export interface OutputImage {
  width: number;
  height: number;
  data: Uint8Array;
}

let current: OutputImage | null = null;
const listeners = new Set<() => void>();

export function publishOutput(img: OutputImage | null) {
  current = img;
  for (const l of listeners) l();
}

export function useOutput(): OutputImage | null {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => current,
  );
}
