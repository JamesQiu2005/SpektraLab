// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { PreviewQueue } from '../state/previewQueue';
import { PreviewBuildStatus } from './PreviewBuildStatus';

vi.mock('../i18n', () => ({ useI18n: () => ({ tz: (en: string) => en }) }));
let root: Root, div: HTMLDivElement;
const queues: PreviewQueue[] = [];
beforeEach(() => {
  vi.stubGlobal('React', React);
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
  div = document.createElement('div'); document.body.append(div); root = createRoot(div);
});
afterEach(async () => {
  await act(async () => root.unmount());
  for (const queue of queues.splice(0)) queue.dispose();
  div.remove(); vi.unstubAllGlobals();
});
const button = (text: string) => [...div.querySelectorAll('button')].find((b) => b.textContent === text)!;

it('labels the preview type and offers pause, resume, and cancellation without blocking editing', async () => {
  const queue = new PreviewQueue(async () => {}); queues.push(queue);
  queue.setForegroundBusy(true);
  queue.replace([{ path: 'a', key: 'a:v1' }]);
  await act(async () => root.render(<PreviewBuildStatus queue={queue} />));
  expect(div.textContent).toContain('Camera previews waiting for editing · Prepared 0/1');
  await act(async () => button('Pause').click());
  expect(div.textContent).toContain('Camera previews paused');
  await act(async () => button('Resume').click());
  expect(div.textContent).toContain('Camera previews waiting for editing');
  await act(async () => button('Cancel').click());
  expect(div.querySelector('[data-testid="preview-build-status"]')).toBeNull();
});

it('reports successful completion briefly and does not claim missing previews are ready', async () => {
  const queue = new PreviewQueue(async () => {}); queues.push(queue);
  await act(async () => {
    root.render(<PreviewBuildStatus queue={queue} />);
    queue.replace([{ path: 'a', key: 'a:v1' }]);
  });
  expect(div.textContent).toContain('Camera preview preparation complete · Prepared 1/1');
  expect(div.querySelector('button')).toBeNull();
  const failed = new PreviewQueue(async () => { throw new Error('no embedded preview'); }); queues.push(failed);
  await act(async () => {
    root.render(<PreviewBuildStatus queue={failed} />);
    failed.replace([{ path: 'b', key: 'b:v1' }]);
  });
  expect(div.textContent).toContain('Prepared 0/1 · 1 could not be generated');
  expect(div.textContent).not.toContain('previews ready');
  expect(div.querySelector('button')).toBeNull();
});

it('distinguishes cache skips from failures and hides cancellation without claiming completion', async () => {
  const queue = new PreviewQueue(async (job) => {
    if (job.path === 'a') return 'skipped';
    if (job.path === 'b') throw new Error('no embedded preview');
  }); queues.push(queue);
  await act(async () => {
    root.render(<PreviewBuildStatus queue={queue} />);
    queue.replace(['a', 'b', 'c'].map((path) => ({ path, key: path })));
  });
  expect(div.textContent).toContain('Prepared 1/3');
  expect(div.textContent).toContain('1 not cached');
  expect(div.textContent).toContain('1 could not be generated');
  expect(div.textContent).not.toContain('unavailable');
  await act(async () => queue.cancel());
  expect(div.textContent).toBe('');
});
