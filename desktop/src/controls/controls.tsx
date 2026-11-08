// controls.tsx — the rails' building blocks (`Controls/*.swift`):
// a collapsible section, the one slider (ScrubSlider), a toggle row, a pill
// menu, a unit field and the Pre-Dev / Post-Dev switch.
//
// ScrubSlider semantics, as on the Mac: drag anywhere on the track; Alt for
// ×0.25 sensitivity; Shift snaps to `snap`; double-click resets to `zero`; the
// value is an editable field (Enter commits, Esc cancels). `onChange` runs
// while dragging; `onCommit` on release.

import * as DropdownMenu from '@radix-ui/react-dropdown-menu';
import { type ReactNode, useEffect, useRef, useState } from 'react';
import { clamp } from '@shared/params';
import { settingsStore, useSettings } from '../state/settings';
import { beginGesture } from '../state/session';
import { Disclosure, Ellipsis, Reset } from './icons';

// ------------------------------------------------------------------ Section

export interface SectionProps {
  id: string;
  title: string;
  children: ReactNode;
  trailing?: ReactNode;
  onReset?: () => void;
  resetHelp?: string;
  resetEnabled?: boolean;
  menu?: { label: string; onSelect: () => void; disabled?: boolean; checked?: boolean }[];
  /** A feature the host cannot do: shown, greyed, with the reason. */
  unsupported?: string | null;
}

export function Section({ id, title, children, trailing, onReset, resetHelp, resetEnabled = true, menu, unsupported }: SectionProps) {
  const collapsed = useSettings((s) => !!s.collapsedSections[id]);
  return (
    <section className={'section' + (unsupported ? ' unsupported' : '')} data-section={id}>
      <div className="section-header">
        <button className={'disclosure' + (collapsed ? ' closed' : '')} onClick={() => settingsStore.getState().toggleSection(id)} aria-label={title}>
          <Disclosure />
        </button>
        <span className="title" onDoubleClick={() => settingsStore.getState().toggleSection(id)}>
          {title}
        </span>
        {trailing && <span className="trailing">{trailing}</span>}
        {onReset && (
          <button className="icon-btn" style={{ width: 18, height: 18 }} title={resetHelp} disabled={!resetEnabled || !!unsupported} onClick={onReset}>
            <Reset />
          </button>
        )}
        {menu && menu.length > 0 && (
          <DropdownMenu.Root>
            <DropdownMenu.Trigger asChild>
              <button className="icon-btn" style={{ width: 22, height: 18 }} aria-label="More" disabled={!!unsupported}>
                <Ellipsis />
              </button>
            </DropdownMenu.Trigger>
            <DropdownMenu.Portal>
              <DropdownMenu.Content className="menu" align="end" sideOffset={4}>
                {menu.map((m) => (
                  <DropdownMenu.Item key={m.label} className="menu-item" disabled={m.disabled} onSelect={m.onSelect}>
                    {m.checked !== undefined && <span className="check">{m.checked ? '✓' : ''}</span>}
                    {m.label}
                  </DropdownMenu.Item>
                ))}
              </DropdownMenu.Content>
            </DropdownMenu.Portal>
          </DropdownMenu.Root>
        )}
      </div>
      {unsupported && !collapsed && <div className="unsupported-note" title={unsupported}>{unsupported}</div>}
      {!collapsed && (
        <div className="section-body" title={unsupported ?? undefined} aria-disabled={!!unsupported}>
          {children}
        </div>
      )}
    </section>
  );
}

// ------------------------------------------------------------- ScrubSlider

export interface ScrubSliderProps {
  label: string;
  sublabel?: ReactNode;
  value: number;
  range: [number, number];
  zero?: number;
  snap?: number;
  format?: (v: number) => string;
  parse?: (s: string) => number | null;
  onChange: (v: number) => void;
  onCommit?: (v: number) => void;
  disabled?: boolean;
  reason?: string;
  blocked?: [number, number] | null;
  /** A coloured track (temperature, tint, the filter axes). */
  gradient?: string;
  testId?: string;
}

export function ScrubSlider(p: ScrubSliderProps) {
  const { label, sublabel, value, range, zero = 0, snap, format = (v) => v.toFixed(2), onChange, onCommit, disabled, reason, blocked, gradient } = p;
  const track = useRef<HTMLDivElement>(null);
  const [text, setText] = useState<string | null>(null);
  const drag = useRef<{ x: number; v: number; w: number } | null>(null);
  const [lo, hi] = range;
  const frac = (v: number) => (clamp(v, lo, hi) - lo) / (hi - lo || 1);

  const onPointerDown = (e: React.PointerEvent) => {
    if (disabled || e.button !== 0) return;
    const el = track.current!;
    el.setPointerCapture(e.pointerId);
    const r = el.getBoundingClientRect();
    beginGesture();
    // Click on the track jumps there; then the drag is relative.
    const v = lo + clamp((e.clientX - r.left) / r.width, 0, 1) * (hi - lo);
    const start = e.detail > 1 ? value : v;
    drag.current = { x: e.clientX, v: start, w: r.width };
    if (e.detail <= 1) onChange(snapTo(start, e.shiftKey));
  };
  const snapTo = (v: number, shift: boolean) => {
    let out = clamp(v, lo, hi);
    if (shift && snap) out = Math.round(out / snap) * snap;
    return out;
  };
  const onPointerMove = (e: React.PointerEvent) => {
    const d = drag.current;
    if (!d) return;
    const k = e.altKey ? 0.25 : 1;
    const v = d.v + ((e.clientX - d.x) / d.w) * (hi - lo) * k;
    onChange(snapTo(v, e.shiftKey));
  };
  const onPointerUp = () => {
    if (drag.current) onCommit?.(value);
    drag.current = null;
  };

  const commitText = () => {
    if (text == null) return;
    const n = p.parse ? p.parse(text) : Number.parseFloat(text.replace(',', '.').replace(/[^0-9.+-eE]/g, ''));
    setText(null);
    if (n != null && Number.isFinite(n)) {
      beginGesture();
      onChange(clamp(n, lo, hi));
      onCommit?.(clamp(n, lo, hi));
    }
  };

  return (
    <div className={'row' + (disabled ? ' disabled' : '')} title={disabled ? reason : undefined} data-testid={p.testId}>
      <span className="row-label">
        {label}
        {sublabel && <span className="sub">{sublabel}</span>}
      </span>
      <div
        ref={track}
        className="scrub"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
        onDoubleClick={() => {
          if (disabled) return;
          beginGesture();
          onChange(zero);
          onCommit?.(zero);
        }}
        role="slider"
        aria-label={label}
        aria-valuemin={lo}
        aria-valuemax={hi}
        aria-valuenow={value}
      >
        <div className="track" style={gradient ? { background: gradient, height: 2 } : undefined} />
        {blocked && <div className="blocked" style={{ left: `${frac(blocked[0]) * 100}%`, width: `${(frac(blocked[1]) - frac(blocked[0])) * 100}%` }} />}
        {zero > lo && zero < hi && <div className="zero" style={{ left: `${frac(zero) * 100}%` }} />}
        <div className="knob" style={{ left: `${frac(value) * 100}%` }} />
      </div>
      <input
        className="value-field"
        value={text ?? format(value)}
        disabled={disabled}
        onFocus={(e) => {
          setText(format(value));
          e.currentTarget.select();
        }}
        onChange={(e) => setText(e.target.value)}
        onBlur={commitText}
        onKeyDown={(e) => {
          if (e.key === 'Enter') (e.target as HTMLInputElement).blur();
          if (e.key === 'Escape') {
            setText(null);
            (e.target as HTMLInputElement).blur();
          }
          if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
            e.preventDefault();
            const step = snap ?? (hi - lo) / 100;
            beginGesture();
            const v = clamp(value + (e.key === 'ArrowUp' ? step : -step), lo, hi);
            onChange(v);
            setText(format(v));
          }
        }}
        aria-label={label + ' value'}
      />
    </div>
  );
}

export const signed = (digits: number) => (v: number) => (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(v).toFixed(digits);
export const parseSigned = (s: string) => {
  const n = Number.parseFloat(s.replace('−', '-').replace(',', '.'));
  return Number.isFinite(n) ? n : null;
};

// ---------------------------------------------------------------- ToggleRow

export function ToggleRow(p: { label: string; sublabel?: string; on: boolean; onChange: (v: boolean) => void; disabled?: boolean; reason?: string; testId?: string }) {
  return (
    <div
      className={'row toggle-row' + (p.disabled ? ' disabled' : '')}
      title={p.disabled ? p.reason : undefined}
      onClick={() => !p.disabled && p.onChange(!p.on)}
      role="switch"
      aria-checked={p.on}
      aria-label={p.label}
      data-testid={p.testId}
    >
      <span className="row-label">
        {p.label}
        {p.sublabel && <span className="sub">{p.sublabel}</span>}
      </span>
      <span className={'checkbox' + (p.on ? ' on' : '')} />
    </div>
  );
}

export function Checkbox(p: { on: boolean; onChange: (v: boolean) => void; label?: string; disabled?: boolean }) {
  return (
    <button className={'checkbox' + (p.on ? ' on' : '')} disabled={p.disabled} onClick={() => p.onChange(!p.on)} aria-label={p.label} role="checkbox" aria-checked={p.on} />
  );
}

// ----------------------------------------------------------------- PillMenu

export interface PillOption<T> {
  value: T;
  label: string;
  badge?: string;
  disabled?: boolean;
  group?: string;
}

export function PillMenu<T extends string | number>(p: {
  label?: string;
  options: PillOption<T>[];
  value: T;
  onChange: (v: T) => void;
  fill?: boolean;
  disabled?: boolean;
  reason?: string;
  testId?: string;
  display?: string;
}) {
  const cur = p.options.find((o) => o.value === p.value);
  let lastGroup: string | undefined;
  const pill = (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild disabled={p.disabled}>
        <button className={'pill-menu' + (p.fill ? ' fill' : '')} data-testid={p.testId} title={p.disabled ? p.reason : undefined}>
          <span>{p.display ?? cur?.label ?? String(p.value)}</span>
          <svg width="7" height="5" viewBox="0 0 7 5">
            <path d="M0.5 0.5h6L3.5 4.5z" fill="none" stroke="currentColor" strokeWidth="0.9" />
          </svg>
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content className="menu" align="start" sideOffset={4}>
          {p.options.map((o) => {
            const header = o.group && o.group !== lastGroup ? o.group : null;
            lastGroup = o.group;
            return (
              <div key={String(o.value)}>
                {header && <DropdownMenu.Label className="menu-label">{header}</DropdownMenu.Label>}
                <DropdownMenu.Item className="menu-item" disabled={o.disabled} onSelect={() => p.onChange(o.value)}>
                  <span className="check">{o.value === p.value ? '✓' : ''}</span>
                  {o.label}
                  {o.badge && (
                    <span className="cine-pill" style={{ marginLeft: 8 }}>
                      {o.badge}
                    </span>
                  )}
                </DropdownMenu.Item>
              </div>
            );
          })}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
  if (!p.label) return pill;
  return (
    <div className={'row' + (p.disabled ? ' disabled' : '')} title={p.disabled ? p.reason : undefined}>
      <span className="row-label">{p.label}</span>
      {pill}
    </div>
  );
}

// ---------------------------------------------------------------- UnitField

export function NumberField(p: { value: number; decimals: number; onCommit: (v: number) => void; disabled?: boolean; width?: number; label?: string }) {
  const [text, setText] = useState<string | null>(null);
  useEffect(() => setText(null), [p.value]);
  return (
    <input
      className="unit-field"
      style={p.width ? { width: p.width } : undefined}
      value={text ?? p.value.toFixed(p.decimals)}
      disabled={p.disabled}
      aria-label={p.label}
      onChange={(e) => setText(e.target.value)}
      onBlur={() => {
        if (text != null) {
          const n = Number.parseFloat(text.replace(',', '.'));
          if (Number.isFinite(n)) p.onCommit(n);
          setText(null);
        }
      }}
      onKeyDown={(e) => {
        if (e.key === 'Enter') (e.target as HTMLInputElement).blur();
        if (e.key === 'Escape') {
          setText(null);
          (e.target as HTMLInputElement).blur();
        }
      }}
    />
  );
}

// ----------------------------------------------------------- SegmentedSwitch

export function SegmentedSwitch<T extends string>(p: { options: { value: T; label: string; marked?: boolean; markHelp?: string }[]; value: T; onChange: (v: T) => void }) {
  return (
    <div className="segmented" role="tablist">
      {p.options.map((o) => (
        <button key={o.value} className={o.value === p.value ? 'on' : ''} role="tab" aria-selected={o.value === p.value} onClick={() => p.onChange(o.value)}>
          {o.label}
          {o.marked && <span className="mark" title={o.markHelp} />}
        </button>
      ))}
    </div>
  );
}
