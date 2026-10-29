// ExportPage.tsx — the export page (`Export/ExportPage.swift`, drawn to
// `reference_layout/Export_Page`): recipes on the left, the frame in the
// middle, the batch (the picked frames) on the right.
//
// The batch freezes settings before its first export and leaves the editor
// on the same photograph. The host opens private frames one at a time.

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { Checkbox, NumberField, PillMenu, ScrubSlider, Section } from '../controls/controls';
import { t, tz } from '../i18n';
import { platform, baseName } from '../platform';
import { sessionStore, setPages, useSession } from '../state/session';
import { settingsStore } from '../state/settings';
import { host, type ProofReply } from '../host/client';
import { Thumb } from '../windows/Filmstrip';
import { GEOMETRY_DEFAULT } from '@shared/geometry';
import { isPairPath } from '@shared/pair';
import { paintOutput } from '../canvas/colorSpace';
import { type ExportRecipe, editRecipe, recipeSummary, DEFAULT_RECIPES, NAME_TOKENS, EXPORT_SPACES, type NameToken, decodeRecipes, extensionOf } from './recipes';
import { captureExportFrames, exportCube, exportFrame, renderProof, hostWrites, outputFor, targetFor, type ExportJob, type ExportOutcome } from './exporter';

const TOKEN_LABEL: Record<NameToken, () => string> = {
  originalName: () => tz('Org. Name', '原文件名'),
  filmStock: () => tz('Film', '胶片'),
  printStock: () => tz('Print', '相纸'),
  date: () => tz('Date', '日期'),
};

async function loadRecipes(): Promise<ExportRecipe[]> {
  try {
    return decodeRecipes(await platform().storeRead('Export', 'recipes.json'));
  } catch {
    return DEFAULT_RECIPES;
  }
}

export function ExportPage() {
  const open = useSession((s) => s.exportOpen);
  const picked = useSession((s) => s.picked);
  const selection = useSession((s) => s.selection);
  const batch = useSession((s) => s.batchExporting);
  const catalog = useSession((s) => s.catalog);
  const hello = useSession((s) => s.hello);
  const sidecar = useSession((s) => s.sidecar);
  const { params, geometry } = sidecar;
  const engineSession = useSession((s) => s.engineSession);
  const developing = useSession((s) => s.developing || s.redecoding);
  const display = useSession((s) => s.displaySpace);
  const metadata = useSession((s) => s.metadata);
  const pair = useSession((s) => s.pair);
  const pairInfo = useSession((s) => s.pairInfo);
  const gate = useSession((s) => s.gate);
  const native = useSession((s) => s.nativeSize);
  const saved = useSession((s) => s.savedGeometry);
  const [proofResult, setProofResult] = useState<{ path: string; format: ExportRecipe['format']; noFilm: boolean; image: ProofReply } | null>(null);
  const [proofStatus, setProofStatus] = useState('');
  const [proofBusy, setProofBusy] = useState(false);
  const [proofEdge, setProofEdge] = useState(2048);
  const proofGeneration = useRef(0);
  const [recipes, setRecipes] = useState<ExportRecipe[]>(DEFAULT_RECIPES);
  const [current, setCurrent] = useState(0);
  const [log, setLog] = useState<{ name: string; outcome: ExportOutcome }[]>([]);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);
  const [sample, setSample] = useState('');
  const stop = useRef(false);
  const active = useRef<ExportJob | null>(null);
  const proof = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    if (open) void loadRecipes().then(setRecipes);
  }, [open]);

  const r = recipes[Math.min(current, recipes.length - 1)] ?? DEFAULT_RECIPES[0]!;
  // These are the recipe fields consumed by renderProof. Names, destination,
  // collision policy and lossless packing cannot change its pixels; JPEG
  // compression is deliberately not simulated by the proof service.
  const proofRecipe = useMemo<ExportRecipe>(() => ({ ...DEFAULT_RECIPES[0]!,
    format: r.format, bitDepth: r.bitDepth, colorSpace: r.colorSpace, longEdge: r.longEdge,
  }), [r.format, r.bitDepth, r.colorSpace, r.longEdge]);
  const proofNoFilm = proofRecipe.format !== 'di' && sidecar.noFilm === true;
  const bypassRefusal = sidecar.noFilm && proofRecipe.format === 'di' ? tz('Enable film simulation before exporting a Digital Intermediate.', '请启用胶片模拟后再导出数字中间片。') : !proofNoFilm ? null
    : pair || (selection && isPairPath(selection)) || params.filmEdge.pair
      ? tz('Export without film simulation is unavailable for half-frame pairs. Enable film simulation.', '半格拼接不能关闭胶片模拟，请启用胶片模拟后导出。')
      : !gate.noFilm
        ? tz('This engine cannot export without film simulation. Update the engine or enable film simulation.', '此引擎不支持不应用胶片模拟的导出。请更新引擎或启用胶片模拟。')
        : null;
  // A pending recipe may keep the same photograph and film mode's last
  // proof. Neither a new photograph nor a bypass toggle inherits old pixels.
  const proofImage = proofResult?.path === selection && proofResult.noFilm === proofNoFilm ? proofResult.image : null;
  const save = (next: ExportRecipe[]) => {
    setRecipes(next);
    void platform().storeWrite('Export', 'recipes.json', next).catch(() => {});
  };
  const edit = (patch: Partial<ExportRecipe>) => {
    const next = editRecipe(recipes, current, patch);
    save(next.recipes);
    setCurrent(next.current);
  };

  useEffect(() => {
    if (!selection) return;
    void targetFor(r, { path: selection, params }, catalog).then((x) => setSample(`${x.base}.${extensionOf(r)}`));
  }, [r, selection, params, catalog]);

  useLayoutEffect(() => {
    const c = proof.current;
    if (c && proofImage) paintOutput(c, proofImage);
  }, [proofImage, open]);

  useEffect(() => {
    const pane = proof.current?.parentElement;
    if (!open || !pane || typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(([entry]) => {
      if (!entry) return;
      const edge = Math.max(entry.contentRect.width, entry.contentRect.height) * (window.devicePixelRatio || 1);
      if (edge > 0) setProofEdge(Math.max(1, Math.min(4096, Math.ceil(edge))));
    });
    observer.observe(pane);
    return () => observer.disconnect();
  }, [open]);

  useEffect(() => {
    const generation = ++proofGeneration.current;
    setProofResult((previous) => open && previous?.path === selection && previous.noFilm === proofNoFilm ? previous : null);
    setProofBusy(false);
    if (bypassRefusal) {
      setProofResult(null); setProofStatus(bypassRefusal); return;
    }
    if (!open || !selection || batch || developing || !engineSession) {
      setProofStatus(open && selection ? tz('Waiting for the image…', '正在等待照片…') : '');
      return;
    }
    if (!hello?.methods?.includes('render_proof') || (proofRecipe.format === 'di' && !hello.methods.includes('export_cineon'))) {
      setProofResult(null);
      setProofStatus(proofRecipe.format === 'di'
        ? tz('Digital Intermediate proofing is unavailable.', '数字中间片软打样尚不可用。')
        : tz('Update the engine to use export soft proofing.', '请更新引擎以使用导出软打样。'));
      return;
    }
    let obsolete = false;
    let job: ExportJob | null = null;
    const selected = { path: selection, session: engineSession, sidecar: structuredClone(sidecar), native: native ?? undefined, metadata, pair, pairInfo };
    const recipe = structuredClone(proofRecipe);
    setProofBusy(true);
    setProofStatus('');
    const timer = setTimeout(() => {
      void (async () => {
        try {
          const [item] = await captureExportFrames([selection], selected, catalog, gate,
            settingsStore.getState().recalculateEffectsAfterCrop, () => obsolete);
          if (obsolete || !item) return;
          if ('error' in item) throw new Error(item.error);
          const result = await renderProof(recipe, item.frame, catalog, hello.methods, display ?? 'srgb', proofEdge, generation,
            { frameOptions: hello.frame_options, cancelled: () => obsolete, active: (value) => { job = value; } });
          if (!obsolete && generation === proofGeneration.current && result) {
            setProofResult({ path: selection, format: recipe.format, noFilm: proofNoFilm, image: result });
            setProofBusy(false); setProofStatus('');
          }
        } catch (e) {
          if (!obsolete) { setProofBusy(false); setProofStatus(e instanceof Error ? e.message : String(e)); }
        }
      })();
    }, 200);
    return () => {
      obsolete = true; clearTimeout(timer);
      if (job) void host().cancel(job.session, job.progressId).catch(() => {});
    };
  }, [open, selection, batch, developing, engineSession, sidecar, native, metadata, pair, pairInfo, proofRecipe, proofNoFilm, bypassRefusal, hello, catalog, gate, display, proofEdge]);

  if (!open) return null;
  const frames = picked.length ? picked : selection ? [selection] : [];
  const writesEdits = hostWrites(hello?.methods as string[] | undefined);
  const spaceSupported = ['sRGB', 'display-p3', 'prophoto'].includes(r.colorSpace) || !!hello?.export_spaces?.includes(r.colorSpace);
  const supported = !bypassRefusal && (r.format === 'di' ? gate.digitalIntermediate && !!hello?.methods?.includes('export_cineon') : writesEdits && spaceSupported);
  const size = native ? outputFor(r, geometry, native) : null;
  const proofMessage = proofBusy
    ? proofImage ? tz('Updating export proof…', '正在更新导出软打样…') : tz('Preparing export proof…', '正在生成导出软打样…')
    : proofStatus;

  const run = async () => {
    if (sessionStore.getState().batchExporting) return;
    // This snapshot includes unsaved edits to the selected photo. No later
    // state read supplies parameters to an already-started batch.
    const state = sessionStore.getState();
    const recipe = structuredClone(r);
    const paths = [...frames];
    const methods = state.hello?.methods ? [...state.hello.methods] : undefined;
    const selected = state.selection ? {
      path: state.selection, sidecar: structuredClone(state.sidecar),
      session: !state.developing && !state.redecoding ? state.engineSession ?? undefined : undefined,
      native: state.nativeSize ?? undefined, dateTaken: state.metadata?.datetime_original, metadata: state.metadata,
      pair: state.pair, pairInfo: state.pairInfo,
    } : null;
    stop.current = false;
    setLog([]);
    setProgress({ done: 0, total: paths.length });
    sessionStore.setState({ batchExporting: true });
    let done = 0;
    let lease: number | null = null;
    try {
      // Keep the native workspace lease between frames as well as during
      // each host call, so an external editor cannot change this batch's inputs.
      lease = await platform().workspaceBegin();
      const prepared = await captureExportFrames(paths, selected, state.catalog, state.gate,
        settingsStore.getState().recalculateEffectsAfterCrop, () => stop.current);
      for (const item of prepared) {
        if (stop.current) break;
        const outcome: ExportOutcome = 'error' in item ? { kind: 'failed', message: item.error }
          : await exportFrame(recipe, item.frame, state.catalog, methods, {
            tiffOptions: state.hello?.tiff_options,
            frameOptions: state.hello?.frame_options,
            cancelled: () => stop.current, active: (job) => { active.current = job; },
          });
        platform().log(outcome.kind === 'failed' ? 'error' : 'info', `export ${baseName(item.path)}: ${JSON.stringify(outcome)}`);
        setLog((l) => [...l, { name: baseName(item.path), outcome }]);
        if (outcome.kind === 'cancelled') break;
        setProgress({ done: ++done, total: paths.length });
      }
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      platform().log('error', `export batch: ${message}`);
      setLog((l) => [...l, { name: tz('Batch', '批量导出'), outcome: { kind: 'failed', message } }]);
    } finally {
      active.current = null;
      if (lease !== null) await platform().workspaceEnd(lease).catch((e) => platform().log('error', `export lease: ${String(e)}`));
      sessionStore.setState({ batchExporting: false });
    }
  };

  const cancel = () => {
    stop.current = true;
    const job = active.current;
    if (job) void host().cancel(job.session, job.progressId).catch((e) => platform().log('error', `export cancel: ${String(e)}`));
  };

  return (
    <div className="export-page" data-testid="export-page">
      <div className="topbar">
        <span style={{ fontWeight: 700, fontSize: 'var(--fs-rail-title)' }}>{t('helpExport')}</span>
        <span className="bar-status">
          {progress ? tz(`${progress.done} of ${progress.total} processed`, `已处理 ${progress.done} / ${progress.total}`) : ''}
        </span>
        <span className="pill-menu" style={{ marginRight: 12 }}>
          {tz(`${frames.length} image${frames.length === 1 ? '' : 's'}`, `${frames.length} 张`)}
        </span>
        {batch ? (
          <button className="btn" onClick={cancel}>
            {tz('Stop', '停止')}
          </button>
        ) : (
          <>
            <button className="btn" onClick={() => setPages({ exportOpen: false })} style={{ marginRight: 8 }}>
              {tz('Close', '关闭')}
            </button>
            <button className="btn primary" disabled={!frames.length || !supported} onClick={() => void run()} data-testid="export-run">
              {tz('Export', '导出')}
            </button>
          </>
        )}
      </div>
      <div className="export-body">
        <aside className="rail left" style={{ pointerEvents: batch ? 'none' : undefined }}>
          <div className="rail-scroll">
            <Section
              id="exp-recipes"
              title={tz('Export Formula', '导出配方')}
              menu={[
                { label: tz('Restore the built-in recipes', '恢复内置配方'), onSelect: () => { save(DEFAULT_RECIPES); setCurrent(0); } },
                {
                  label: tz('Export the print as a .cube LUT…', '将相纸导出为 .cube LUT…'),
                  onSelect: () => void exportCube(params.printStock, `${params.printStock}.cube`).catch((e) => platform().message('SpektraLab', String(e), 'error')),
                },
              ]}
            >
              <div className="recipe-list">
                {recipes.map((x, i) => (
                  <div key={x.id} className={'stock-row' + (i === current ? ' selected' : '')} onClick={() => setCurrent(i)}>
                    <span className="name" title={recipeSummary(x)}>{x.name}</span>
                  </div>
                ))}
              </div>
              <div className="row" style={{ justifyContent: 'flex-end', gap: 6 }}>
                <button className="icon-btn" title={tz('Add a recipe', '新建配方')} onClick={() => save([...recipes, { ...r, id: 'r' + Date.now(), name: r.name + ' ' + tz('copy', '副本') }])}>
                  +
                </button>
                <button className="icon-btn" title={tz('Remove this recipe', '删除此配方')} disabled={recipes.length <= 1} onClick={() => { save(recipes.filter((_, i) => i !== current)); setCurrent(0); }}>
                  −
                </button>
              </div>
              <div className="row">
                <span className="row-label">{tz('Name', '名称')}</span>
                <input className="unit-field" style={{ flex: 1, textAlign: 'left', padding: '0 6px' }} value={r.name} onChange={(e) => edit({ name: e.target.value })} />
              </div>
            </Section>
            <Section id="exp-location" title={tz('Location', '位置')}>
              <div className="row">
                <span className="row-label">{tz('Folder', '文件夹')}</span>
                <button
                  className="pill-menu fill"
                  title={r.folder.kind === 'fixed' ? r.folder.path : undefined}
                  onClick={async () => {
                    const p = await platform().pickFolder(tz('Export to…', '导出到…'));
                    if (p) edit({ folder: { kind: 'fixed', path: p } });
                  }}
                >
                  <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{r.folder.kind === 'fixed' ? r.folder.path : tz('Beside the original', '原图旁')}</span>
                </button>
                {r.folder.kind === 'fixed' && (
                  <button className="icon-btn" title={tz('Beside the original', '原图旁')} onClick={() => edit({ folder: { kind: 'besideOriginal' } })}>
                    ×
                  </button>
                )}
              </div>
              <div className="row">
                <span className="row-label">{tz('Subfolder', '子文件夹')}</span>
                <input className="unit-field" style={{ flex: 1, textAlign: 'left', padding: '0 6px' }} value={r.subfolder} onChange={(e) => edit({ subfolder: e.target.value.replace(/[\\/:]/g, '-') })} />
              </div>
              <PillMenu
                label={tz('Existing File', '已有文件')}
                value={r.existing}
                fill
                options={[
                  { value: 'addSuffix', label: tz('Add a number', '添加后缀') },
                  { value: 'overwrite', label: tz('Overwrite', '覆盖') },
                  { value: 'skip', label: tz('Keep (skip)', '跳过') },
                ]}
                onChange={(v) => edit({ existing: v })}
              />
            </Section>
            <Section id="exp-naming" title={tz('Naming', '命名')}>
              <div className="row" style={{ flexWrap: 'wrap', gap: 4 }}>
                <span className="row-label">{tz('Format', '格式')}</span>
                {r.naming.order.map((tok, i) => (
                  <button
                    key={tok}
                    className={'chip' + (r.naming.tokens.includes(tok) ? ' on' : '')}
                    title={tz('Click to include; Alt-click to move left', '点击加入；按住 Alt 点击左移')}
                    onClick={(e) => {
                      if (e.altKey && i > 0) {
                        const order = [...r.naming.order];
                        [order[i - 1], order[i]] = [order[i]!, order[i - 1]!];
                        edit({ naming: { ...r.naming, order } });
                        return;
                      }
                      const on = r.naming.tokens.includes(tok) ? r.naming.tokens.filter((x) => x !== tok) : [...r.naming.tokens, tok];
                      if (on.length) edit({ naming: { ...r.naming, tokens: NAME_TOKENS.filter((x) => on.includes(x)) } });
                    }}
                  >
                    {TOKEN_LABEL[tok]()}
                  </button>
                ))}
              </div>
              <div className="row">
                <span className="row-label">{tz('Sample', '示例')}</span>
                <span className="caption" style={{ userSelect: 'text' }} data-testid="export-sample">
                  {sample}
                </span>
              </div>
            </Section>
            <Section id="exp-format" title={tz('Format and Size', '格式与尺寸')}>
              <div className="caption" data-testid="recipe-summary">{recipeSummary(r)}</div>
              <div className="row">
                <span className="row-label">{tz('Format', '格式')}</span>
                <PillMenu
                  value={r.format}
                  options={[
                    { value: 'jpeg', label: 'JPEG' },
                    { value: 'png', label: 'PNG' },
                    { value: 'tiff', label: 'TIFF' },
                    { value: 'di', label: tz('Digital Intermediate', '数字中间片'), disabled: !sessionStore.getState().gate.digitalIntermediate },
                  ]}
                  onChange={(v) => edit({ format: v, bitDepth: v === 'jpeg' || v === 'png' ? 8 : r.bitDepth })}
                />
                <PillMenu
                  value={r.bitDepth}
                  disabled={r.format !== 'tiff'}
                  reason={tz('JPEG and PNG are 8-bit on this host.', '此处 JPEG 与 PNG 为 8 位。')}
                  options={[
                    { value: 8, label: tz('8 bit', '8 位') },
                    { value: 16, label: tz('16 bit', '16 位') },
                  ]}
                  onChange={(v) => edit({ bitDepth: v })}
                />
              </div>
              <PillMenu
                label={tz('Color Space', '色彩空间')}
                value={r.colorSpace}
                fill
                disabled={r.format === 'di'}
                options={EXPORT_SPACES}
                onChange={(v) => edit({ colorSpace: v })}
              />
              <ScrubSlider label={tz('Quality', '质量')} value={r.quality} range={[10, 100]} zero={92} snap={5} format={(v) => v.toFixed(0)} disabled={r.format !== 'jpeg'} onChange={(v) => edit({ quality: Math.round(v) })} />
              {(r.format === 'tiff' || r.format === 'di') && <>
                <PillMenu label={tz('Compression', '压缩')} value={r.tiffCompression ?? 'none'}
                  options={[{ value: 'none', label: tz('None', '无压缩') }, { value: 'lzw', label: tz('LZW (lossless)', 'LZW（无损）'), disabled: !hello?.tiff_options?.includes('lzw') }]}
                  onChange={(v) => edit({ tiffCompression: v })} />
                <Checkbox label={tz('Embed preview page', '嵌入预览页')} on={r.format === 'di' || !!r.embedsPreview}
                  disabled={r.format === 'di' || !hello?.tiff_options?.includes('preview-page')}
                  onChange={(v) => edit({ embedsPreview: v })} />
              </>}
              <div className="row">
                <span className="row-label">{tz('Long Edge', '长边')}</span>
                <Checkbox on={r.longEdge === 0} label={tz('Original size', '原始尺寸')} onChange={(v) => edit({ longEdge: v ? 0 : 3000 })} />
                <span className="caption">{tz('Original', '原始')}</span>
                {r.longEdge > 0 && <NumberField value={r.longEdge} decimals={0} onCommit={(v) => edit({ longEdge: Math.max(16, Math.round(v)) })} />}
                <span className="caption num">{size ? `${size.width} × ${size.height}` : ''}</span>
              </div>
            </Section>
            <Section id="exp-summary" title={tz('Summary', '摘要')}>
              {!spaceSupported && <div className="caption">{tz('Update the engine to export this colour space.', '请更新引擎以导出此色彩空间。')}</div>}
              {bypassRefusal && <div className="caption">{bypassRefusal}</div>}
              <div className="caption">
                {r.format === 'di'
                  ? tz('Cineon log, 16-bit, untagged. Includes crop and rotation; Post-Dev is excluded. A view preview and both view LUTs accompany the file.', 'Cineon 对数、16 位、不嵌入 ICC。保留裁剪和旋转，不包含显影后调整；文件附带视图预览和两个显示 LUT。')
                  : sidecar.noFilm
                  ? tz('The decoded photograph is exported with Post-Dev, crop and output colour conversion. Film simulation, Film Edge and Date Back do not apply.', '导出解码后的照片，保留显影后调整、裁剪和输出色彩转换，不应用胶片模拟、片边和日期后背。')
                  : writesEdits
                  ? tz('The file is the canvas’s frame: crop, rotation and Post-Dev included.', '文件即画布上的画面：包含裁剪、旋转与显影后调整。')
                  : tz('This engine cannot export the complete frame. Update the engine to export.', '此引擎不支持完整画面导出，请更新引擎后再导出。')}
              </div>
              {log.map((l, i) => (
                <div key={i} className="caption mono" style={{ color: l.outcome.kind === 'failed' ? 'var(--hist-r)' : undefined }}>
                  {l.name}: {l.outcome.kind === 'written' ? `→ ${l.outcome.path}` : l.outcome.kind === 'skipped' ? tz(`skipped (${l.outcome.path} exists)`, `已跳过（${l.outcome.path} 已存在）`) : l.outcome.kind === 'cancelled' ? tz('cancelled', '已取消') : l.outcome.message}
                </div>
              ))}
              {log.some((l) => l.outcome.kind === 'written') && (
                <button
                  className="btn"
                  onClick={() => {
                    const w = log.find((l) => l.outcome.kind === 'written');
                    if (w && w.outcome.kind === 'written') void platform().reveal(w.outcome.path);
                  }}
                >
                  {tz('Show in folder', '在文件夹中显示')}
                </button>
              )}
            </Section>
          </div>
        </aside>
        <main className="export-proof" style={{ flexDirection: 'column' }}>
          <canvas ref={proof} data-testid="export-proof" style={{ display: proofImage ? undefined : 'none' }} />
          {proofMessage && <div className="caption" role="status">{proofMessage}</div>}
          {proofImage && <div className="caption" data-testid="proof-stats">
            {tz('Export proof', '导出软打样')} · {proofImage.proof.file_width} × {proofImage.proof.file_height} · {proofImage.proof.color_space} · {proofImage.proof.bit_depth} bit<br />
            {proofImage.proof.encoding === 'cineon'
              ? tz('Cineon shown through the supplied DI view LUT; the file retains its untagged log codes.', '使用配套 DI 视图 LUT 显示；文件保留未标记色彩空间的对数码值。')
              : <>{tz('Outside target gamut', '超出目标色域')} {(100 * proofImage.proof.stats.outside_fraction).toFixed(2)}% · {tz('Gamut mapping applied', '色域映射作用')} {(100 * proofImage.proof.stats.moved_fraction).toFixed(2)}% · {tz('Clipped', '夹限')} {(100 * proofImage.proof.stats.clipped_fraction).toFixed(2)}%</>}
            {proofResult?.format === 'jpeg' && <><br />{tz('Before JPEG compression; compression artifacts are not simulated.', '显示 JPEG 压缩前的结果，不模拟压缩伪影。')}</>}
          </div>}
        </main>
        <aside className="export-strip">
          {frames.map((p) => (
            <div key={p} className={'export-cell' + (p === selection ? ' open' : '')}>
              {/* The whole photograph, turned, the crop under a mask — as the filmstrip (§7.7). */}
              <Thumb path={p} geometry={p === selection ? geometry : (saved[p] ?? GEOMETRY_DEFAULT)} height={120} />
              <span>{baseName(p)}</span>
            </div>
          ))}
        </aside>
      </div>
    </div>
  );
}
