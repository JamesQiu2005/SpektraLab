// Dialogs.tsx — Settings (`Windows/SettingsWindow.swift`, the pages this port
// carries), About (licences: CC BY-SA requires the attribution be visible),
// and the engine-failure dialog.

import * as Dialog from '@radix-ui/react-dialog';
import { useEffect, useState } from 'react';
import { PillMenu, ToggleRow } from '../controls/controls';
import { t, tz } from '../i18n';
import { host } from '../host/client';
import { platform, type AppPaths } from '../platform';
import { recomputeFilmFormat, requestPrint, setPages, useSession, sessionStore } from '../state/session';
import { INTERFACE_SCALES, PREVIEW_EDGES, settingsStore, useSettings, SETTINGS_DEFAULT } from '../state/settings';
import { featureGate } from '@shared/params';

function Frame({ open, onClose, title, children, actions, testId }: { open: boolean; onClose: () => void; title: string; children: React.ReactNode; actions?: React.ReactNode; testId?: string }) {
  return (
    <Dialog.Root open={open} onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="dialog-overlay" />
        <Dialog.Content className="dialog" data-testid={testId} aria-describedby={undefined}>
          <Dialog.Title asChild>
            <h2>{title}</h2>
          </Dialog.Title>
          {children}
          <div className="dialog-actions">
            {actions}
            <Dialog.Close asChild>
              <button className="btn primary">{tz('Done', '完成')}</button>
            </Dialog.Close>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

export function SettingsDialog() {
  const open = useSession((s) => s.settingsOpen);
  const page = useSettings((s) => s.settingsPage);
  const st = useSettings((s) => s);
  const hello = useSession((s) => s.hello);
  const hostState = useSession((s) => s.hostState);
  const gate = useSessionGate();
  const [paths, setPaths] = useState<AppPaths | null>(null);
  const [diag, setDiag] = useState<string>('');
  useEffect(() => {
    if (open) {
      void platform().appPaths().then(setPaths);
      void host()
        .diagnostics()
        .then((d) => setDiag(JSON.stringify(d, null, 1)))
        .catch(() => {});
    }
  }, [open, page]);
  const set = settingsStore.getState().set;
  return (
    <Frame open={open} onClose={() => setPages({ settingsOpen: false })} title={tz('Settings', '设置')} testId="settings">
      <div className="tabs">
        {(['general', 'rendering', 'diagnostics'] as const).map((p) => (
          <button key={p} className={page === p ? 'on' : ''} onClick={() => set('settingsPage', p)}>
            {p === 'general' ? t('setTabGeneral') : p === 'rendering' ? t('setTabRendering') : t('setTabDiagnostics')}
          </button>
        ))}
      </div>
      <div className="dialog-body rail right" style={{ background: 'transparent' }}>
        {page === 'general' && (
          <>
            <div className="settings-group">
              <h3>{t('setLanguage')}</h3>
              <PillMenu
                label={t('setLanguage')}
                value={st.language}
                options={[
                  { value: 'system', label: t('languageFollowSystem') },
                  { value: 'english', label: 'English' },
                  { value: 'simplifiedChinese', label: '简体中文 (zh-Hans)' },
                ]}
                onChange={(v) => set('language', v)}
                testId="language"
              />
              <div className="caption">{t('setLanguageCaption')}</div>
            </div>
            <div className="settings-group">
              <h3>{t('setInterface')}</h3>
              <PillMenu label={t('setScale')} value={st.interfaceScale} options={INTERFACE_SCALES.map((s) => ({ value: s, label: `${s} %` }))} onChange={(v) => set('interfaceScale', v)} />
              <div className="row">
                <button
                  className="btn"
                  onClick={() => {
                    for (const k of ['leftCollapsed', 'rightCollapsed', 'filmstripCollapsed', 'leftWidth', 'rightWidth', 'collapsedSections'] as const) set(k, SETTINGS_DEFAULT[k] as never);
                  }}
                >
                  {t('setResetLayout')}
                </button>
              </div>
            </div>
          </>
        )}
        {page === 'rendering' && (
          <>
            <div className="settings-group">
              <h3>{tz('Preview', '预览')}</h3>
              <PillMenu
                label={tz('Preview', '预览')}
                value={st.previewLongEdge}
                options={PREVIEW_EDGES.map((e) => ({ value: e, label: `${e} px` }))}
                onChange={(v) => {
                  set('previewLongEdge', v);
                  // The live tier's size is a session parameter: send it, render.
                  const sid = sessionStore.getState().engineSession;
                  if (sid) void host().setParams(sid, { preview_long_edge: v }).then(() => requestPrint());
                }}
              />
              <div className="caption">
                {tz(
                  "The resolution every interactive edit renders at. The frame's own resolution is rendered separately once an edit settles, so this trades responsiveness while dragging against nothing in the finished picture.",
                  '每次交互编辑的渲染分辨率。编辑停下后会另外按照片本身的分辨率渲染，所以这里只是拖动时的流畅度，与最终画面无关。',
                )}
              </div>
            </div>
            <div className="settings-group">
              <h3>{tz('Film effects', '胶片效果')}</h3>
              <ToggleRow
                label={tz('Crop re-maps the frame', '裁剪重新映射画幅')}
                on={st.recalculateEffectsAfterCrop}
                onChange={(v) => {
                  set('recalculateEffectsAfterCrop', v);
                  queueMicrotask(recomputeFilmFormat);
                }}
              />
              <div className="caption">{tz('Whether cropping changes the physical scale of grain, halation and glare. Off — the default, and the physically true answer — the crop shows less of the same negative.', '裁剪是否改变颗粒、光晕与耀光的物理尺度。关闭（默认，也是物理上正确的做法）时，裁剪只是看到同一张负片的更小部分。')}</div>
              <ToggleRow label={tz('Decouple effects', '分离效果强度')} on={st.decoupleEffects} onChange={(v) => set('decoupleEffects', v)} />
              <div className="caption">{tz('Show a strength for each film effect beside its switch. The strengths belong to the frame: turning this off hides the sliders and changes no picture.', '在每个胶片效果的开关旁显示强度滑块。强度属于照片本身：关闭此项只会隐藏滑块，不会改变任何画面。')}</div>
            </div>
            <div className="settings-group">
              <h3>{tz('Digital Intermediate', '数字中间片')}</h3>
              <ToggleRow
                label={tz('Blue compensation', '蓝色补偿')}
                on={st.diBlueCompensation}
                disabled={!gate.digitalIntermediate}
                reason={tz('The Digital Intermediate is not available with this engine yet.', '此引擎暂不支持数字中间片。')}
                onChange={(v) => {
                  set('diBlueCompensation', v);
                  const s = sessionStore.getState();
                  sessionStore.setState({ gate: featureGate(s.unsupported, v) });
                }}
              />
            </div>
          </>
        )}
        {page === 'diagnostics' && (
          <>
            <div className="settings-group">
              <h3>{tz('This session', '本次会话')}</h3>
              <div className="caption">
                {tz('App', '应用')}: {paths?.version ?? '—'} · {paths?.os ?? ''}
                <br />
                {tz('Engine', '引擎')}: {hello ? `${hello.host_version} — ${hello.build_info}` : hostState.phase}
                <br />
                GPU: {hello?.backend?.device_name ?? '—'} ({hello?.backend?.api ?? '—'}) · {tz('Render core', '渲染核心')}: {String(hello?.capabilities?.backend?.render_core ?? '—')}
                <br />
                {tz('Not available here', '此处不可用')}: {(hello?.capabilities?.backend?.unsupported_features as string[] | undefined)?.join(', ') || '—'}
              </div>
            </div>
            <div className="settings-group">
              <h3>{tz('Logs and settings', '日志与设置')}</h3>
              <div className="caption mono">
                {tz('Logs', '日志')}: {paths?.logs}
                <br />
                {tz('Sidecars', '设置文件')}: {paths?.sidecars}
              </div>
              <div className="row" style={{ gap: 8 }}>
                <button className="btn" onClick={() => paths && void platform().reveal(paths.logs)}>
                  {tz('Show logs', '显示日志')}
                </button>
                <button className="btn" onClick={() => paths && void platform().reveal(paths.sidecars)}>
                  {tz('Show sidecars', '显示设置文件')}
                </button>
                <button className="btn" onClick={() => void host().restart()}>
                  {tz('Restart engine', '重启引擎')}
                </button>
              </div>
            </div>
            <div className="settings-group">
              <h3>{tz('Engine host', '引擎进程')}</h3>
              <div className="mono" style={{ maxHeight: 180, overflow: 'auto' }}>
                {diag}
              </div>
            </div>
          </>
        )}
      </div>
    </Frame>
  );
}

function useSessionGate() {
  return useSession((s) => s.gate);
}

export function AboutDialog() {
  const open = useSession((s) => s.aboutOpen);
  const [texts, setTexts] = useState<{ name: string; body: string }[]>([]);
  const [paths, setPaths] = useState<AppPaths | null>(null);
  useEffect(() => {
    if (!open) return;
    void platform().appPaths().then(setPaths);
    void Promise.all(
      ['SpektraLab-GPL-3.0.txt', 'Profiles-and-LUTs-CC-BY-SA-4.0.txt', 'README.txt'].map(async (name) => {
        try {
          const r = await fetch('assets/licenses/' + name);
          return { name, body: r.ok ? await r.text() : '' };
        } catch {
          return { name, body: '' };
        }
      }),
    ).then(setTexts);
  }, [open]);
  return (
    <Frame open={open} onClose={() => setPages({ aboutOpen: false })} title="SpektraLab" testId="about">
      <div className="dialog-body">
        <p>
          {tz('Version', '版本')} {paths?.version ?? '1.3.1'} — {tz('film and print emulation built on the spektrafilm engine.', '基于 spektrafilm 引擎的胶片与相纸模拟。')}
        </p>
        <p className="caption">
          {tz(
            'SpektraLab is free software under the GNU GPL, version 3 or later. The film and paper profiles are licensed CC BY-SA 4.0; their attribution follows.',
            'SpektraLab 是依据 GNU GPL 第 3 版或更新版本发布的自由软件。胶片与相纸的特性数据依据 CC BY-SA 4.0 授权，署名如下。',
          )}
        </p>
        {texts.map((x) => (
          <details key={x.name}>
            <summary>{x.name}</summary>
            <div className="mono" style={{ maxHeight: 200, overflow: 'auto' }}>
              {x.body || tz('(not bundled in this build)', '（此版本未附带）')}
            </div>
          </details>
        ))}
      </div>
    </Frame>
  );
}

/** The engine failed to start or keeps dying: say so, in words, with the log tail. */
export function HostFailure() {
  const st = useSession((s) => s.hostState);
  const [detailOpen, setDetailOpen] = useState(false);
  const [tail, setTail] = useState<string>('');
  const failed = st.phase === 'failed';
  useEffect(() => {
    if (!failed) return;
    // The host's own stderr: where a driver says what it could not do.
    void host()
      .diagnostics()
      .then((d) => setTail(((d as { stderr_tail?: string[] }).stderr_tail ?? []).join('\n')))
      .catch(() => {});
  }, [failed]);
  if (st.phase === 'restarting')
    return (
      <div className="host-banner" role="status">
        {tz('The engine stopped and is being restarted…', '引擎已停止，正在重启…')}
      </div>
    );
  if (st.phase !== 'failed') return null;
  const detail = tail || st.detail || '';
  const vulkan = /vulkan|\bvk|no .*device|GPU/i.test(st.reason + ' ' + detail);
  return (
    <Dialog.Root open>
      <Dialog.Portal>
        <Dialog.Overlay className="dialog-overlay" />
        <Dialog.Content className="dialog" data-testid="host-failure" aria-describedby={undefined}>
          <Dialog.Title asChild>
            <h2>{tz('The render engine could not start', '渲染引擎无法启动')}</h2>
          </Dialog.Title>
          <div className="dialog-body">
            <p>{st.reason}</p>
            {vulkan && (
              <p className="caption">
                {tz(
                  'SpektraLab renders on the GPU through Vulkan. Make sure a Vulkan driver is installed for your graphics card (on Linux: mesa-vulkan-drivers or your vendor’s driver; on Windows: the latest driver from your GPU vendor), then restart the engine.',
                  'SpektraLab 通过 Vulkan 在 GPU 上渲染。请确认已为显卡安装 Vulkan 驱动（Linux：mesa-vulkan-drivers 或厂商驱动；Windows：显卡厂商的最新驱动），然后重启引擎。',
                )}
              </p>
            )}
            {detail && (
              <details open={detailOpen} onToggle={(e) => setDetailOpen((e.target as HTMLDetailsElement).open)}>
                <summary>{tz('Engine log', '引擎日志')}</summary>
                <div className="mono" style={{ maxHeight: 220, overflow: 'auto' }}>
                  {detail}
                </div>
              </details>
            )}
          </div>
          <div className="dialog-actions">
            <button className="btn" onClick={() => void platform().appPaths().then((p) => platform().reveal(p.logs))}>
              {tz('Show logs', '显示日志')}
            </button>
            <button className="btn primary" onClick={() => void host().restart()}>
              {tz('Restart engine', '重启引擎')}
            </button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
