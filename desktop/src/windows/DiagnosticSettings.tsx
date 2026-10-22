import { useEffect, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { PillMenu, ToggleRow } from '../controls/controls';
import { host } from '../host/client';
import { inTauri } from '../host/transport';
import { platform, type AppPaths } from '../platform';
import { tz } from '../i18n';
import { diagnosticReport } from './diagnosticReport';

interface DiagnosticConfig {
  level: 'error' | 'info' | 'debug'; per_node: boolean; export_job_log: boolean;
  days: number; megabytes: number; files: number; directory: string | null;
}
interface DiagnosticStatus {
  settings: DiagnosticConfig; directory: string; cleanup_error: string | null;
  previous_session: { clean_exit?: boolean } | null;
}
export function DiagnosticSettings({ paths, hello, includePaths }: { paths: AppPaths | null; hello: unknown; includePaths: boolean }) {
  const [status, setStatus] = useState<DiagnosticStatus | null>(null);
  const [draft, setDraft] = useState<DiagnosticConfig | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState('');
  const [error, setError] = useState('');
  useEffect(() => {
    let alive = true;
    if (inTauri()) void invoke<DiagnosticStatus>('diagnostics_get').then((s) => { if (alive) { setStatus(s); setDraft(s.settings); } }).catch((e) => { if (alive) setError(String(e)); });
    return () => { alive = false; };
  }, []);
  const action = async (fn: () => Promise<void>) => {
    setBusy(true); setError(''); setNotice(''); try { await fn(); } catch (e) { setError(String(e)); } finally { setBusy(false); }
  };
  const save = async (settings: DiagnosticConfig) => {
    const s = await invoke<DiagnosticStatus>('diagnostics_set', { settings }); setStatus(s); setDraft(s.settings);
    setNotice(tz('Saved. Host verbosity and node timings apply on the next engine restart; a new log directory applies on the next app launch.', '已保存。宿主日志和逐节点计时在下次重启引擎时生效；日志目录在下次启动应用时生效。'));
  };
  const bundle = () => void action(async () => {
    const path = await platform().pickSave(tz('Save diagnostic bundle', '保存诊断包'), 'SpektraLab-diagnostics.zip', 'zip');
    if (!path) return;
    const [d, memory] = await Promise.all([host().diagnostics(), host().memoryReport().catch(() => null)]);
    const result = await invoke<string>('diagnostics_save_bundle', { path, summary: diagnosticReport(paths, hello, d, includePaths, memory), includePaths });
    setNotice(`${tz('Saved', '已保存')}: ${result}`);
  });
  return <>
    <div className="settings-group">
      <h3>{tz('Recording diagnostics', '记录诊断')}</h3>
      {draft && status ? <>
        <PillMenu label={tz('Log level', '日志级别')} value={draft.level} options={[
          { value: 'error', label: tz('Errors', '错误') }, { value: 'info', label: tz('Normal', '正常') }, { value: 'debug', label: tz('Debug', '调试') },
        ].filter((o) => !draft.per_node || o.value !== 'error')} onChange={(level) => { if (!busy) void action(() => save({ ...draft, level: level as DiagnosticConfig['level'] })); }} />
        <ToggleRow label={tz('Per-node GPU timings', '逐节点 GPU 计时')} on={draft.per_node} disabled={busy}
          onChange={(per_node) => void action(() => save({ ...draft, per_node, level: per_node && draft.level === 'error' ? 'info' : draft.level }))} />
        <p className="caption">{tz('Detailed timings add GPU synchronization and diagnostic overhead. Use them to investigate a slow frame; turn them off for normal use and performance measurements. Restart the engine to apply.', '详细计时会增加 GPU 同步及诊断开销。仅在排查慢帧时启用；正常使用及正式性能测量时请关闭。重启引擎后生效。')}</p>
        <ToggleRow label={tz('Write a job log beside exports', '在导出旁保存任务日志')} on={draft.export_job_log} disabled={busy}
          onChange={(export_job_log) => void action(() => save({ ...draft, export_job_log }))} />
        <p className="caption">{tz('Writes the frozen request, source/output paths and measured timings to a separate JSON file beside each completed export. Off by default; no image pixels are logged.', '在每张已完成导出的旁边保存独立 JSON，包含冻结参数、输入/输出路径和实测时间。默认关闭，不记录图像像素。')}</p>
        <p className="caption">{status.previous_session?.clean_exit === false ? tz('The previous session did not record a clean exit.', '上次会话未记录正常退出。') : status.previous_session?.clean_exit === true ? tz('The previous session exited cleanly.', '上次会话正常退出。') : tz('No previous session record.', '尚无上次会话记录。')}</p>
      </> : <p className="caption">{!inTauri()
        ? tz('Available in the desktop application.', '此功能在桌面应用中可用。')
        : error ? tz('Could not load diagnostic settings.', '无法加载诊断设置。')
          : tz('Loading diagnostic settings…', '正在加载诊断设置…')}</p>}
    </div>
    {draft && status && <div className="settings-group">
      <h3>{tz('Log retention', '日志保留')}</h3>
      {([['days', 1, 365, tz('Days', '天')], ['megabytes', 10, 10000, 'MB'], ['files', 1, 500, tz('Files', '文件')]] as const).map(([key, min, max, label]) =>
        <label key={key} className="row" style={{ justifyContent: 'space-between' }}>{label}<input aria-label={label} type="number" min={min} max={max} disabled={busy}
          value={Number.isNaN(draft[key]) ? '' : draft[key]} onChange={(e) => setDraft({ ...draft, [key]: e.target.value === '' ? NaN : Number(e.target.value) })} style={{ width: 90 }} /></label>)}
      <p className="caption">{tz('Oldest owned log files are removed at launch, after changing limits and periodically while the engine is idle. The active log is kept; older rotations can be removed.', '启动时、修改上限后及引擎空闲时定期清理最旧的本应用日志。保留当前正在写入的日志，之前轮换的日志可以清理。')}</p>
      <div className="row" style={{ gap: 8 }}>
        <button className="btn" disabled={busy} onClick={() => void action(() => save(draft))}>{tz('Apply retention', '应用保留设置')}</button>
        <button className="btn" disabled={busy} onClick={() => void action(async () => { const count = await invoke<number>('diagnostics_clear_logs'); setNotice(`${tz('Logs removed', '已清理日志')}: ${count}`); })}>{tz('Clear old logs', '清空旧日志')}</button>
      </div>
      <p className="caption mono" style={{ overflowWrap: 'anywhere' }}>{status.directory}</p>
      {draft.directory && draft.directory !== status.directory && <p className="caption mono">{tz('Next launch', '下次启动')}: {draft.directory}</p>}
      <button className="btn" disabled={busy} onClick={() => void action(async () => { const directory = await platform().pickFolder(tz('Choose log directory', '选择日志目录')); if (directory) await save({ ...draft, directory }); })}>{tz('Choose log directory…', '选择日志目录…')}</button>
      {status.cleanup_error && <p className="caption" role="alert">{status.cleanup_error}</p>}
    </div>}
    <div className="settings-group">
      <h3>{tz('Diagnostic bundle', '诊断包')}</h3>
      <button className="btn" disabled={busy || !status} onClick={bundle}>{tz('Save diagnostic bundle…', '保存诊断包…')}</button>
      <p className="caption">{tz('One ZIP containing versions, settings, capabilities, memory ledger, prior exit status and recent logs. It is saved where you choose and is never uploaded. Unless names are enabled below, log records containing paths or image names are omitted.', '一个 ZIP，包含版本、设置、引擎能力、内存账本、上次退出状态和最近日志。只保存到你选择的位置，不会上传。若未开启下方的名称选项，包含路径或图像名称的日志记录会被略去。')}</p>
    </div>
    {notice && <p className="caption" role="status">{notice}</p>}
    {error && <p className="caption" role="alert">{error}</p>}
  </>;
}
