// StockList.tsx — the film and paper lists: group headers, a rounded white
// selection, the orange CINE pill, a cover where the catalogue has one.
//
// A film without a cover photo (the 1.x box shots exist for 11 stocks) gets a generic canister
// drawn in the catalogue's own swatch colour with its speed, as SpektraLab 2 marks a stock by its
// swatch. It is not a maker's packaging and does not imitate one.

export interface StockRow {
  id: string;
  name: string;
  header?: boolean;
  cine?: boolean;
  cover?: string | null;
  /** "#rrggbb" from the catalogue: the canister's colour when there is no cover. */
  swatch?: string | null;
  iso?: number | null;
  disabled?: boolean;
  reason?: string | null;
}

/** Black or white text, whichever reads on `hex` (relative luminance). */
function inkOn(hex: string): string {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex);
  if (!m) return '#fff';
  const n = parseInt(m[1]!, 16);
  const lin = (c: number) => {
    const s = c / 255;
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  const y = 0.2126 * lin((n >> 16) & 255) + 0.7152 * lin((n >> 8) & 255) + 0.0722 * lin(n & 255);
  return y > 0.4 ? '#111' : '#fff';
}

function Canister({ swatch, iso }: { swatch: string; iso?: number | null }) {
  const ink = inkOn(swatch);
  return (
    <svg className="cover canister" width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
      {/* the spool's knob, the cap, the body */}
      <rect x="7" y="0.5" width="4" height="2" rx="0.5" fill="#8a8a8a" />
      <rect x="3" y="2" width="12" height="2.5" rx="1" fill="#5c5c5c" />
      <rect x="3.5" y="4" width="11" height="13.5" rx="1.5" fill={swatch} stroke="rgba(0,0,0,0.35)" strokeWidth="0.6" />
      {iso ? (
        <text x="9" y="13.2" textAnchor="middle" fontSize={iso >= 1000 ? 4.2 : 5.2} fontWeight="700" fill={ink}>
          {iso}
        </text>
      ) : null}
    </svg>
  );
}

export function StockList({ rows, selected, onSelect, testId }: { rows: StockRow[]; selected: string; onSelect: (id: string) => void; testId?: string }) {
  return (
    <div role="listbox" data-testid={testId}>
      {rows.map((r) =>
        r.header ? (
          <div key={r.id} className="stock-group">
            {r.name}
          </div>
        ) : (
          <div
            key={r.id}
            role="option"
            aria-selected={r.id === selected}
            aria-disabled={r.disabled}
            className={'stock-row' + (r.id === selected ? ' selected' : '') + (r.disabled ? ' disabled' : '')}
            title={r.disabled ? (r.reason ?? undefined) : r.name}
            onClick={() => !r.disabled && onSelect(r.id)}
            data-stock={r.id}
          >
            <span className="name">{r.name}</span>
            {r.cover ? <img className="cover" src={r.cover} alt="" /> : r.swatch ? <Canister swatch={r.swatch} iso={r.iso} /> : null}
            {r.cine && <span className="cine-pill">CINE</span>}
          </div>
        ),
      )}
    </div>
  );
}
