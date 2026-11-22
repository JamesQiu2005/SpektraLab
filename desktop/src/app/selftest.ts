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
// Export button clicked) and wait for its file. Then the Library on the real
// helper: a linked folder of two RAWs, and — in Develop, from the browser at
// the window's right (PRD-W5) — a press on the other frame's row, which must
// move the editing session to it and develop it. Any failure ends the run with
// its reason; the Rust watchdog ends a run that never ends.

import { invoke } from '@tauri-apps/api/core';
import { inTauri } from '../host/transport';
import { platform } from '../platform';
import { scheduler } from '../scheduler';
import type { JobSnapshotWire } from '../scheduler/types';
import { frameImages } from '../state/frames';
import { flushSave, openPaths, selectAllFrames, sessionStore, setPages, setParams } from '../state/session';
import { DEFAULT_RECIPES_V2, type ExportRecipe } from '../export/recipes';
import { addFolder, closeLibrary, libraryClient, libraryStore, openCaptureOneDialog, openLibrary, pick, refresh, setRating } from '../library/store';
import { lib, LibraryError, type ImageRow } from '../library/client';
import { setLibraryView, setUi, setWorkspace, uiStore } from './ui';
import { exportRun } from '../export/ExportPage';
import { host } from '../host/client';

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
const developed = () => /^(Developed|已冲洗)/.test(statusText());

async function startExport(recipe: ExportRecipe) {
  await platform().storeWrite('Export', 'recipes.json', [recipe]);
  setPages({ exportOpen: true });
  await until('the dialog to show the self-test recipe', () =>
    Array.from(document.querySelectorAll('[title]')).some((el) => el.getAttribute('title') === recipe.name), 30);
  const run = await until('the Export dialog’s Export button', () => {
    const button = document.querySelector<HTMLButtonElement>('[data-testid="export-run"]');
    return button && !button.disabled ? button : null;
  }, 30);
  run.click();
  await until('the export to start', () => sessionStore.getState().batchExporting, 30);
}

async function completedExport() {
  await until('the export dialog to close', () => !sessionStore.getState().batchExporting
    && !sessionStore.getState().exportOpen, 90);
}

async function exerciseBatch(recipe: ExportRecipe, folder: string, out: string) {
  const frames = (await platform().listImages(folder)).map((file) => file.path).sort();
  const count = frames.length;
  if (count < 2) throw new Error('Batch self-test needs at least two frames');
  await openPaths(frames);
  selectAllFrames();
  if (sessionStore.getState().picked.length !== count) throw new Error('All batch frames must be selected');
  const jobs: JobSnapshotWire[] = [];
  const unlisten = scheduler().onJob((job) => { if (job.kind === 'export') jobs.push(job); });
  try {
    await startExport({ ...recipe, name: 'Self-test stopped batch', subfolder: 'stop-batch' });
    await until('the first export to be in progress', () => jobs.some((job) => job.state === 'running'), 30);
    const ring = await until('the export ring', () => document.querySelector<HTMLButtonElement>('[data-testid="export-ring"]'), 10);
    ring.click();
    const stop = await until('the Stop after this frame button', () => {
      const button = document.querySelector<HTMLButtonElement>('[data-testid="stop-after-frame"]');
      return button && !button.disabled ? button : null;
    }, 10);
    stop.click();
    await completedExport();
    const stopped = await platform().listImages(`${out}/stop-batch`);
    const stoppedProgress = exportRun.getState().progress;
    const stoppedJobs = new Set(jobs.map((job) => job.jobId));
    if (stopped.length !== 1 || stoppedJobs.size !== 1 || !jobs.some((job) => job.state === 'done')
        || stoppedProgress?.done !== 1 || stoppedProgress.total !== count || !stoppedProgress.stopped)
      throw new Error(`Stop after frame: ${stopped.length} files, ${stoppedJobs.size} jobs, progress ${JSON.stringify(stoppedProgress)}`);
    jobs.length = 0;
    await startExport({ ...recipe, name: 'Self-test full batch', subfolder: 'full-batch' });
    await completedExport();
    const completed = await platform().listImages(`${out}/full-batch`);
    const completedFrames = new Set(jobs.filter((job) => job.state === 'done').map((job) => job.frameId));
    if (completed.length !== count || !frames.every((frame) => completedFrames.has(frame)))
      throw new Error(`Full batch: ${completed.length} files for ${completedFrames.size} completed frames; expected ${count}`);
    await write('batch.json', json({ frames, stopped, completed, stoppedProgress }));
  } finally {
    unlisten();
  }
}

async function checkRestart() {
  const selected = sessionStore.getState().selection;
  const events: string[] = [];
  const unlisten = host().onState((state) => events.push(state.phase));
  try {
    await write('restart-ready.json', json({ selected }));
    await until('the engine to restart and redevelop the selected frame', () => {
      const state = sessionStore.getState();
      return events.includes('restarting') && events.at(-1) === 'ready' && state.selection === selected
        && state.engineSession && state.job?.state === 'done' && developed();
    }, 60);
    await write('restart.json', json({ events, selected, job: sessionStore.getState().job }));
  } finally {
    unlisten();
  }
}

/** Exercise the pictures in the running WebView2 from a real linked folder. */
async function exerciseLibraryPreviews(images: ImageRow[]) {
  const mode = await until('the Library mode button', () => document.querySelector<HTMLButtonElement>('[data-testid="mode-library"]'), 10);
  mode.click();
  await until('Library mode', () => uiStore.getState().workspace === 'library', 10);
  const examples = images.filter((image) => image.exists !== false).slice(0, 2);
  if (examples.length !== 2) throw new Error('Library preview self-test needs two originals with previews');
  let previous = '';
  const decoded = [];
  for (const image of examples) {
    const tile = await until('the linked source’s tile', () =>
      document.querySelector<HTMLButtonElement>(`[data-testid="library-tile"][data-uuid="${CSS.escape(image.uuid)}"]`), 15);
    tile.click();
    const picture = await until(`the preview of ${image.file_name}`, () => {
      const viewer = document.querySelector<HTMLImageElement>('[data-testid="library-viewer-image"]');
      const thumb = tile.querySelector('img');
      return viewer && viewer.alt === image.file_name && viewer.naturalWidth > 0 && thumb?.src === viewer.src ? viewer : null;
    }, 40);
    if (picture.src === previous) throw new Error('The previously selected picture remained in the viewer');
    previous = picture.src;
    decoded.push({ file: image.file_name, width: picture.naturalWidth, height: picture.naturalHeight });
  }
  return decoded;
}

async function exerciseLibraryRestart(out: string, image: ImageRow) {
  const client = libraryClient();
  const source = libraryStore.getState().source;
  const before = await client.state();
  if (!source || !before.running) throw new Error('Expected a running library helper');
  pick(image.uuid);
  await write('library-restart-ready.json', json({ handle: source.handle, launches: before.launches }));
  const deadline = performance.now() + 20000;
  while ((await client.state()).running) {
    if (performance.now() > deadline) throw new Error('The test helper did not stop');
    await sleep(100);
  }
  const rawHandle = source.handle.split(':').at(-1);
  // Occupy the old numeric handle in the new process with a different library.
  let reused = false;
  for (let i = 0; i < 8 && !reused; i++) {
    const distractor = await lib.create(client, `${out}/restart-distractor-${i}.spkcatalog`, 'catalog');
    reused = distractor.library.split(':').at(-1) === rawHandle;
  }
  if (!reused) throw new Error('The fresh helper did not reuse the old handle');
  let rejected = false;
  try {
    await lib.setRating(client, source.handle, [image.uuid], 2);
  } catch (e) {
    if (!(e instanceof LibraryError) || e.code !== 'stale_library') throw e;
    rejected = true;
  }
  if (!rejected) throw new Error('A write with the old helper handle reached another library');
  await refresh();
  const recovered = libraryStore.getState();
  const after = await client.state();
  const rating = recovered.images.find((row) => row.uuid === image.uuid)?.rating;
  if (after.launches !== before.launches + 1 || recovered.source?.info.uuid !== source.info.uuid
      || recovered.source.handle === source.handle || recovered.focus !== image.uuid || rating !== 4) {
    throw new Error('The library did not recover its identity, selection and rating');
  }
  return { launches: [before.launches, after.launches], handleReused: reused, staleWriteRejected: rejected, rating, focus: recovered.focus };
}

// Exercise the two spellings separately: the native picker can return a Win32
// namespace path, while the helper should publish its regular drive/UNC path.
function extendedWindowsPath(path: string): string {
  const native = path.replaceAll('/', '\\');
  return native.startsWith('\\\\') ? '\\\\?\\UNC\\' + native.slice(2) : '\\\\?\\' + native;
}

async function exerciseCaptureOneRelink(folder: string, wrongFolder: string, verbatim: boolean) {
  setWorkspace('library');
  setLibraryView('grid');
  setUi({ fullGrid: false });
  const offline = libraryStore.getState().images.find((row) => row.exists === false);
  if (!offline) throw new Error('Capture One relink fixture needs an offline original');
  const tile = await until('the offline photo tile', () => Array.from(document.querySelectorAll<HTMLButtonElement>('[data-testid="library-tile"]'))
    .find((el) => el.dataset.uuid === offline.uuid), 20);
  tile.click();
  const dialogs = platform();
  const pickFolder = dialogs.pickFolder;
  const row = () => libraryStore.getState().images.find((r) => r.uuid === offline.uuid);
  const locate = async (result: string | null) => {
    let opened = false;
    dialogs.pickFolder = async () => { opened = true; return result; };
    const button = await until('the Locate Folder button', () => document.querySelector<HTMLButtonElement>('[data-testid="locate-original-folder"]'), 20);
    button.click();
    await until('the folder picker and refresh', () => opened && !libraryStore.getState().locating, 20);
  };
  try {
    await locate(null);
    if (!row() || row()?.path !== offline.path) throw new Error('Cancelling Locate Folder changed the source path');
    await locate(wrongFolder);
    if (row()?.exists !== false || row()?.path !== offline.path || !libraryStore.getState().message)
      throw new Error('An empty folder changed the path or did not show the offline message');
    await locate(verbatim ? extendedWindowsPath(folder) : folder);
  } finally {
    dialogs.pickFolder = pickFolder;
  }
  const online = row();
  if (!online?.exists || online.path.replaceAll('\\', '/') !== `${folder.replaceAll('\\', '/')}/${offline.file_name}` ||
      online.rating !== offline.rating || online.color_tag !== offline.color_tag || libraryStore.getState().focus !== offline.uuid)
    throw new Error('Locate Folder did not recover the selected original and its metadata');
  await until('the recovered original preview', () => document.querySelector('[data-testid="library-viewer-image"]'), 20);
  return online;
}

export async function runSelfTestIfAsked(): Promise<void> {
  if (!inTauri()) return;
  type Args = { raw: string; out: string; folder: string | null; captureOne: string | null; exerciseBatch: boolean;
    captureOneRelink?: string | null; captureOneVerbatim?: boolean;
    exerciseLibraryPreviews?: boolean; exerciseLibraryRestart?: boolean };
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
        && developed() ? develop : null;
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
    await startExport(recipe);
    await completedExport();
    const files = await platform().listImages(`${out}/export`).catch(() => []);
    if (!files.length) throw new Error(`the export wrote nothing into ${out}/export`);
    await write('export.json', json({ files: files.map((f) => ({ path: f.path, size: f.size })) }));
    // The Library on the real helper: a linked folder, then a Capture One catalog (read-only).
    const library: Record<string, unknown> = {};
    if (args.folder) {
      const testExposure = 0.75;
      // spklib serialises Windows paths with forward slashes.
      const originalPath = raw.replaceAll('\\', '/');
      const isOriginal = (path: string | null) => path?.replaceAll('\\', '/') === originalPath;
      if (args.exerciseLibraryPreviews) {
        setParams((params) => ({ ...params, exposureCompensationEV: testExposure }));
        await flushSave();
      }
      await addFolder(args.folder);
      let l = await until('the folder library', () => { const st = libraryStore.getState(); return st.phase === 'open' && st.total > 0 ? st : st.message ? (() => { throw new Error(`folder: ${st.message}`); })() : null; }, 60);
      library.folder = { kind: l.source?.kind, total: l.total, images: l.images.map((i) => i.file_name), path: l.source?.info.path };
      if (args.exerciseLibraryPreviews) {
        const opened = l.source;
        const first = l.images.find((image) => isOriginal(image.path));
        const recent = l.recent.find((source) => source.path === opened?.info.path);
        if (!first || opened?.kind !== 'folder' || !recent?.catalogPath) throw new Error('The linked folder has no recent catalogue');
        pick(first.uuid);
        await setRating(4);
        await closeLibrary();
        await openLibrary(recent.path);
        const reopened = libraryStore.getState();
        const rated = reopened.images.find((image) => image.uuid === first.uuid);
        if (reopened.source?.info.uuid !== opened.info.uuid || reopened.source.kind !== 'folder'
            || reopened.source.catalogPath !== opened.catalogPath || reopened.total !== l.total || rated?.rating !== 4) {
          throw new Error(`The linked folder did not reopen with its saved rating: ${reopened.message ?? rated?.rating}`);
        }
        library.reopened = { catalogue: reopened.source.info.uuid, image: rated.uuid, rating: rated.rating, total: reopened.total };
        if (args.exerciseLibraryRestart) library.helperRestart = await exerciseLibraryRestart(out, rated);
        l = libraryStore.getState();
        library.previews = await exerciseLibraryPreviews(l.images);
      }
      // A second frame, opened from the browser in Develop: its row pressed, as a person would.
      const other = l.images.find((i) => !isOriginal(i.path) && i.exists !== false);
      if (!other) throw new Error(`the folder library has no second frame: ${l.images.map((i) => i.file_name).join(', ')}`);
      if (uiStore.getState().workspace !== 'develop') (document.querySelector('[data-testid="mode-develop"]') as HTMLButtonElement | null)?.click();
      const seenOther: JobSnapshotWire[] = [];
      scheduler().onJob((j) => { if (j.frameId === other.path) seenOther.push(j); });
      const row = await until('the second frame’s row in the browser', () => document.querySelector<HTMLElement>(`[data-testid="browser"] [data-uuid="${other.uuid}"]`), 30);
      row.click();
      await until(`${other.file_name} open on the page`, () => sessionStore.getState().selection === other.path, 60);
      const second = await until('the scheduler to report the second frame developed', () => {
        const st = sessionStore.getState();
        const develop = seenOther.find((j) => j.kind === 'canvasDevelop' && j.state === 'done');
        return develop && st.job && st.job.frameId === other.path && st.job.state === 'done' && frameImages.print
          && developed() ? develop : null;
      }, 240);
      library.second = {
        file: other.file_name, path: other.path, mode: uiStore.getState().workspace, status: statusText(), job: second,
        events: seenOther.map((j) => `${j.kind} ${j.state}`), selection: sessionStore.getState().selection,
        browserFocus: libraryStore.getState().focus === other.uuid, frameTitle: document.querySelector('[data-testid="frame-title"]')?.textContent ?? '',
        print: frameImages.print ? { width: frameImages.print.width, height: frameImages.print.height } : null,
      };
      if (args.exerciseLibraryPreviews) {
        const original = l.images.find((image) => isOriginal(image.path))!;
        const tile = await until('the original frame in the reopened folder', () =>
          document.querySelector<HTMLButtonElement>(`[data-testid="library-tile"][data-uuid="${CSS.escape(original.uuid)}"]`), 15);
        tile.click();
        await until('the saved exposure restored from the original frame', () => {
          const state = sessionStore.getState();
          return isOriginal(state.selection) && state.engineSession && state.job?.state === 'done'
            && state.sidecar.params.exposureCompensationEV === testExposure && developed();
        }, 90);
        library.restoredExposure = testExposure;
      }
    }
    if (args.captureOne) {
      const catalog = args.captureOne;
      const dialogs = platform();
      const pickFolder = dialogs.pickFolder;
      try {
        dialogs.pickFolder = async () => args.captureOneVerbatim ? extendedWindowsPath(catalog) : catalog;
        await openCaptureOneDialog();
      } finally {
        dialogs.pickFolder = pickFolder;
      }
      const l = libraryStore.getState();
      if (l.phase !== 'open' || l.source?.kind !== 'captureOneCatalog' || !l.source.readOnly)
        throw new Error(`Capture One open: ${l.message ?? l.phase}`);
      const recent = l.recent[0];
      if (recent?.path.replaceAll('\\', '/') !== catalog.replaceAll('\\', '/') || !recent.catalogPath)
        throw new Error('Capture One recent entry did not retain its source and mirror');
      const relinked = args.captureOneRelink ? await exerciseCaptureOneRelink(args.captureOneRelink, out, !!args.captureOneVerbatim) : null;
      await closeLibrary();
      await openLibrary(recent.path);
      const reopened = libraryStore.getState();
      if (reopened.phase !== 'open' || reopened.source?.info.uuid !== l.source.info.uuid ||
          reopened.source.info.path !== recent.path || reopened.total !== l.total || !reopened.source.readOnly)
        throw new Error(`Capture One recent reopen: ${reopened.message ?? reopened.phase}`);
      if (relinked && !reopened.images.some((row) => row.uuid === relinked.uuid && row.exists && row.path === relinked.path))
        throw new Error('Capture One did not retain the new path when reopened');
      library.captureOne = { kind: l.source.kind, readOnly: l.source.readOnly, total: l.total,
        collections: l.collections.map((c) => c.title || c.name), origin: l.source.info.origin,
        recentPath: recent.path, mirrorPath: recent.catalogPath, reopened: true, ...(relinked && { relinked }) };
    }
    library.state = await (await import('../library/store')).libraryClient().state();
    await write('library.json', json(library));
    if (args.exerciseBatch && args.folder) {
      await exerciseBatch(recipe, args.folder, out);
      await checkRestart();
    }
    await invoke('selftest_finish', { code: 0, reason: `developed and exported ${files.map((f) => f.path).join(', ')}` });
  } catch (e) {
    const reason = e instanceof Error ? e.message : String(e);
    try { await write('status.json', json({ failed: reason, status: statusText(), job: sessionStore.getState().job, snapshots: await scheduler().snapshot().catch(() => null) })); } catch { /* the reason still goes out */ }
    await invoke('selftest_finish', { code: 1, reason });
  }
}
