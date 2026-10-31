// A software Vulkan device lowers the preview edge until the user picks one;
// hardware restores the default. The flag migrates from settings saved
// before it existed.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { HelloResult } from '@shared/protocol';
import { adoptPreviewEdgeForDevice, sessionStore } from './session';
import { loadSettings, SETTINGS_DEFAULT, settingsStore, SOFTWARE_PREVIEW_EDGE } from './settings';

vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({}) }));
vi.mock('../platform', () => ({ platform: () => ({ log: () => {} }), baseName: (p: string) => p, dirName: (p: string) => p }));

const hello = (device_name: string) => ({ backend: { api: 'vulkan', device_name } } as unknown as HelloResult);
const edge = () => settingsStore.getState().previewLongEdge;

beforeEach(() => {
  settingsStore.setState({ previewLongEdge: SETTINGS_DEFAULT.previewLongEdge, previewLongEdgeChosen: false });
  sessionStore.setState({ status: '' });
});

describe('preview edge on a software device', () => {
  it('drops to the smallest edge on lavapipe and says so', () => {
    adoptPreviewEdgeForDevice(hello('llvmpipe (LLVM 17.0.6, 256 bits)'));
    expect(edge()).toBe(SOFTWARE_PREVIEW_EDGE);
    expect(sessionStore.getState().status).toContain('llvmpipe');
  });
  it('returns to the default once a hardware device answers', () => {
    adoptPreviewEdgeForDevice(hello('llvmpipe (LLVM 17.0.6, 256 bits)'));
    adoptPreviewEdgeForDevice(hello('AMD Radeon RX 9070'));
    expect(edge()).toBe(SETTINGS_DEFAULT.previewLongEdge);
  });
  it("leaves the user's own choice alone on either device", () => {
    settingsStore.setState({ previewLongEdge: 1920, previewLongEdgeChosen: true });
    adoptPreviewEdgeForDevice(hello('llvmpipe (LLVM 17.0.6, 256 bits)'));
    adoptPreviewEdgeForDevice(hello('AMD Radeon RX 9070'));
    expect(edge()).toBe(1920);
    expect(sessionStore.getState().status).toBe('');
  });
});

describe('the chosen flag in stored settings', () => {
  const storage = (o: Record<string, unknown>) => ({ getItem: () => JSON.stringify(o) });
  it('is implied by a non-default edge saved before the flag existed', () => {
    expect(loadSettings(storage({ previewLongEdge: 1920 })).previewLongEdgeChosen).toBe(true);
    expect(loadSettings(storage({ previewLongEdge: 2560 })).previewLongEdgeChosen).toBe(false);
  });
  it('is kept as saved once it exists', () => {
    expect(loadSettings(storage({ previewLongEdge: 1080, previewLongEdgeChosen: false })).previewLongEdgeChosen).toBe(false);
    expect(loadSettings(storage({ previewLongEdge: 2560, previewLongEdgeChosen: true })).previewLongEdgeChosen).toBe(true);
  });
});
