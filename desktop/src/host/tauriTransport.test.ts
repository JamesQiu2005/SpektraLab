import { beforeEach, expect, it, vi } from 'vitest';
import { tauriTransport } from './tauriTransport';

const fake = vi.hoisted(() => ({ invoke: vi.fn(), listen: vi.fn() }));
vi.mock('@tauri-apps/api/core', () => ({ invoke: fake.invoke }));
vi.mock('@tauri-apps/api/event', () => ({ listen: fake.listen }));
beforeEach(() => { vi.resetAllMocks(); });

it('registers the state listener before asking for the startup snapshot', async () => {
  let subscribed!: (unlisten: () => void) => void;
  fake.listen.mockReturnValue(new Promise<() => void>((resolve) => { subscribed = resolve; }));
  fake.invoke.mockResolvedValue({ phase: 'ready', hello: {} });
  const transport = tauriTransport();
  const stop = transport.onState(vi.fn());
  const pending = transport.state();
  await Promise.resolve();
  expect(fake.invoke).not.toHaveBeenCalled();
  const unlisten = vi.fn();
  subscribed(unlisten);
  expect(await pending).toMatchObject({ phase: 'ready' });
  expect(fake.invoke).toHaveBeenCalledWith('host_state');
  stop();
  await Promise.resolve();
  expect(unlisten).toHaveBeenCalledOnce();
});
