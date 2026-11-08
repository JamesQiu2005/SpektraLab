// main.ts — the mock host on stdio, framed as HOST-PROTOCOL.md §1.
//
//   node mock-host/main.ts            (Node >= 22.18 strips the types itself)
//
// Spawned by the Tauri core when SPEKTRALAB_MOCK_HOST=1. Requests are handled
// in order, one at a time, like the real host's worker thread; `ping`,
// `cancel` and `shutdown` jump the queue as the protocol says.
//
// Env: MOCK_ALL_FEATURES=1 reports no unsupported features;
//      MOCK_RENDER_DELAY_MS=n slows renders down (to see the tiers);
//      MOCK_CRASH_AFTER=n exits after n requests (to test restarts).

import { FrameDecoder, encodeFrame } from '../src/shared/framing.ts';
import { MockHost, type MockRequest } from './core.ts';

const host = new MockHost({
  realisticUnsupported: process.env.MOCK_ALL_FEATURES !== '1',
  renderDelayMs: Number(process.env.MOCK_RENDER_DELAY_MS ?? 0),
  missing: (p) => p.includes('__missing__'),
});
const crashAfter = Number(process.env.MOCK_CRASH_AFTER ?? 0);
let handled = 0;

const decoder = new FrameDecoder();
const queue: MockRequest[] = [];
let busy = false;

function send(header: unknown, payload?: Uint8Array) {
  process.stdout.write(encodeFrame(header, payload));
}

async function drain() {
  if (busy) return;
  busy = true;
  while (queue.length) {
    const req = queue.shift()!;
    const reply = await host.handle(req);
    send(reply.header, reply.payload);
    handled++;
    if (req.method === 'shutdown') process.exit(0);
    if (crashAfter && handled >= crashAfter) {
      process.stderr.write(`mock host: crashing after ${handled} requests (MOCK_CRASH_AFTER)\n`);
      process.exit(3);
    }
  }
  busy = false;
}

process.stdin.on('data', (chunk: Buffer) => {
  for (const f of decoder.push(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.length))) {
    const req = f.header as MockRequest;
    if (req.method === 'ping' || req.method === 'cancel' || req.method === 'shutdown') {
      void host.handle(req).then((r) => {
        send(r.header, r.payload);
        if (req.method === 'shutdown') process.exit(0);
      });
    } else {
      queue.push(req);
      void drain();
    }
  }
});
process.stdin.on('end', () => process.exit(0));
process.stderr.write('mock host: ready (synthetic pictures, no engine)\n');
