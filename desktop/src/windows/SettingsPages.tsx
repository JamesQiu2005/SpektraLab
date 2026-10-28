import { useEffect, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { host } from '../host/client';
import { inTauri } from '../host/transport';
import { platform } from '../platform';
import { tz } from '../i18n';
import { ToggleRow } from '../controls/controls';
import { clearDisplayCache, configureDisplayCache, displayCacheStatus, type DisplayCacheStatus } from '../state/displayCache';
import { checkWindowsUpdate, type UpdateStatus } from './updateCheck';

const GiB = 1024 ** 3;
export function formatBytes(value: unknown): string {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return '—';
  return value >= GiB ? `${(value / GiB).toFixed(2)} GiB` : `${(value / 1024 ** 2).toFixed(1)} MiB`;
}
type MemoryReport = { total_bytes?: number; suspended_bytes?: number; pool?: { free_bytes?: number; live_bytes?: number; frame_high_water_bytes?: number };
  persistent?: { bytes?: number; source_bytes?: number; cached_negative_bytes?: number; cached_view_bytes?: number };
  pressure?: { idle_trim_seconds?: number; idle_trims?: number } };

export function MemorySettings() {
  const [memory, setMemory] = useState<MemoryReport | null>(null);
  const [cache, setCache] = useState<DisplayCacheStatus | null>(null);
  const [cacheLoading, setCacheLoading] = useState(true);
  const [limit, setLimit] = useState('16');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  // One sample at a time; unmount cancels the timer, not an engine job. A
  // queued report cannot pile up while the worker is busy developing a RAW.
  useEffect(() => {
    let mounted = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const refresh = async () => {
      const results = await Promise.allSettled([host().memoryReport(), displayCacheStatus()]);
      if (!mounted) return;
      setCacheLoading(false);
      if (results[0].status === 'fulfilled') setMemory(results[0].value);
      if (results[1].status === 'fulfilled') {
        const value = results[1].value;
        setCache(value);
        if (!timer && value) setLimit(String(value.cap_bytes / GiB));
      }
      const failed = results.find((r) => r.status === 'rejected');
      if (failed?.status === 'rejected') setError(String(failed.reason));
      timer = setTimeout(() => void refresh(), 2000);
    };
    void refresh();
    return () => { mounted = false; clearTimeout(timer); };
  }, []);
  const changeCache = async (clear: boolean) => {
    const n = Number(limit);
    if (!clear && (!Number.isFinite(n) || n < 0 || n > 64)) {
      setError(tz('Choose a cache limit between 0 and 64 GiB.', '缓存上限应为 0 至 64 GiB。')); return;
    }
    setBusy(true); setError('');
    try {
      if (clear) await clearDisplayCache(); else await configureDisplayCache(Math.round(n * GiB));
      setCache(await displayCacheStatus());
    } catch (e) { setError(String(e)); }
    finally { setBusy(false); }
  };
  return <>
    <div className="settings-group">
      <h3>{tz('Engine allocations', '引擎分配')}</h3>
      <dl className="caption" data-testid="memory-ledger">
        <dt>{tz('GPU buffers tracked by the engine', '引擎记录的 GPU 缓冲区')}</dt><dd>{formatBytes(memory?.total_bytes)}</dd>
        <dt>{tz('Decoded sources', '解码输入')}</dt><dd>{formatBytes(memory?.persistent?.source_bytes)}</dd>
        <dt>{tz('Negative cache', '负片缓存')}</dt><dd>{formatBytes(memory?.persistent?.cached_negative_bytes)}</dd>
        <dt>{tz('Print cache', '相纸缓存')}</dt><dd>{formatBytes(memory?.persistent?.cached_view_bytes)}</dd>
        <dt>{tz('Reusable pool', '可回收缓冲池')}</dt><dd>{formatBytes(memory?.pool?.free_bytes)}</dd>
        <dt>{tz('Suspended frames on disk', '暂存到磁盘的画面')}</dt><dd>{formatBytes(memory?.suspended_bytes)}</dd>
      </dl>
      <p className="caption">{tz('This ledger counts engine allocations, not the whole process or driver memory. Disk suspension is listed separately and is not added to GPU usage.', '此账本记录引擎分配，并非整个进程或驱动的内存。磁盘暂存单独列出，不计入 GPU 占用。')}</p>
      <p className="caption">{tz('Rendering and RAW decoding run serially. Unused GPU buffers are returned when the worker becomes idle; transfer buffers use bounded chunks. Suspended editor caches are restored on demand.', '渲染和 RAW 解码依次执行；引擎空闲后归还未使用的 GPU 缓冲区，数据传输采用有上限的分块。暂停的编辑器缓存按需恢复。')}</p>
    </div>
    <div className="settings-group">
      <h3>{tz('Display cache on disk', '显示磁盘缓存')}</h3>
      <p className="caption">{tz('Recent previews also use up to 128 MiB of memory. Clear removes both memory and disk previews.', '近期预览另外使用最多 128 MiB 内存；清空会同时清除内存与磁盘预览。')}</p>
      {cache ? <>
        <p className="caption">{formatBytes(cache.bytes)} / {formatBytes(cache.cap_bytes)} · {cache.entries} {tz('pictures', '张图片')}</p>
        <label>{tz('Limit (GiB; 0 disables disk caching)', '上限（GiB；0 关闭磁盘缓存）')}
          <input aria-label={tz('Cache limit', '缓存上限')} type="number" min="0" max="64" step="1" value={limit} onChange={(e) => setLimit(e.target.value)} disabled={busy} style={{ width: 80, marginLeft: 8 }} />
        </label>
        <div className="row" style={{ gap: 8, marginTop: 10 }}>
          <button className="btn" disabled={busy} onClick={() => void changeCache(false)}>{tz('Apply limit', '应用上限')}</button>
          <button className="btn" disabled={busy} onClick={() => void changeCache(true)}>{tz('Clear display cache', '清空显示缓存')}</button>
          <button className="btn" onClick={() => void platform().reveal(cache.path).catch((e) => setError(String(e)))}>{tz('Show folder', '显示目录')}</button>
        </div>
        <p className="caption mono" style={{ overflowWrap: 'anywhere' }}>{cache.path}</p>
        <p className="caption">{tz('Only rendered previews are cached; originals, edits and exports are kept separately. Entries are checked and evicted by least recent use. Clearing does not delete photographs or edits.', '这里只缓存渲染预览，原片、编辑参数和导出文件独立保存。缓存按校验及最近使用情况管理；清空不会删除照片或编辑参数。')}</p>
      </> : <p className="caption">{!inTauri()
        ? tz('Available in the desktop application.', '此功能在桌面应用中可用。')
        : cacheLoading ? tz('Loading display cache…', '正在加载显示缓存…')
          : tz('Display cache is unavailable.', '显示缓存不可用。')}</p>}
    </div>
    {error && <p className="caption" role="alert">{error}</p>}
  </>;
}

export function UpdateSettings({ version, os }: { version?: string; os?: string }) {
  const [status, setStatus] = useState<UpdateStatus | null>(null);
  const [checking, setChecking] = useState(false);
  const check = async () => {
    setChecking(true);
    setStatus(await checkWindowsUpdate(version ?? ''));
    setChecking(false);
  };
  return <div className="settings-group">
    <h3>{tz('Windows updates', 'Windows 更新')}</h3>
    <button className="btn" disabled={checking || !version || (!!os && !/windows/i.test(os))} onClick={() => void check()}>
      {checking ? tz('Checking…', '正在检查…') : !version ? tz('Loading app version…', '正在读取应用版本…') : tz('Check for Windows updates', '检查 Windows 更新')}
    </button>
    <p className="caption">{tz('Checks public releases only when pressed. Only a published Windows x64 package counts as an update. No photographs or settings are sent; installation is manual.', '仅在点击时检查公开发布。只有已发布的 Windows x64 安装包才视为更新；不发送照片或设置，更新由你手动安装。')}</p>
    {status && <div className="caption" role="status">
      {status.kind === 'available' || status.kind === 'current' ? <>
        {status.kind === 'available' ? tz('Windows update available', '发现 Windows 更新') : tz('No newer matching Windows release', '没有更新的匹配 Windows 版本')}: {status.version}<br />{status.asset}
        <div><button className="btn" onClick={() => void platform().openUrl(status.url)}>{tz('Open release page', '打开发布页面')}</button></div>
      </> : status.kind === 'unavailable' ? tz('No Windows x64 package was found in the latest 30 releases. A macOS release is not a Windows update.', '最近 30 个发布中未找到 Windows x64 包。macOS 的发布不代表 Windows 有更新。') : `${tz('Check failed', '检查失败')}: ${'reason' in status ? status.reason : ''}`}
    </div>}
  </div>;
}

export interface AgentAccess { enabled: boolean; runtime_available: boolean; executable: string; command: string; mcp_config: unknown }
export function AgentsSettings() {
  const [access, setAccess] = useState<AgentAccess | null>(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState('');
  useEffect(() => {
    let alive = true;
    if (inTauri()) void invoke<AgentAccess>('agent_access_get').then((v) => { if (alive) setAccess(v); }).catch((e) => { if (alive) setError(String(e)); });
    return () => { alive = false; };
  }, []);
  const action = async (fn: () => Promise<void>) => { setBusy(true); setError(''); setNotice(''); try { await fn(); } catch (e) { setError(String(e)); } finally { setBusy(false); } };
  return <div className="settings-group">
    <h3>{tz('Command line and agents', '命令行与智能体')}</h3>
    <ToggleRow label={tz('Allow local command line and agent access', '允许本地命令行及智能体访问')} on={access?.enabled ?? false} disabled={!access || busy}
      onChange={(enabled) => void action(async () => setAccess(await invoke<AgentAccess>('agent_access_set', { enabled })))} />
    <p className="caption">{tz('Off by default. When enabled, local tools can read images and saved edits, change edits, and export through the same engine. No network listener is opened. App and agent batch operations share an exclusive workspace lock.', '默认关闭。开启后，本地工具可读取照片及编辑参数、修改参数，并通过同一引擎导出。不会打开网络监听；应用和智能体批量操作共用独占工作区锁。')}</p>
    {!access ? <p className="caption">{!inTauri()
      ? tz('Available in the desktop application.', '此功能在桌面应用中可用。')
      : error ? tz('Could not load local tool settings.', '无法加载本地工具设置。')
        : tz('Loading local tool settings…', '正在加载本地工具设置…')}</p> : <>
      {!access.runtime_available && <p className="caption" role="status">{tz('This build does not include the agent runtime.', '此构建尚未包含智能体运行环境。')}</p>}
      <div className="row" style={{ gap: 8 }}>
        <button className="btn" disabled={busy || !access.runtime_available} onClick={() => void action(async () => { const p = await invoke<string>('agent_cli_install'); setNotice(`${tz('Command installed', '已安装命令')}: ${p}`); })}>{tz('Install command', '安装命令')}</button>
        <button className="btn" disabled={busy} onClick={() => void action(async () => { await invoke('agent_cli_uninstall'); setNotice(tz('Managed command removed.', '已移除本应用安装的命令。')); })}>{tz('Remove command', '移除命令')}</button>
      </div>
      <p className="caption mono" style={{ overflowWrap: 'anywhere' }}>{access.executable}</p>
      <p className="caption">{tz('The command wrapper points to this copy of the app; reinstall it after moving the app. Your PATH is not modified.', '命令指向当前这份应用，移动应用后请重新安装命令。此操作不会修改 PATH。')}</p>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: 'calc(12px * var(--ui-scale))', marginTop: 'calc(12px * var(--ui-scale))' }}>
        <details style={{ width: '100%', minWidth: 0 }}>
          <summary style={{ cursor: 'pointer', lineHeight: 1.5, paddingBlock: 'calc(4px * var(--ui-scale))' }}>{tz('MCP configuration', 'MCP 配置')}</summary>
          <pre style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere', lineHeight: 1.5, margin: 'calc(8px * var(--ui-scale)) 0 0' }}>{JSON.stringify(access.mcp_config, null, 2)}</pre>
        </details>
        <button className="btn" style={{ height: 'auto', maxWidth: '100%', lineHeight: 1.4, padding: 'calc(6px * var(--ui-scale)) calc(14px * var(--ui-scale))' }} disabled={busy || !access.runtime_available}
          onClick={() => void action(async () => { await navigator.clipboard.writeText(JSON.stringify(access.mcp_config, null, 2)); setNotice(tz('Configuration copied.', '配置已复制。')); })}>{tz('Copy MCP configuration', '复制 MCP 配置')}</button>
      </div>
    </>}
    {notice && <p className="caption" role="status">{notice}</p>}
    {error && <p className="caption" role="alert">{error}</p>}
  </div>;
}
