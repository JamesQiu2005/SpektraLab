// @vitest-environment jsdom
import React, { act, type ReactNode } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { SessionState } from '../state/session';
import type * as PlatformModule from '../platform';
import { ALL_FEATURES } from '@shared/params';
import { newSidecar } from '@shared/sidecar';
import { EMPTY_CATALOG } from '@shared/stocks';

const fake = vi.hoisted(() => ({
  select: vi.fn(), request: vi.fn(), renderProof: vi.fn(), cancel: vi.fn(), probe: vi.fn(), sidecarLoad: vi.fn(),
  ensureDir: vi.fn(), pathExists: vi.fn(), log: vi.fn(), storeRead: vi.fn(), paint: vi.fn(),
  workspaceBegin: vi.fn(), workspaceEnd: vi.fn(),
  output: { width: 1, height: 1, colorSpace: 'display-p3', data: new Uint8Array([180, 120, 80, 255]) },
}));
vi.mock('../state/session', async () => {
  const { createStore } = await import('zustand/vanilla');
  const { useStore } = await import('zustand');
  const sessionStore = createStore<SessionState>(() => ({} as SessionState));
  return { sessionStore, select: fake.select, setPages: vi.fn(),
    useSession: <T,>(selector: (s: SessionState) => T) => useStore(sessionStore, selector) };
});
vi.mock('../state/settings', () => ({ settingsStore: { getState: () => ({ recalculateEffectsAfterCrop: false }) } }));
vi.mock('../host/client', () => ({ host: () => ({ transport: { request: fake.request }, renderProof: fake.renderProof, cancel: fake.cancel, probe: fake.probe }) }));
vi.mock('../platform', async (original) => ({ ...await original<typeof PlatformModule>(), platform: () => fake }));
vi.mock('../canvas/output', () => ({ useOutput: () => fake.output }));
vi.mock('../canvas/colorSpace', () => ({ paintOutput: fake.paint }));
vi.mock('../windows/Filmstrip', () => ({ Thumb: () => null }));
vi.mock('../controls/controls', () => ({
  Section: ({ children }: { children: ReactNode }) => <section>{children}</section>,
  Checkbox: () => null, NumberField: () => null, PillMenu: () => null, ScrubSlider: () => null,
}));
vi.mock('../i18n', () => ({ t: (key: string) => key, tz: (english: string) => english }));
import { ExportPage } from './ExportPage';
import { sessionStore } from '../state/session';

let root: Root;
let div: HTMLDivElement;
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}
const reply = () => ({ result: { path: 'D:/out/image.jpg', width: 3000, height: 2000 }, payload: new Uint8Array() });
async function mount() {
  div = document.createElement('div'); document.body.append(div);
  root = createRoot(div);
  await act(async () => { root.render(<ExportPage />); });
}
async function click(button: HTMLButtonElement) {
  await act(async () => { button.dispatchEvent(new MouseEvent('click', { bubbles: true })); });
}
beforeEach(() => {
  vi.resetAllMocks();
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
  // The Node Vitest config uses classic JSX; production Vite uses the React plugin.
  vi.stubGlobal('React', React);
  fake.storeRead.mockResolvedValue(null);
  fake.sidecarLoad.mockResolvedValue(null);
  fake.ensureDir.mockResolvedValue(undefined);
  fake.pathExists.mockResolvedValue(false);
  fake.probe.mockResolvedValue({ width: 6000, height: 4000, metadata: {} });
  fake.request.mockResolvedValue(reply());
  fake.cancel.mockResolvedValue(true);
  fake.workspaceBegin.mockResolvedValue(71);
  fake.workspaceEnd.mockResolvedValue(undefined);
  sessionStore.setState({ exportOpen: true, picked: ['D:/photos/b.NEF', 'D:/photos/a.NEF'],
    selection: 'D:/photos/a.NEF', engineSession: 'editor', batchExporting: false, developing: false, redecoding: false,
    nativeSize: { width: 6000, height: 4000 }, metadata: {}, gate: structuredClone(ALL_FEATURES),
    catalog: EMPTY_CATALOG, sidecar: structuredClone(newSidecar()), savedGeometry: {},
    hello: { methods: ['export_frame'] } as SessionState['hello'],
  });
});
afterEach(async () => {
  if (root) await act(async () => root.unmount());
  div?.remove();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('export page batch integration', () => {
  it('freezes the selected unsaved grade, exports sequentially and never selects another photo', async () => {
    sessionStore.getState().sidecar.adjustments.exposure = 1.5;
    const before = sessionStore.getState();
    const pending = deferred<ReturnType<typeof reply>>();
    fake.request.mockReturnValueOnce(pending.promise).mockResolvedValueOnce(reply());
    await mount();
    expect(fake.paint).not.toHaveBeenCalled();
    expect(div.textContent).toContain('Update the engine to use export soft proofing');
    await click(div.querySelector('[data-testid=export-run]')!);
    expect(fake.request).toHaveBeenCalledOnce();
    expect(fake.workspaceBegin).toHaveBeenCalledOnce();
    expect(fake.workspaceEnd).not.toHaveBeenCalled();
    expect(fake.request.mock.calls[0]![0]).toBe('export_frame');
    expect(fake.request.mock.calls[0]![1]).toMatchObject({ source_path: 'D:/photos/b.NEF', session: undefined });
    expect(sessionStore.getState().selection).toBe(before.selection);
    expect(sessionStore.getState().sidecar).toBe(before.sidecar);
    // Even an external mutation after the first job started cannot change
    // the selected photo's already-frozen export snapshot.
    sessionStore.getState().sidecar.adjustments.exposure = 9;
    await act(async () => { pending.resolve(reply()); });
    expect(fake.request).toHaveBeenCalledTimes(2);
    expect(fake.request.mock.calls[1]![1]).toMatchObject({ session: 'editor',
      source_path: 'D:/photos/a.NEF', adjustments: { exposure: 1.5 } });
    expect(fake.select).not.toHaveBeenCalled();
    expect(sessionStore.getState().engineSession).toBe('editor');
    expect(sessionStore.getState().batchExporting).toBe(false);
    expect(fake.workspaceEnd).toHaveBeenCalledExactlyOnceWith(71);
    expect(div.textContent).toContain('2 of 2 processed');
  });
  it('cancels a private job by progress id, skips later frames and keeps truthful progress', async () => {
    const pending = deferred<ReturnType<typeof reply>>();
    fake.request.mockReturnValueOnce(pending.promise);
    fake.cancel.mockImplementation(async () => { pending.reject(Object.assign(new Error('cancelled'), { code: 'cancelled' })); return true; });
    await mount();
    await click(div.querySelector('[data-testid=export-run]')!);
    const job = fake.request.mock.calls[0]![1];
    const stop = [...div.querySelectorAll('button')].find((b) => b.textContent === 'Stop')!;
    await click(stop);
    expect(fake.cancel).toHaveBeenCalledExactlyOnceWith('', job.progress_id);
    expect(fake.request).toHaveBeenCalledOnce();
    expect(fake.select).not.toHaveBeenCalled();
    expect(sessionStore.getState().selection).toBe('D:/photos/a.NEF');
    expect(sessionStore.getState().batchExporting).toBe(false);
    expect(div.textContent).toContain('0 of 2 processed');
    expect(div.textContent).toContain('cancelled');
    expect(fake.workspaceEnd).toHaveBeenCalledExactlyOnceWith(71);
  });
  it('does not start any export or release an unowned lease when another process owns the workspace', async () => {
    fake.workspaceBegin.mockRejectedValue(new Error('Workspace busy'));
    await mount(); await click(div.querySelector('[data-testid=export-run]')!);
    expect(fake.request).not.toHaveBeenCalled();
    expect(fake.workspaceEnd).not.toHaveBeenCalled();
    expect(sessionStore.getState().batchExporting).toBe(false);
    expect(div.textContent).toContain('Workspace busy');
  });
  it('clears the batch UI even if releasing the lease reports an error', async () => {
    fake.workspaceEnd.mockRejectedValue(new Error('Lease release failed'));
    await mount(); await click(div.querySelector('[data-testid=export-run]')!);
    expect(fake.workspaceEnd).toHaveBeenCalledExactlyOnceWith(71);
    expect(sessionStore.getState().batchExporting).toBe(false);
    expect(fake.log).toHaveBeenCalledWith('error', expect.stringContaining('Lease release failed'));
  });
  it('blocks export with a clear message when the host only supports the older methods', async () => {
    sessionStore.setState({ hello: { methods: ['render', 'write_image', 'export_image'] } as SessionState['hello'] });
    await mount();
    expect((div.querySelector('[data-testid=export-run]') as HTMLButtonElement).disabled).toBe(true);
    expect(div.textContent).toContain('Update the engine to export');
    expect(fake.request).not.toHaveBeenCalled();
  });
});

describe('export recipe proof', () => {
  const proofReply = (generation: number, colorSpace = 'Display P3') => ({
    ...fake.output, proof: { generation, file_width: 6000, file_height: 4000, color_space: colorSpace,
      bit_depth: 8 as const, stats: { pixels: 24_000_000, outside_fraction: .02, moved_fraction: .1, clipped_fraction: .003 },
      compression_simulated: false as const, print_cached: true },
  });
  it('uses a frozen export snapshot and ignores a superseded recipe response', async () => {
    vi.useFakeTimers();
    sessionStore.setState({ displaySpace: 'display-p3', hello: { methods: ['export_frame', 'render_proof'],
      export_spaces: ['sRGB', 'display-p3', 'prophoto', 'adobe-rgb', 'rec2020'] } as SessionState['hello'] });
    const first = deferred<ReturnType<typeof proofReply>>(), second = deferred<ReturnType<typeof proofReply>>();
    fake.renderProof.mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise);
    await mount();
    await act(async () => { await vi.advanceTimersByTimeAsync(210); });
    expect(fake.renderProof).toHaveBeenCalledOnce();
    const before = fake.renderProof.mock.calls[0]![0];
    expect(before).toMatchObject({ session: 'editor', format: 'jpeg', color_space: 'display-p3', display: 'display-p3', long_edge: 0 });
    expect(before).not.toHaveProperty('path');
    await act(async () => { div.querySelectorAll('.recipe-list .stock-row')[1]!.dispatchEvent(new MouseEvent('click', { bubbles: true })); });
    expect(fake.cancel).toHaveBeenCalledWith('editor', before.progress_id);
    await act(async () => { await vi.advanceTimersByTimeAsync(210); });
    const latest = fake.renderProof.mock.calls[1]![0];
    expect(latest).toMatchObject({ format: 'tiff16', color_space: 'prophoto' });
    const current = proofReply(latest.generation, 'ProPhoto RGB');
    await act(async () => { second.resolve(current); });
    expect(fake.paint).toHaveBeenLastCalledWith(div.querySelector('canvas'), current);
    expect(div.querySelector('[data-testid=proof-stats]')?.textContent).toContain('6000 × 4000');
    expect(div.querySelector('[data-testid=proof-stats]')?.textContent).toContain('2.00%');
    await act(async () => { first.resolve(proofReply(before.generation)); });
    expect(fake.paint).toHaveBeenCalledOnce();
    expect(fake.request).not.toHaveBeenCalled();
  });
  it('cancels a proof when the page closes and never paints its late result', async () => {
    vi.useFakeTimers();
    sessionStore.setState({ hello: { methods: ['render_proof', 'export_frame'] } as SessionState['hello'] });
    const pending = deferred<ReturnType<typeof proofReply>>(); fake.renderProof.mockReturnValue(pending.promise);
    await mount(); await act(async () => { await vi.advanceTimersByTimeAsync(210); });
    const request = fake.renderProof.mock.calls[0]![0];
    await act(async () => { sessionStore.setState({ exportOpen: false }); });
    expect(fake.cancel).toHaveBeenCalledWith('editor', request.progress_id);
    await act(async () => { pending.resolve(proofReply(request.generation)); });
    expect(fake.paint).not.toHaveBeenCalled();
  });
});
