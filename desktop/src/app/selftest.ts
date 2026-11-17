// selftest.ts — T5b's driver, inside the real app's webview (PRD-W2 T5, phase 2).
//
// Inert unless the Rust side was started with `--selftest <raw> <outdir>` in a
// debug or `selftest` build (`src-tauri/src/selftest.rs`): `selftest_args` does
// not exist in a release package, so this asks once, gets nothing, and stops.
//
// The run: open the RAW as the person would (the same door as open-with),
// wait until the scheduler reports the canvas develop done and the status line
// says Developed, write the canvas's own pixels as a PNG and the status line,
// the page's job and the scheduler's snapshots as JSON, then one export through
// the Export dialog (a recipe stored for this run, the dialog opened, its
// Export button clicked) and wait for its file. Any failure ends the run with
// its reason; the Rust watchdog ends a run that never ends.

import { invoke } from '@tauri-apps/api/core';
import { inTauri } from '../host/transport';
import { platform } from '../platform';
import { scheduler } from '../scheduler';
import type { JobSnapshotWire } from '../scheduler/types';
import { frameImages } from '../state/frames';
import { openPaths, sessionStore, setPages } from '../state/session';
import { DEFAULT_RECIPES_V2, type ExportRecipe } from '../export/recipes';
import { addFolder, libraryStore, openLibrary } from '../library/store';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function until<T>(what: string, probe: () => T | null | undefined | false, seconds: number): Promise<T> {
  const end = performance.now() + seconds * 1000;
  for (;;) {
    const v = probe();
    if (v) return v;
    if (performance.now() > end) throw new Error(`${what}: not within ${seconds} s`);
    await sleep(200);
  }
}

async function write(name: string, bytes: Uint8Array) {
  await invoke('selftest_write', bytes, { headers: { 'x-selftest-name': name } });
}
const json = (v: unknown) => new TextEncoder().encode(JSON.stringify(v, null, 2));
const statusText = () => document.querySelector('[data-testid="status-line"]')?.textContent?.replace(/\s+/g, ' ').trim() ?? '';

export async function runSelfTestIfAsked(): Promise<void> {
  if (!inTauri()) return;
  type Args = { raw: string; out: string; folder: string | null; captureOne: string | null };
  let args: Args | null = null;
  try { args = await invoke<Args>('selftest_args'); } catch { return; }
  if (!args) return;
  const { raw, out } = args;
  try {
    await until('the engine host ready', () => sessionStore.getState().hostState.phase === 'ready', 120);
    // Every job of the frame the scheduler reports, as it reports them (scheduler://job).
    const seen: JobSnapshotWire[] = [];
    scheduler().onJob((j) => { if (j.frameId === raw) seen.push(j); });
    await openPaths([raw]);
    await until(`${raw} selected`, () => sessionStore.getState().selection === raw, 30);
    // Developed: the scheduler's canvas job of this frame done, its print landed, the status line says so.
    // Developed: the scheduler reported the frame's canvas develop done, the page's newest job (the
    // develop, or the full view after it) is done, the print landed, and the status line says so.
    const job = await until('the scheduler to report the develop done', () => {
      const s = sessionStore.getState();
      const develop = seen.find((j) => j.kind === 'canvasDevelop' && j.state === 'done');
      return develop && s.job && s.job.frameId === raw && s.job.state === 'done' && frameImages.print
        && /^Developed/.test(statusText()) ? develop : null;
    }, 240);
    // The canvas's own pixels (a WebGL2 canvas with preserveDrawingBuffer), as the window shows them.
    const canvas = await until('the canvas', () => document.querySelector<HTMLCanvasElement>('[data-testid="canvas"] canvas'), 10);
    await sleep(500);
    const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, 'image/png'));
    if (!blob) throw new Error('the canvas gave no PNG');
    await write('canvas.png', new Uint8Array(await blob.arrayBuffer()));
    const s = sessionStore.getState();
    await write('status.json', json({
      status: statusText(), job, pageJob: s.job, events: seen.map((j) => `${j.kind} ${j.state}${j.state === 'running' ? ` ${j.stage} ${j.fraction.toFixed(2)}` : ''}`), renderFailure: s.renderFailure, badge: s.badge, nativeSize: s.nativeSize,
      print: frameImages.print ? { width: frameImages.print.width, height: frameImages.print.height, tier: frameImages.print.tier } : null,
      canvas: { width: canvas.width, height: canvas.height },
      backend: s.hello?.backend ?? null,
      snapshots: await scheduler().snapshot(), frameSnapshot: await scheduler().snapshot(raw), budget: await scheduler().budget(),
    }));
    // One export through the dialog: this run's recipe, stored where the dialog reads its recipes.
    const recipe: ExportRecipe = { ...structuredClone(DEFAULT_RECIPES_V2[0]!), id: 'selftest', name: 'Self-test JPEG',
      format: 'jpeg', colorSpace: 'sRGB', quality: 90, longEdge: 1200, folder: { kind: 'fixed', path: out }, subfolder: 'export', existing: 'overwrite' };
    await platform().storeWrite('Export', 'recipes.json', [recipe]);
    setPages({ exportOpen: true });
    // The dialog reads its recipes when it opens: export once it shows this run's.
    await until('the dialog to show the self-test recipe', () => document.querySelector('[title="Self-test JPEG"]'), 30);
    const run = await until('the Export dialog’s Export button', () => {
      const b = document.querySelector<HTMLButtonElement>('[data-testid="export-run"]');
      return b && !b.disabled ? b : null;
    }, 30);
    run.click();
    await until('the export to start', () => sessionStore.getState().batchExporting, 30);
    await until('the export to finish', () => !sessionStore.getState().batchExporting, 600);
    const files = await platform().listImages(`${out}/export`).catch(() => []);
    if (!files.length) throw new Error(`the export wrote nothing into ${out}/export`);
    await write('export.json', json({ files: files.map((f) => ({ path: f.path, size: f.size })) }));
    // The Library on the real helper: a linked folder, then a Capture One catalog (read-only).
    const library: Record<string, unknown> = {};
    if (args.folder) {
      await addFolder(args.folder);
      const l = await until('the folder library', () => { const st = libraryStore.getState(); return st.phase === 'open' && st.total > 0 ? st : st.message ? (() => { throw new Error(`folder: ${st.message}`); })() : null; }, 60);
      library.folder = { kind: l.source?.kind, total: l.total, images: l.images.map((i) => i.file_name), path: l.source?.info.path };
    }
    if (args.captureOne) {
      await openLibrary(args.captureOne);
      const l = await until('the Capture One catalog', () => { const st = libraryStore.getState(); return st.phase === 'open' && st.source?.kind === 'captureOneCatalog' ? st : st.phase === 'failed' ? (() => { throw new Error(`Capture One: ${st.message}`); })() : null; }, 60);
      library.captureOne = { kind: l.source?.kind, readOnly: l.source?.readOnly, total: l.total, collections: l.collections.map((c) => c.title || c.name), origin: l.source?.info.origin };
    }
    library.state = await (await import('../library/store')).libraryClient().state();
    await write('library.json', json(library));
    await invoke('selftest_finish', { code: 0, reason: `developed and exported ${files.map((f) => f.path).join(', ')}` });
  } catch (e) {
    const reason = e instanceof Error ? e.message : String(e);
    try { await write('status.json', json({ failed: reason, status: statusText(), job: sessionStore.getState().job, snapshots: await scheduler().snapshot().catch(() => null) })); } catch { /* the reason still goes out */ }
    await invoke('selftest_finish', { code: 1, reason });
  }
}
