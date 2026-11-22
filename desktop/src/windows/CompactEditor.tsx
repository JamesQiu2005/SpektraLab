// CompactEditor.tsx — the editor on a narrow screen (a phone, the Fold's cover screen).
//
// The same controls as the three-column editor, arranged for one thumb: the photograph on top, always in
// view; under it the film, the paper and the file; a row of tools (the rails' sections, Pre-Dev or Post-Dev);
// the chosen tool's controls open above that row; undo, more, copy, before/after and Export at the bottom.
// "Photos" shows the open photographs to pick from, with Import. EditorWindow switches to this below
// COMPACT_MAX_WIDTH and back when the screen widens (the Fold unfolded).

import * as DropdownMenu from '@radix-ui/react-dropdown-menu';
import { type ComponentType, type ReactNode, useEffect, useState } from 'react';
import { Canvas } from '../canvas/Canvas';
import { SectionHeldOpen, SegmentedSwitch } from '../controls/controls';
import { BeforeAfter, ChevronLeft, Crop, Ellipsis, Export, Import, Redo, Undo } from '../controls/icons';
import { t, tz } from '../i18n';
import { baseName } from '../platform';
import {
  ClipboardSection,
  CropSection,
  DateBackSection,
  DoubleSection,
  EnlargerSection,
  FilmEdgeSection,
  FilmSection,
  PairSection,
  PrintSection,
} from '../panels/LeftRail';
import {
  AdvancedSection,
  BorderSection,
  CameraSection,
  ChannelMixerSection,
  ColorBalanceSection,
  CurveSection,
  ExposureSection,
  FilmFormatSection,
  HslSection,
  LatitudeSection,
  LayersSection,
  LensSection,
  LightLeakSection,
  ScenePlacementSection,
  WatermarkSection,
  WhiteBalanceSection,
} from '../panels/RightRail';
import { copySettings, pasteSettings, redo, setOriginal, setPages, setTool, solveNow, toggleCompare, undo, useSession } from '../state/session';
import { settingsStore, useSettings } from '../state/settings';
import { openFilesDialog } from './actions';
import { Filmstrip } from './Filmstrip';
import { HostFailure } from './Dialogs';

/** Narrower than this (CSS px) gets the compact editor: the Fold's cover screen is ~412, unfolded ~840. */
export const COMPACT_MAX_WIDTH = 700;

export function useCompact(): boolean {
  const query = `(max-width: ${COMPACT_MAX_WIDTH}px)`;
  const [compact, setCompact] = useState(() => window.matchMedia(query).matches);
  useEffect(() => {
    const m = window.matchMedia(query);
    const on = () => setCompact(m.matches);
    m.addEventListener('change', on);
    return () => m.removeEventListener('change', on);
  }, [query]);
  return compact;
}

interface Tool {
  id: string;
  label: () => string;
  glyph: ReactNode;
  sections: ComponentType[];
}

const g = (d: ReactNode) => (
  <svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" aria-hidden="true">
    {d}
  </svg>
);

const PRE_DEV: Tool[] = [
  { id: 'film', label: () => tz('Film', '胶片'), sections: [FilmSection], glyph: g(<><rect x="4" y="3" width="12" height="14" rx="1" /><path d="M7 3v14M13 3v14" /></>) },
  { id: 'print', label: () => tz('Print', '印放'), sections: [PrintSection, EnlargerSection], glyph: g(<><rect x="4" y="5" width="12" height="11" rx="1" /><path d="M6 3h8" /></>) },
  { id: 'camera', label: () => tz('Expose', '曝光'), sections: [CameraSection, LatitudeSection], glyph: g(<><circle cx="10" cy="10" r="3.5" /><path d="M10 2.5v2M10 15.5v2M2.5 10h2M15.5 10h2M4.7 4.7l1.4 1.4M13.9 13.9l1.4 1.4M4.7 15.3l1.4-1.4M13.9 6.1l1.4-1.4" /></>) },
  { id: 'format', label: () => tz('Grain', '颗粒'), sections: [FilmFormatSection], glyph: g(<><circle cx="6" cy="7" r="1" /><circle cx="11" cy="5" r="1" /><circle cx="14" cy="10" r="1" /><circle cx="8" cy="12" r="1" /><circle cx="12" cy="15" r="1" /><circle cx="5" cy="15" r="1" /></>) },
  { id: 'leak', label: () => tz('Leak', '漏光'), sections: [LightLeakSection], glyph: g(<><path d="M3 17V3h6" /><path d="M9 3c3 2 6 5 8 9" /></>) },
  { id: 'lens', label: () => tz('Lens', '镜头'), sections: [LensSection], glyph: g(<><circle cx="10" cy="10" r="7" /><path d="M10 3l3 6M17 10l-6 2M13 16l-4-5M3 10l7-1M7 4l2 6" /></>) },
  { id: 'edge', label: () => tz('Film Edge', '片边'), sections: [FilmEdgeSection, DateBackSection], glyph: g(<><rect x="3" y="4" width="14" height="12" rx="1" /><rect x="6" y="7" width="8" height="6" /></>) },
  { id: 'crop', label: () => tz('Crop', '裁剪'), sections: [CropSection], glyph: <Crop /> },
  { id: 'layers', label: () => tz('Layers', '图层'), sections: [LayersSection], glyph: g(<><path d="M10 3l7 4-7 4-7-4z" /><path d="M3 11l7 4 7-4" /></>) },
  { id: 'placement', label: () => tz('Placement', '场景'), sections: [ScenePlacementSection], glyph: g(<><path d="M3 10h14M10 3v14" /><path d="M6 7l-3 3 3 3M14 7l3 3-3 3" /></>) },
  { id: 'frames', label: () => tz('Pairs', '双拼'), sections: [PairSection, DoubleSection], glyph: g(<><rect x="3" y="5" width="6" height="10" rx="1" /><rect x="11" y="5" width="6" height="10" rx="1" /></>) },
  { id: 'advanced', label: () => tz('Advanced', '高级'), sections: [AdvancedSection], glyph: g(<><path d="M4 6h12M4 14h12" /><circle cx="8" cy="6" r="1.8" /><circle cx="12" cy="14" r="1.8" /></>) },
  { id: 'clipboard', label: () => tz('Copy', '复制'), sections: [ClipboardSection], glyph: g(<><rect x="5" y="4" width="10" height="13" rx="1" /><path d="M8 4V2.5h4V4" /></>) },
];

const POST_DEV: Tool[] = [
  { id: 'wb', label: () => tz('White', '白平衡'), sections: [WhiteBalanceSection], glyph: g(<><path d="M10 3v9" /><circle cx="10" cy="14" r="3" /></>) },
  { id: 'exposure', label: () => tz('Exposure', '曝光'), sections: [ExposureSection], glyph: g(<><circle cx="10" cy="10" r="7" /><path d="M10 3a7 7 0 0 1 0 14z" fill="currentColor" /></>) },
  { id: 'curve', label: () => tz('Curve', '曲线'), sections: [CurveSection], glyph: g(<><path d="M3 17C8 17 7 3 17 3" /><rect x="3" y="3" width="14" height="14" rx="1" strokeOpacity="0.4" /></>) },
  { id: 'hsl', label: () => tz('HSL', 'HSL'), sections: [HslSection], glyph: g(<><circle cx="10" cy="10" r="7" /><path d="M10 3v14M3 10h14" strokeOpacity="0.5" /></>) },
  { id: 'mixer', label: () => tz('Mixer', '混合'), sections: [ChannelMixerSection], glyph: g(<><circle cx="7.5" cy="8" r="4" /><circle cx="12.5" cy="8" r="4" /><circle cx="10" cy="12.5" r="4" /></>) },
  { id: 'balance', label: () => tz('Balance', '色彩平衡'), sections: [ColorBalanceSection], glyph: g(<><path d="M10 3v14M4 7h12" /><path d="M4 7l-2 5h4zM16 7l-2 5h4z" /></>) },
  { id: 'border', label: () => tz('Border', '边框'), sections: [BorderSection], glyph: g(<><rect x="2.5" y="2.5" width="15" height="15" rx="1" /><rect x="6" y="6" width="8" height="8" /></>) },
  { id: 'watermark', label: () => tz('Watermark', '水印'), sections: [WatermarkSection], glyph: g(<><path d="M4 15l4-10 2 5 2-3 4 8z" /></>) },
];

export function CompactEditor() {
  const selection = useSession((s) => s.selection);
  const [photos, setPhotos] = useState(!selection);
  // Picking a photograph in the list opens it.
  useEffect(() => {
    if (selection) setPhotos(false);
  }, [selection]);
  return (
    <div className="compact" data-testid="compact-editor">
      {photos || !selection ? <PhotoList onBack={selection ? () => setPhotos(false) : undefined} /> : <Editing onPhotos={() => setPhotos(true)} />}
    </div>
  );
}

function PhotoList({ onBack }: { onBack?: () => void }) {
  return (
    <div className="compact-photos">
      <div className="compact-bar">
        {onBack ? (
          <button className="compact-text-btn" onClick={onBack}>
            {tz('Back', '返回')}
          </button>
        ) : (
          <span className="compact-title">{tz('Photos', '照片')}</span>
        )}
        <span style={{ flex: 1 }} />
        <button className="compact-text-btn accent" onClick={() => void openFilesDialog()} data-testid="open-button">
          <Import /> {tz('Import', '导入')}
        </button>
      </div>
      <Filmstrip />
      <HostFailure />
    </div>
  );
}

function Editing({ onPhotos }: { onPhotos: () => void }) {
  const tab = useSettings((s) => s.parametersTab);
  const [open, setOpen] = useState<string | null>(null);
  const tools = tab === 'preDev' ? PRE_DEV : POST_DEV;
  const tool = tools.find((x) => x.id === open) ?? null;
  return (
    <div className="compact-edit">
      <div className="compact-bar">
        <button className="compact-text-btn" onClick={onPhotos} aria-label={tz('Photos', '照片')}>
          <ChevronLeft /> {tz('Photos', '照片')}
        </button>
        <span style={{ flex: 1 }} />
        <SegmentedSwitch
          value={tab}
          onChange={(v) => {
            settingsStore.getState().set('parametersTab', v);
            setOpen(null);
          }}
          options={[
            { value: 'preDev', label: t('tabPreDev') },
            { value: 'postDev', label: t('tabPostDev') },
          ]}
        />
        <span style={{ flex: 1 }} />
        <ProcessButton />
      </div>
      <div className="compact-canvas">
        <Canvas />
        <HostFailure />
      </div>
      <StatusLine />
      {tool && (
        <div className="compact-pane" data-testid="compact-pane">
          <SectionHeldOpen.Provider value={true}>
            {tool.sections.map((S, i) => (
              <S key={i} />
            ))}
          </SectionHeldOpen.Provider>
        </div>
      )}
      <div className="compact-tools" role="toolbar">
        {tools.map((x) => (
          <button key={x.id} className={'compact-tool' + (x.id === open ? ' on' : '')} onClick={() => setOpen(x.id === open ? null : x.id)} aria-pressed={x.id === open}>
            <span className="compact-tool-glyph">{x.glyph}</span>
            <span className="compact-tool-label">{x.label()}</span>
          </button>
        ))}
      </div>
      <BottomBar />
    </div>
  );
}

function ProcessButton() {
  const engine = useSession((s) => s.engineSession);
  const developing = useSession((s) => s.developing);
  return (
    <button className={'action-pill' + (engine && !developing ? ' active' : '')} disabled={!engine || developing} onClick={() => void solveNow()} data-testid="process">
      {t('actionSolve')}
    </button>
  );
}

function StatusLine() {
  const selection = useSession((s) => s.selection);
  const film = useSession((s) => s.sidecar.params.filmStock);
  const paper = useSession((s) => s.sidecar.params.printStock);
  const catalog = useSession((s) => s.catalog);
  const developing = useSession((s) => s.developing);
  const status = useSession((s) => s.status);
  const name = (id: string) => catalog.stock(id)?.name.replace(/^(Kodak|Fujifilm) (Professional )?/, '') ?? id;
  return (
    <div className="compact-status" data-testid="status">
      <span className="compact-status-film">
        {developing ? '⏳ ' : ''}
        {status || `${name(film)} · ${name(paper)}`}
      </span>
      <span className="compact-status-file">{selection ? baseName(selection) : ''}</span>
    </div>
  );
}

function BottomBar() {
  const selection = useSession((s) => s.selection);
  const comparing = useSession((s) => s.comparing);
  const original = useSession((s) => s.showingOriginal);
  const tool = useSession((s) => s.tool);
  const canUndo = useSession((s) => s.undo.length > 0);
  const canRedo = useSession((s) => s.redo.length > 0);
  return (
    <div className="compact-bottom">
      <button className="compact-round" onClick={undo} disabled={!canUndo} aria-label={tz('Undo', '撤销')} data-testid="undo-button">
        <Undo size={18} />
      </button>
      <button className="compact-round" onClick={redo} disabled={!canRedo} aria-label={tz('Redo', '重做')} data-testid="redo-button">
        <Redo size={18} />
      </button>
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <button className="compact-round" aria-label={tz('More', '更多')}>
            <Ellipsis />
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content className="menu" side="top" align="start" sideOffset={6}>
            <DropdownMenu.Item className="menu-item" disabled={!selection} onSelect={() => setOriginal(!original)}>
              <span className="check">{original ? '✓' : ''}</span>
              {t('actionOriginal')}
            </DropdownMenu.Item>
            <DropdownMenu.Item className="menu-item" disabled={!selection} onSelect={() => void pasteSettings()}>
              {tz('Paste settings', '粘贴设置')}
            </DropdownMenu.Item>
            <DropdownMenu.Item className="menu-item" onSelect={() => setTool(tool === 'crop' ? 'select' : 'crop')}>
              <span className="check">{tool === 'crop' ? '✓' : ''}</span>
              {tz('Crop on the photograph', '在照片上裁剪')}
            </DropdownMenu.Item>
            <DropdownMenu.Item className="menu-item" onSelect={() => setPages({ layoutOpen: true })}>
              {tz('Layout', '排版')}
            </DropdownMenu.Item>
            <DropdownMenu.Item className="menu-item" onSelect={() => setPages({ settingsOpen: true })}>
              {tz('Settings', '设置')}
            </DropdownMenu.Item>
            <DropdownMenu.Item className="menu-item" onSelect={() => setPages({ aboutOpen: true })}>
              {tz('About Develop', '关于 Develop')}
            </DropdownMenu.Item>
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
      <button className="compact-round" onClick={copySettings} disabled={!selection} aria-label={tz('Copy settings', '复制设置')}>
        <svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
          <rect x="7" y="7" width="10" height="10" rx="1.5" />
          <path d="M13 7V4.5A1.5 1.5 0 0 0 11.5 3h-7A1.5 1.5 0 0 0 3 4.5v7A1.5 1.5 0 0 0 4.5 13H7" />
        </svg>
      </button>
      <button className={'compact-round' + (comparing ? ' on' : '')} onClick={toggleCompare} disabled={!selection} aria-label={t('helpBeforeAfter')}>
        <BeforeAfter />
      </button>
      <span style={{ flex: 1 }} />
      <button className="compact-export" disabled={!selection} onClick={() => setPages({ exportOpen: true })} data-testid="export-button">
        <Export /> {tz('Export', '导出')}
      </button>
    </div>
  );
}
