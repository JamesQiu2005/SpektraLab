// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
const mocks = vi.hoisted(() => ({ invoke: vi.fn(), pickSave: vi.fn(), pickFolder: vi.fn() }));
vi.mock('@tauri-apps/api/core', () => ({ invoke: mocks.invoke }));
vi.mock('../host/transport', () => ({ inTauri: () => true }));
vi.mock('../host/client', () => ({ host: () => ({ memoryReport: async () => ({ total_bytes: 10 }), diagnostics: async () => ({ launch: { program: 'D:/private/host.exe' }, stderr_tail: ['private.NEF'] }) }) }));
vi.mock('../platform', () => ({ platform: () => ({ pickSave: mocks.pickSave, pickFolder: mocks.pickFolder }) }));
vi.mock('../i18n', () => ({ tz: (s: string) => s }));
vi.mock('../controls/controls', () => ({
  ToggleRow: (p: { label: string; disabled: boolean; on: boolean; onChange: (v: boolean) => void }) => <button disabled={p.disabled} onClick={() => p.onChange(!p.on)}>{p.label}</button>,
  PillMenu: () => <div />,
}));
import { DiagnosticSettings } from './DiagnosticSettings';
const config = { level: 'info', per_node: false, export_job_log: false, days: 7, megabytes: 100, files: 20, directory: null };
let root: Root, div: HTMLDivElement;
beforeEach(() => {
  vi.stubGlobal('React', React); vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true); vi.clearAllMocks();
  div = document.createElement('div'); document.body.append(div); root = createRoot(div);
  mocks.invoke.mockImplementation(async (method, p) => method === 'diagnostics_save_bundle' ? p.path : ({ settings: method === 'diagnostics_set' ? p.settings : config, directory: 'D:/logs', cleanup_error: null, previous_session: { clean_exit: false } }));
});
afterEach(async () => { await act(async () => root.unmount()); div.remove(); vi.unstubAllGlobals(); });
const button = (text: string) => [...div.querySelectorAll('button')].find((b) => b.textContent === text)!;
it('identifies a pending native request as loading and enables the bundle when it resolves', async () => {
  let finish!: (value: unknown) => void;
  mocks.invoke.mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
  await act(async () => root.render(<DiagnosticSettings paths={null} hello={null} includePaths={false} />));
  expect(div.textContent).toContain('Loading diagnostic settings…');
  expect(div.textContent).not.toContain('Available in the desktop application.');
  expect(button('Save diagnostic bundle…').disabled).toBe(true);
  await act(async () => finish({ settings: config, directory: 'D:/logs', cleanup_error: null, previous_session: null }));
  expect(div.textContent).not.toContain('Loading diagnostic settings…');
  expect(button('Save diagnostic bundle…').disabled).toBe(false);
});
it('reports a native load failure without misidentifying the running app as a browser', async () => {
  mocks.invoke.mockRejectedValue(new Error('diagnostics unavailable'));
  await act(async () => root.render(<DiagnosticSettings paths={null} hello={null} includePaths={false} />));
  expect(div.textContent).toContain('Could not load diagnostic settings.');
  expect(div.querySelector('[role="alert"]')?.textContent).toContain('diagnostics unavailable');
  expect(div.textContent).not.toContain('Available in the desktop application.');
  expect(button('Save diagnostic bundle…').disabled).toBe(true);
});
it('persists real instrumentation settings only after explicit interaction', async () => {
  await act(async () => root.render(<DiagnosticSettings paths={null} hello={null} includePaths={false} />));
  expect(div.textContent).toContain('previous session did not record a clean exit');
  expect(mocks.invoke).not.toHaveBeenCalledWith('diagnostics_set', expect.anything());
  await act(async () => button('Per-node GPU timings').click());
  expect(mocks.invoke).toHaveBeenCalledWith('diagnostics_set', { settings: { ...config, per_node: true } });
  expect(div.textContent).toContain('next engine restart');
});
it('saves a locally chosen ZIP and omits private log paths from the default summary', async () => {
  mocks.pickSave.mockResolvedValue('D:/support/report.zip');
  await act(async () => root.render(<DiagnosticSettings paths={null} hello={null} includePaths={false} />));
  await act(async () => button('Save diagnostic bundle…').click());
  const call = mocks.invoke.mock.calls.find((c) => c[0] === 'diagnostics_save_bundle')!;
  expect(call[1]).toMatchObject({ path: 'D:/support/report.zip', includePaths: false });
  expect(JSON.stringify(call[1].summary)).not.toContain('private');
  expect(call[1].summary.engine_memory_ledger).toEqual({ total_bytes: 10 });
});
