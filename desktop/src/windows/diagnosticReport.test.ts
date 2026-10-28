import { expect, it } from 'vitest';
import { diagnosticReport } from './diagnosticReport';
it('omits local paths, arguments, frame metadata and logs unless explicitly included', () => {
  const d = { state: { phase: 'ready', detail: 'D:/secret/photo.ARW' }, launch: { program: 'D:/secret/host.exe', args: ['D:/secret'], origin: 'bundled sidecar' }, stderr_tail: ['photo.ARW failed'] };
  const h = { host_version: '1', backend: { api: 'Vulkan', device_name: 'GPU' }, unrelated: 'secret' };
  expect(JSON.stringify(diagnosticReport({ version: '1.3.1' }, h, d, false))).not.toMatch(/secret|photo|stderr|program|unrelated/);
  expect(JSON.stringify(diagnosticReport(null, h, d, true))).toContain('D:/secret/photo.ARW');
});
