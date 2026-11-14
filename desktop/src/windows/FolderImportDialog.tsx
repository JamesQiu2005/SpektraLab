import * as Dialog from '@radix-ui/react-dialog';
import { useState } from 'react';
import { useStore } from 'zustand';
import { Checkbox } from '../controls/controls';
import { tz } from '../i18n';
import { folderImportStore, finishFolderImport, type FolderImportRequest } from '../state/folderImport';
import { settingsStore } from '../state/settings';

function ImportOptions({ request }: { request: FolderImportRequest }) {
  const [rawOnly, setRawOnly] = useState(settingsStore.getState().folderRawOnly);
  return <Dialog.Root open onOpenChange={(open) => { if (!open) finishFolderImport(null); }}>
    <Dialog.Portal>
      <Dialog.Overlay className="dialog-overlay" />
      <Dialog.Content className="dialog" data-testid="folder-import-dialog" aria-describedby="folder-import-description">
        <Dialog.Title asChild><h2>{tz('Import folder', '导入文件夹')}</h2></Dialog.Title>
        <div className="dialog-body">
          <p className="caption" style={{ overflowWrap: 'anywhere' }}>{request.folder}</p>
          <label className="row" style={{ justifyContent: 'flex-start', gap: 10 }}>
            <Checkbox on={rawOnly} onChange={setRawOnly} label={tz('Import RAW files only', '只导入 RAW 文件')} />
            {tz('Import RAW files only', '只导入 RAW 文件')}
          </label>
          <p id="folder-import-description" className="caption">{tz(
            `Found ${request.total} photographs, including ${request.rawCount} RAW files. This choice is remembered for the next folder.`,
            `找到 ${request.total} 张照片，其中 ${request.rawCount} 张 RAW。下次导入会沿用本次选择。`,
          )}</p>
          <p className="caption">{tz('Files selected with Open Images are always kept, including JPEGs.', '通过“打开图片”明确选择的文件仍会导入，包括 JPEG。')}</p>
          </div>
        <div className="dialog-actions">
          <button className="btn" onClick={() => finishFolderImport(null)}>{tz('Cancel', '取消')}</button>
          <button className="btn primary" onClick={() => finishFolderImport(rawOnly)}>{tz('Import', '导入')}</button>
        </div>
      </Dialog.Content>
    </Dialog.Portal>
  </Dialog.Root>;
}

export function FolderImportDialog() {
  const request = useStore(folderImportStore, (s) => s.request);
  return request ? <ImportOptions key={request.id} request={request} /> : null;
}
