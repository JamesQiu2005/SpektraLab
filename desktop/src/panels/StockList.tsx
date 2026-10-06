// StockList.tsx — the film and paper lists: group headers, a rounded white
// selection, the orange CINE pill, a cover where the catalogue has one.

export interface StockRow {
  id: string;
  name: string;
  header?: boolean;
  cine?: boolean;
  cover?: string | null;
  disabled?: boolean;
  reason?: string | null;
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
            {r.cover && <img className="cover" src={r.cover} alt="" />}
            {r.cine && <span className="cine-pill">CINE</span>}
          </div>
        ),
      )}
    </div>
  );
}
