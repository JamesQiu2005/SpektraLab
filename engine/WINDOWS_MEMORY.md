# Windows memory residency follow-up (2026-10-18)

This change keeps the film model, float32 processing, default effects, RAW
algorithm/thread budget and output formats. It does not introduce overlapping
RAW decoding, GPU renders or encoders. The public C ABI is unchanged.

## Allocation lifetimes

- Compatible16 decoding destroys LibRaw after validating its independently
  owned RGB16 output and capturing metadata, before allocating float RGB.
  The headroom conversion still needs the LibRaw image and is unchanged.
- Vulkan upload/readback use at most 64 MiB per staging buffer (128 MiB total),
  transferring larger images in synchronous chunks. Narrowing double input to
  float also happens by chunk, without a second full float vector. Memory
  dependencies and noncoherent flush/invalidate remain explicit.
- The worker trims unused GPU scratch and staging before decoding another
  source, after five seconds of inactivity, and under Windows memory pressure
  (available physical memory below max(512 MiB, 10% total), or available commit
  below 512 MiB). Diagnostic polling does not reset the inactivity timer.
  Closing the last engine session also trims unused memory immediately.
  Live source, negative and print buffers are never trimmed.
- Complete-frame TIFF8/TIFF16 export writes its unchanged uncompressed layout
  directly from the readback in <=1 MiB chunks through the existing atomic
  writer. It does not allocate a second whole-file byte vector. Legacy memory
  encoding interfaces remain available.
- Before a private batch source is decoded, existing editors' unique source,
  tier, negative and print planes are saved as exact bytes to a session-owned
  temporary file. Full-tier/source aliases are deduplicated. GPU references
  are dropped only after all writes succeed. An 8 MiB CPU chunk bounds the
  transfer workspace; the pipeline, parameters and random state remain alive.
  The next pixel-consuming editor operation restores lazily; metadata/progress
  queries do not restore pixels or postpone idle trimming. Re-decoding also
  keeps the old snapshot on disk until its replacement is ready. Partial restore failure discards
  partial GPU allocations and keeps the disk snapshot for retry. Closing a
  suspended editor removes the file without restoring it. Windows uses an
  exclusive Unicode-path file with delete-on-close lifetime.

The disk snapshot costs I/O and potentially reclaimable OS file cache; it is
not free memory. `memory_report.suspended_bytes` and per-session residency
fields report it separately from GPU `total_bytes`. The GPU pool ledger still
excludes staging. `SPEKTRAFILM_TRANSFER_TIMINGS=1` records staging allocations
and trims; leave it off for timing. Diagnostic
`SPEKTRAFILM_VULKAN_STAGING_BYTES` accepts a 4-byte-aligned value from 4 through
67108864 and cannot raise the production limit. Invalid values fail clearly.
`SPK_TEST_RESIDENCY_FAILURE=write/read` is only a fault-injection test hook.

## Measured memory

Local RTX 5070 Ti, 4688x7028 Sony ARW (32,947,264 pixels), 2560 preview, default
Portra 400 / Portra Endura effects. Baseline is preserved build
`build-widegamut-20261012`, commit `9c03b68`; candidate is the independent
`build-memory-20261017`. Evidence is under the workspace's
`validation/memory-optimization-20261017` and previous
`validation/memory-profile-20261017` directories. The directory date records
the experiment start; this follow-up completed on October 18.

| Compatible16 measurement | Before | After |
| --- | ---: | ---: |
| Standalone RAW decoder peak process commit | 935.46 MB | 596.83 MB |
| Host RAW open peak process commit | 1.303 GB | 0.974 GB |
| Full-source preview peak process commit | 4.792 GB | 4.463 GB |
| TIFF16 export peak process commit | 5.502 GB | 4.711 GB |
| Private batch with an editor, peak process commit | 5.877 GB | 4.441 GB |
| Last session closed, retained process commit | 4.023 GB | 0.519 GB |
| Last session closed, unused device pool | 3.030 GB | 0 |
| Maximum upload + readback staging | 593.05 MB | 134.22 MB |

Headroom shows the same staging, pool and TIFF savings. Its standalone RAW
peak remains 737.3 MB because that decode path still consumes the LibRaw
buffer. Its private-batch peak changes from 5.964 to 4.435 GB. The editor in
that batch test holds a 1.054 GB disk snapshot; the remaining device state is
about 1 MB. No 80 MP IIQ sample was available: these results are not a
reproduction or a guarantee for that format/camera.

MB/GB above are decimal. Process commit includes driver-backed commitments;
it is not physical RAM. GPU buffer ledger, process commit, working set and
board-wide GPU usage must not be added together. Sampling was 10 ms for the
process and 100 ms for board-wide GPU usage, so very short peaks may be missed.
Memory-workflow transfer diagnostics were enabled; its timings are not used
as the speed benchmark. WebView/frontend memory is outside this measurement.

## Speed tradeoffs

A separate diagnostic-free run alternated three independent processes of
each build. Each kept default effects and the same input/snapshots, rendered
the full print first, then recorded one initial and five hot exports per
format. Complete calls include pixel readback, encoding, file closure and
atomic rename; they do not force OS disk-cache flush to physical media and do
not measure the WebView. `timing.json` and `timing-summary.json` retain all
stage timings, samples and ranges.

| Complete host call | Before median | After median (range) |
| --- | ---: | ---: |
| RAW + source open, first/process | 1942 ms | 2005 ms (1803–2138) |
| First full-source 2560 view | 1078 ms | 1103 ms (1014–1155) |
| JPEG Q92 hot export | 177 ms | 163 ms (157–289) |
| PNG hot export | 1835 ms | 1961 ms (1754–2167) |
| TIFF16 hot export | 228 ms | 98 ms (92–116) |
| First private batch with editor | 2117 ms | 2691 ms (2627–2793) |
| Returning to the suspended editor | 8 ms | 324 ms (300–336) |

TIFF improves by 57%. PNG's hot median is 6.8% slower in this run, with
overlapping ranges; this change does not claim universal speed improvement.
The memory reduction is the purpose of chunked transfer and residency.
The approximately 0.57 s first-batch cost saves the editor's exact cache once;
subsequent private exports reuse that file. Restoring costs about 0.32 s when
editing resumes. The 20-export integration test checks that the snapshot is
not rewritten between batch frames. No parallel batch pipeline was enabled.

## Regression coverage

`spk_vulkan_transfer` covers chunk boundaries, offset reads, unaligned host
destinations, invalid ranges, double-to-float upload, clear/copy and trimming
while live buffers remain valid. `spk_vulkan_view` covers exact random cached
pixels across suspension, alias accounting, RNG continuation, mid-write and
partial-read failure rollback, missing temporary directory and file cleanup.
`spk_host_codecs` checks independently parsed TIFF pixels/metadata, 8/16-bit,
odd dimensions, multiple strips and atomic write failure. The preserved old
TIFF encoder also matched the new memory/file encoders in 12 complete-file
byte comparisons using the same ICC input.

`python engine/tests/host_memory.py --host <host> --resources <engine>` runs
the real framed protocol with owned synthetic images: idle trim while polling,
20 private exports, cache-file reuse despite metadata/progress polling,
exact restore without the source file, failed redecode while suspended,
queued/running cancellation, output failure/protection and close cleanup.

The standalone production RAW decoder was compared with the old source:
both compatible16 and headroom full float RGB hashes are identical. Missing
input and unsupported Nikon HE still return errors. External Metal/reference
parity, Intel integrated GPUs and the reported IIQ file remain untested here.

All 25 CTest checks pass in the configured MinGW toolchain environment. The
full-size deterministic host comparison also has exact RGBA16 (263,578,112
bytes), PNG and JPEG results, and exact TIFF8/TIFF16 files after masking only
the generated ICC creation-date bytes. It disables random stages solely for
cross-build pixel comparison; the timing and same-session residency tests
keep default random effects. This is regression against the preserved Windows
build, not a substitute for the external Metal/Python color oracle.

The final staged host also passed the existing full-RAW regression adapted to
the new disk-residency ledger, including Chinese paths, all three file formats,
decode snapshots, cancellation, overwrite protection and 20 private ARW
exports. Process commit over the last ten iterations stayed between 3.426 and
3.430 GB; no retained-session or GPU-accounting growth was observed. Final
host/resource hashes and test records are in `manifest.json`. The unchanged
frontend was reused for the local `app/spektralab.exe` test directory; this run
did not repeat a native-window interaction test. No Git commit or portable ZIP
was created.
