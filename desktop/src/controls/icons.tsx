// icons.tsx — the bar's and the rails' glyphs as inline SVG (the Mac uses SF
// Symbols, which do not exist here; these are drawn to the same shapes).

import type { SVGProps } from 'react';

type P = SVGProps<SVGSVGElement> & { size?: number };
const base = (size = 16, p: P) => ({
  width: size,
  height: size,
  viewBox: '0 0 16 16',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.2,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
  ...p,
});

export const SidebarLeft = ({ size, ...p }: P) => (
  <svg {...base(size ?? 15, p)}>
    <rect x="1.5" y="2.5" width="13" height="11" rx="2" />
    <line x1="6" y1="2.5" x2="6" y2="13.5" />
  </svg>
);
export const SidebarRight = ({ size, ...p }: P) => (
  <svg {...base(size ?? 15, p)}>
    <rect x="1.5" y="2.5" width="13" height="11" rx="2" />
    <line x1="10" y1="2.5" x2="10" y2="13.5" />
  </svg>
);
export const Import = ({ size, ...p }: P) => (
  <svg {...base(size, p)}>
    <path d="M5 6.5h-2.5v7h11v-7H11" />
    <path d="M8 1.5v8M5.5 7l2.5 2.5L10.5 7" />
  </svg>
);
export const Export = ({ size, ...p }: P) => (
  <svg {...base(size, p)}>
    <path d="M5 6.5h-2.5v7h11v-7H11" />
    <path d="M8 10V1.5M5.5 4L8 1.5 10.5 4" />
  </svg>
);
export const Cursor = ({ size, ...p }: P) => (
  <svg {...base(size, p)}>
    <path d="M4 2l8.5 6.5-4 .6 2.3 4.4-1.6.8-2.3-4.5L4 12.5z" fill="currentColor" stroke="none" />
  </svg>
);
export const Hand = ({ size, ...p }: P) => (
  <svg {...base(size, p)}>
    <path d="M5 8V3.5a1 1 0 012 0V7m0-4.5a1 1 0 012 0V7m0-3.5a1 1 0 012 0V8m0-2.5a1 1 0 012 0V10c0 2.5-2 4.5-4.5 4.5S5.5 13 4 11L2.6 8.8a1 1 0 011.6-1.2L5 8.7" />
  </svg>
);
export const Crop = ({ size, ...p }: P) => (
  <svg {...base(size, p)}>
    <path d="M4 1.5V12h10.5M1.5 4H12v10.5" />
  </svg>
);
export const ZoomOut = ({ size, ...p }: P) => (
  <svg {...base(size, p)}>
    <circle cx="6.8" cy="6.8" r="4.8" />
    <path d="M10.3 10.3l4 4M4.6 6.8h4.4" />
  </svg>
);
export const ZoomIn = ({ size, ...p }: P) => (
  <svg {...base(size, p)}>
    <circle cx="6.8" cy="6.8" r="4.8" />
    <path d="M10.3 10.3l4 4M4.6 6.8h4.4M6.8 4.6v4.4" />
  </svg>
);
export const BeforeAfter = ({ size, ...p }: P) => (
  <svg width={size ?? 25} height={16} viewBox="0 0 25 16" fill="none" stroke="currentColor" strokeWidth={1.2} {...p}>
    <rect x="1" y="1.5" width="23" height="13" rx="1.5" />
    <rect x="12.5" y="1.5" width="11.5" height="13" fill="currentColor" />
  </svg>
);
export const ChevronLeft = ({ size, ...p }: P) => (
  <svg {...base(size ?? 12, p)}>
    <path d="M10 2.5L4.5 8l5.5 5.5" />
  </svg>
);
export const ChevronRight = ({ size, ...p }: P) => (
  <svg {...base(size ?? 12, p)}>
    <path d="M6 2.5L11.5 8 6 13.5" />
  </svg>
);
export const Disclosure = ({ size, ...p }: P) => (
  <svg width={size ?? 12} height={7} viewBox="0 0 12 7" fill="none" stroke="currentColor" strokeWidth={1.1} {...p}>
    <path d="M1 1h10L6 6z" />
  </svg>
);
export const Reset = ({ size, ...p }: P) => (
  <svg {...base(size ?? 10, p)}>
    <path d="M3 8a5 5 0 105-5H5.5M5.5 1l-2 2 2 2" />
  </svg>
);
export const Ellipsis = ({ size, ...p }: P) => (
  <svg width={size ?? 14} height={4} viewBox="0 0 14 4" fill="currentColor" {...p}>
    <circle cx="2" cy="2" r="1.4" />
    <circle cx="7" cy="2" r="1.4" />
    <circle cx="12" cy="2" r="1.4" />
  </svg>
);
export const RotateLeft = ({ size, ...p }: P) => (
  <svg {...base(size ?? 13, p)}>
    <rect x="5" y="6" width="9" height="8" rx="1" />
    <path d="M2 8V5a3 3 0 013-3h3M6 0l2 2-2 2" />
  </svg>
);
export const RotateRight = ({ size, ...p }: P) => (
  <svg {...base(size ?? 13, p)}>
    <rect x="2" y="6" width="9" height="8" rx="1" />
    <path d="M14 8V5a3 3 0 00-3-3H8M10 0L8 2l2 2" />
  </svg>
);
export const FlipH = ({ size, ...p }: P) => (
  <svg {...base(size ?? 13, p)}>
    <path d="M8 1v14M6 3L1.5 13H6zM10 3l4.5 10H10z" />
  </svg>
);
export const FlipV = ({ size, ...p }: P) => (
  <svg {...base(size ?? 13, p)}>
    <path d="M1 8h14M3 6L13 1.5V6zM3 10l10 4.5V10z" />
  </svg>
);
