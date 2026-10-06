// ExportPage.tsx — placeholder until the export page lands (next commit).
import { setPages, useSession } from '../state/session';

export function ExportPage() {
  const open = useSession((s) => s.exportOpen);
  if (!open) return null;
  return (
    <div className="dialog-overlay" onClick={() => setPages({ exportOpen: false })}>
      <div className="dialog">Export</div>
    </div>
  );
}
