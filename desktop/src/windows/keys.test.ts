// Trap 32: a single-key shortcut must not fire from inside a text field.
import { describe, expect, it } from 'vitest';
import { chord, isTypingKey,nativeMenuOwnsKey } from './keys';

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
  it('uses the physical letter when an IME owns a non-editable canvas key',()=>{
    expect(chord({...k('Process',div),code:'KeyC'})).toBe('c');
    expect(chord({...k('Unidentified',div),code:'KeyV'})).toBe('v');
    expect(isTypingKey({...k('Process',field),code:'KeyC'})).toBe(true);
    expect(chord({...k('Process',field),code:'KeyC'})).toBe('process');
  });
  it('handles Windows WebView keydowns even when the native menu advertises that chord',()=>{
    const owns=new Set(['ctrl+e','ctrl+z']);
    expect(nativeMenuOwnsKey(k('e',div,{ctrlKey:true}),owns,'Windows NT 10.0')).toBe(false);
    expect(nativeMenuOwnsKey(k('z',div,{ctrlKey:true}),owns,'Windows NT 10.0')).toBe(false);
    expect(nativeMenuOwnsKey(k('e',div,{ctrlKey:true}),owns,'X11; Linux x86_64')).toBe(true);
  });
});
