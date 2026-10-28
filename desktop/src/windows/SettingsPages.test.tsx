// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
const mocks = vi.hoisted(() => ({ invoke: vi.fn(), cache: vi.fn(), clear: vi.fn(), configure: vi.fn(), report: vi.fn() }));
vi.mock('@tauri-apps/api/core', () => ({ invoke: mocks.invoke }));
vi.mock('../host/transport', () => ({ inTauri: () => true }));
vi.mock('../host/client', () => ({ host: () => ({ memoryReport: mocks.report }) }));
vi.mock('../state/displayCache', () => ({ displayCacheStatus: mocks.cache, clearDisplayCache: mocks.clear, configureDisplayCache: mocks.configure }));
vi.mock('../platform', () => ({ platform: () => ({ reveal: vi.fn(), openUrl: vi.fn() }) }));
vi.mock('../i18n', () => ({ tz: (s: string) => s }));
vi.mock('../controls/controls', () => ({ ToggleRow: (p: { label: string; disabled: boolean; on: boolean; onChange: (v: boolean) => void }) =>
  <button disabled={p.disabled} aria-pressed={p.on} onClick={() => p.onChange(!p.on)}>{p.label}</button> }));
import { AgentsSettings, MemorySettings, UpdateSettings, formatBytes } from './SettingsPages';
let root: Root, div: HTMLDivElement;
beforeEach(() => {
  vi.stubGlobal('React', React); vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true); vi.clearAllMocks();
  div = document.createElement('div'); document.body.append(div); root = createRoot(div);
});
afterEach(async () => { await act(async () => root.unmount()); div.remove(); vi.unstubAllGlobals(); });
const button = (text: string) => [...div.querySelectorAll('button')].find((b) => b.textContent === text)!;
it('distinguishes a loading native cache from unavailable browser support', async () => {
  let finish!: (value: unknown) => void;
  mocks.report.mockResolvedValue({ total_bytes: 0 });
  mocks.cache.mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
  await act(async () => root.render(<MemorySettings />));
  expect(div.textContent).toContain('Loading display cache…');
  expect(div.textContent).not.toContain('Available in the desktop application.');
  await act(async () => finish({ bytes: 0, cap_bytes: 16 * 1024 ** 3, entries: 0, path: 'D:/cache' }));
  expect(div.textContent).not.toContain('Loading display cache…');
  expect(button('Clear display cache').disabled).toBe(false);
});
it('shows native agent settings loading, then explains a command failure', async () => {
  let fail!: (reason: unknown) => void;
  mocks.invoke.mockImplementation(() => new Promise((_resolve, reject) => { fail = reject; }));
  await act(async () => root.render(<AgentsSettings />));
  expect(div.textContent).toContain('Loading local tool settings…');
  expect(div.textContent).not.toContain('Available in the desktop application.');
  expect(button('Allow local command line and agent access').disabled).toBe(true);
  await act(async () => fail(new Error('permission settings unavailable')));
  expect(div.textContent).toContain('Could not load local tool settings.');
  expect(div.querySelector('[role="alert"]')?.textContent).toContain('permission settings unavailable');
  expect(div.textContent).not.toContain('Loading local tool settings…');
});
it('explains why the update check is temporarily disabled while app information loads', async () => {
  await act(async () => root.render(<UpdateSettings />));
  expect(button('Loading app version…').disabled).toBe(true);
  await act(async () => root.render(<UpdateSettings version="1.3.1" os="windows" />));
  expect(button('Check for Windows updates').disabled).toBe(false);
});
it('shows real ledger values and only clears the preview disk cache', async () => {
  mocks.report.mockResolvedValue({ total_bytes: 2 * 1024 ** 3, suspended_bytes: 1024 ** 3, persistent: { source_bytes: 256 * 1024 ** 2 } });
  mocks.cache.mockResolvedValue({ bytes: 512 * 1024 ** 2, cap_bytes: 16 * 1024 ** 3, entries: 3, max_entry_bytes: 64 * 1024 ** 2, path: 'D:/cache' });
  await act(async () => root.render(<MemorySettings />));
  expect(div.textContent).toContain('2.00 GiB'); expect(div.textContent).toContain('256.0 MiB');
  await act(async () => button('Clear display cache').click());
  expect(mocks.clear).toHaveBeenCalledOnce(); expect(mocks.configure).not.toHaveBeenCalled();
  expect(formatBytes(Number.NaN)).toBe('—');
});
it('keeps agent access off until the user toggles it and displays missing packaged runtime', async () => {
  const state = { enabled: false, runtime_available: false, executable: 'D:/owned/spektralab.cmd', command: '', mcp_config: {} };
  mocks.invoke.mockImplementation(async (name, args) => name === 'agent_access_set' ? { ...state, enabled: args.enabled } : state);
  await act(async () => root.render(<AgentsSettings />));
  expect(mocks.invoke).toHaveBeenCalledWith('agent_access_get');
  expect(mocks.invoke).not.toHaveBeenCalledWith('agent_access_set', expect.anything());
  expect(button('Install command').disabled).toBe(true);
  expect(div.textContent).toContain('does not include the agent runtime');
  await act(async () => button('Allow local command line and agent access').click());
  expect(mocks.invoke).toHaveBeenCalledWith('agent_access_set', { enabled: true });
  expect(button('Allow local command line and agent access').getAttribute('aria-pressed')).toBe('true');
});
