import { beforeEach, expect, it, vi } from 'vitest';
import { encodeFrame } from '@shared/framing';
import { tauriTransport } from './tauriTransport';

const ipc = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock('@tauri-apps/api/core', () => ({ invoke: ipc.invoke }));
vi.mock('@tauri-apps/api/event', () => ({ listen: vi.fn(async () => () => {}) }));
const bytes = (v: Uint8Array) => v.buffer.slice(v.byteOffset, v.byteOffset + v.byteLength);
beforeEach(() => { ipc.invoke.mockReset(); });

it('assembles a framed download across bounded native IPC reads and releases its token', async () => {
  const original = new Uint8Array([1,2,3,4,5,6,7,8]);
  ipc.invoke.mockImplementation(async (name: string, args: {offset?: number}) => {
    if (name === 'host_request') return bytes(encodeFrame({ok:true,result:{image:{width:2,height:1}},tauri_download:{id:'d1',bytes:original.length}}));
    if (name === 'binary_read') {
      const start = args.offset!;
      return bytes(original.subarray(start, Math.min(start+7, original.length)));
    }
    if (name === 'binary_drop') return;
    throw new Error(`unexpected IPC ${name}`);
  });
  const reply = await tauriTransport().request('render', {});
  expect([...reply.payload]).toEqual([1,2,3,4,5,6,7,8]);
  expect(reply.result.image).toEqual({width:2,height:1});
  expect(ipc.invoke).toHaveBeenCalledWith('binary_drop', {id:'d1'});
});

it('uploads a large image in bounded raw chunks, never one oversized WebView request', async () => {
  const payload = new Uint8Array(8*1024*1024+37);
  payload[payload.length-1] = 231;
  const uploaded: Uint8Array[] = [];
  ipc.invoke.mockImplementation(async (name: string, args: unknown) => {
    if (name === 'host_upload_open') return 'u1';
    if (name === 'host_upload_chunk') {
      const body = args as Uint8Array;
      expect(body.byteLength).toBeLessThanOrEqual(8*1024*1024+128);
      uploaded.push(body);
      return;
    }
    if (name === 'host_upload_finish') return bytes(encodeFrame({ok:true,result:{path:'file.tif'}}));
    if (name === 'binary_drop') return;
    throw new Error(`unexpected or unbounded IPC ${name}`);
  });
  const reply = await tauriTransport().request('write_image', {width:100}, {payload});
  expect(reply.result.path).toBe('file.tif');
  expect(uploaded).toHaveLength(2);
  expect(uploaded.at(-1)!.at(-1)).toBe(231);
  expect(ipc.invoke).toHaveBeenCalledWith('binary_drop', {id:'u1'});
});

it('cleans up a partial download when the bridge stops making progress', async () => {
  ipc.invoke.mockImplementation(async (name: string) => {
    if (name === 'host_request') return bytes(encodeFrame({ok:true,tauri_download:{id:'broken',bytes:12}}));
    if (name === 'binary_read') return new ArrayBuffer(0);
    if (name === 'binary_drop') return;
  });
  await expect(tauriTransport().request('render', {})).rejects.toThrow(/progress|empty|truncated/i);
  expect(ipc.invoke).toHaveBeenCalledWith('binary_drop', {id:'broken'});
});
