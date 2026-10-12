// Trap 32: a single-key shortcut must not fire from inside a text field.
import { describe, expect, it, vi } from 'vitest';
import { chord, isTypingKey, webviewOwnsMenuKeys, installKeys } from './keys';

const field = { tagName: 'INPUT', type: 'text', isContentEditable: false } as unknown as EventTarget;
const checkbox = { tagName: 'INPUT', type: 'checkbox', isContentEditable: false } as unknown as EventTarget;
const div = { tagName: 'DIV', isContentEditable: false } as unknown as EventTarget;
const k = (key: string, target: EventTarget | null, mods: Partial<{ ctrlKey: boolean; altKey: boolean; shiftKey: boolean; metaKey: boolean }> = {}) => ({
  key,
  target,
  ctrlKey: false,
  metaKey: false,
  altKey: false,
  shiftKey: false,
  ...mods,
});

describe('typing-key guard', () => {
  it('hands arrows, letters and delete to a focused field', () => {
    for (const key of ['ArrowLeft', 'ArrowRight', 'v', 'c', 'Backspace', ',', '.']) expect(isTypingKey(k(key, field))).toBe(true);
  });
  it('control (the control), and an unfocused canvas, still reach the shortcuts', () => {
    expect(isTypingKey(k('ArrowLeft', div))).toBe(false);
    expect(isTypingKey(k('ArrowLeft', checkbox))).toBe(false);
    expect(isTypingKey(k('z', field, { ctrlKey: true }))).toBe(false);
    expect(isTypingKey(k('Escape', field))).toBe(false);
    expect(isTypingKey(k('Enter', field))).toBe(false);
  });
  it('names chords the way the table does', () => {
    expect(chord(k('ArrowLeft', div))).toBe('arrowleft');
    expect(chord(k('C', div, { ctrlKey: true, shiftKey: true }))).toBe('ctrl+shift+c');
    expect(chord(k('[', div, { ctrlKey: true, altKey: true }))).toBe('ctrl+alt+[');
  });
});


it('Windows routes menu keys through WebView2; Linux keeps its native accelerators', () => {
  expect(webviewOwnsMenuKeys('Mozilla/5.0 (Windows NT 10.0; Win64; x64)')).toBe(true);
  expect(webviewOwnsMenuKeys('Mozilla/5.0 (X11; Linux x86_64)')).toBe(false);
});


it('window Ctrl shortcuts execute once, text editing stays in fields, and batches block edits', async () => {
  const { sessionStore } = await import('../state/session');
  const { settingsStore } = await import('../state/settings');
  const callbacks: ((e: KeyboardEvent) => void)[] = [];
  vi.stubGlobal('window', { addEventListener: (_: string, cb: (e: KeyboardEvent) => void) => callbacks.push(cb), removeEventListener: () => {} });
  vi.useFakeTimers();
  const dispose = installKeys();
  const fire = (key: string, mods: { shiftKey?: boolean; altKey?: boolean } = {}, target = div) => {
    const e = { ...k(key, target, { ctrlKey: true, ...mods }), preventDefault: vi.fn() };
    callbacks[0]!(e as unknown as KeyboardEvent);
    return e;
  };
  try {
    sessionStore.setState({ batchExporting: false, exportOpen: false, settingsOpen: false, aboutOpen: false, view: { fit: false, zoom: 1, cx: 0.5, cy: 0.5 } });
    settingsStore.getState().set('leftCollapsed', false);
    settingsStore.getState().set('rightCollapsed', false);
    fire('b');
    expect(settingsStore.getState().leftCollapsed).toBe(true);
    fire('b');
    expect(settingsStore.getState().leftCollapsed).toBe(false);
    const strip = settingsStore.getState().filmstripCollapsed;
    fire('F', { shiftKey: true });
    expect(settingsStore.getState().filmstripCollapsed).toBe(!strip);
    fire('=');
    expect(sessionStore.getState().view.zoom).toBeGreaterThan(1);
    fire('-');
    expect(sessionStore.getState().view.zoom).toBe(1);
    const turns = sessionStore.getState().sidecar.geometry.quarterTurns;
    fire(']', { altKey: true });
    expect(sessionStore.getState().sidecar.geometry.quarterTurns).not.toBe(turns);
    fire('[', { altKey: true });
    expect(sessionStore.getState().sidecar.geometry.quarterTurns).toBe(turns);
    expect(fire('a', {}, field).preventDefault).not.toHaveBeenCalled();
    sessionStore.setState({ batchExporting: true });
    expect(fire('b').preventDefault).not.toHaveBeenCalled();
    expect(settingsStore.getState().leftCollapsed).toBe(false);
  } finally {
    dispose(); vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals();
    sessionStore.setState({ batchExporting: false });
    settingsStore.getState().set('filmstripCollapsed', false);
  }
});
