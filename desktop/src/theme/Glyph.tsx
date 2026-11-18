// Glyph.tsx — one of the design's glyphs (glyphs.generated.ts, cut out of
// desktop/design/windows by scripts/gen-glyphs.ts), drawn in currentColor at
// the size the drawing gives it.

import { GLYPHS, type GlyphName } from './glyphs.generated';

export type { GlyphName };

export function Glyph({ name, size, className }: { name: GlyphName; size?: number; className?: string }) {
  const g = GLYPHS[name];
  const k = size ? size / Math.max(g.w, g.h) : 1;
  return (
    <svg className={'v2-g' + (className ? ` ${className}` : '')} data-glyph={name} width={g.w * k} height={g.h * k} viewBox={`0 0 ${g.w} ${g.h}`}
      aria-hidden="true" focusable="false" dangerouslySetInnerHTML={{ __html: g.svg }} />
  );
}
