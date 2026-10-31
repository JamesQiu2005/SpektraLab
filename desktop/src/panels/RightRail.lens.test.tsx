// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { newSidecar } from '@shared/sidecar';
import { ALL_FEATURES } from '@shared/params';
import type { HelloResult } from '@shared/protocol';
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({}) }));
vi.mock('../platform', () => ({ platform: () => ({ log: vi.fn(), sidecarSave: async () => '' }),
  baseName: (p: string) => p, dirName: (p: string) => p }));
import { sessionStore } from '../state/session';
import { settingsStore } from '../state/settings';
import { setLanguage } from '../i18n';
import { RightRail } from './RightRail';

let root: Root, div: HTMLDivElement;
const reason = () => div.querySelector('[data-testid=lens-profile]')?.textContent;
async function mount(language: 'english' | 'simplifiedChinese') {
  setLanguage(language);
  div = document.createElement('div'); document.body.append(div); root = createRoot(div);
  await act(async () => root.render(<RightRail />));
}
beforeEach(() => {
  vi.useFakeTimers(); vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true); vi.stubGlobal('React', React);
  settingsStore.setState({ collapsedSections: {}, parametersTab: 'preDev' });
  sessionStore.setState({ sidecar: structuredClone(newSidecar()), selection: '/owned/a.ARW', engineSession: 's1',
    latitude: { reply: null, failure: null, refusal: null, session: null, frame: null, stamp: null },
    hello: { methods: ['redecode'] } as HelloResult, gate: ALL_FEATURES, nativeSize: { width: 6, height: 4 },
    frameKind: 'raw', batchExporting: false, redecoding: false, pair: null, pairInfo: null,
    metadata: { lens_correction: { available: false, applied: false, reason: 'camera profile was not matched uniquely',
      distortion: false, tca: false, vignetting: false, scale: 1 } } });
});
afterEach(async () => {
  await act(async () => root.unmount()); div.remove(); vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals();
  setLanguage('english');
});

it('shows the host’s lens reason as it is in English', async () => {
  await mount('english');
  expect(reason()).toBe('camera profile was not matched uniquely');
});

it('shows the host’s lens reason in Chinese when the interface is Chinese', async () => {
  await mount('simplifiedChinese');
  expect(reason()).toBe('没有唯一匹配到相机配置文件');
});
