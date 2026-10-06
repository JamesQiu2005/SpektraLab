// Trap 32: a single-key shortcut must not fire from inside a text field.
import { describe, expect, it } from 'vitest';
import { chord, isTypingKey } from './keys';

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
