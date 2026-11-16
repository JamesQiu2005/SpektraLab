# Windows baseline — 2026-11-15

Final local gates completed 2026-11-16 (America/Los_Angeles).

## Scope and checkout

- Worktree: E:/user/ChatGPT/SPEKTRAlab/.claude/worktrees/windows-baseline.
- Branch: codex/windows-baseline-20261115; parent 9fb90f3 (codex/windows-native).
- Upstream inspected: https://github.com/JamesQiu2005/SpektraLab; advertised HEAD 87de3b6c837f9e21ad67924c50b169b3bacbfc5e matched the local Mac 2.4.0 baseline. No configured remote, push or main merge.
- Owned input G:/photos/001/_DSC9136.NEF was copied to ignored build/vertical-input/source.NEF. Nikon Z 5, 6040×4032. Original untouched.

## Changes

- Vulkan FIR and IIR now implement accumulation mode 2 as weighted convolution with a zero starting sum, matching Metal and the shared Blur host. Previously the nonzero mode also added the dummy input image. This corrupted both DIR diffusion and halation.
- Existing pointwise GPU test covers both axes and modes 0/1/2, negative/channel-specific weights, and active/inactive IIR channels, including output guards. Before the fix it failed with `fir accumulation case=193 index=0 got=100.5 expected=0.5 delta=100 tolerance=0`.
- All Qt FrameCanvas surfaces apply the active display's ICC for legacy SDR. Windows advanced-color-managed displays keep the sRGB source for system handling. Missing/invalid profiles and failed transforms report their status and retain the image. Presentation does not modify the stored frame or export pixels.
- Added Windows Qt/MinGW CI build and five explicitly discovered CPU tests. Hosted CI does not claim Vulkan GPU acceptance. It has not run remotely.

## Evidence

All paths below are relative to this worktree unless another checkout is named.

| Gate | Result | Evidence |
| --- | --- | --- |
| Regression before fix | failed as expected | build-blur-regression-red.log |
| Release build and full registered CTest | 19/19, 0 skips, 10.09 s | build-blur-green-release.log |
| Debug build and full registered CTest | 19/19, 0 skips, 17.01 s | build-blur-green-debug.log |
| Deterministic DIR/halation public Python comparison | passed; 129,600 RGB values; max float error 8.838652921895097e-06, max 1 uint16 count, 0 count outliers | build/parity-default-blur-fixed/parity-report.json |
| Release owned NEF editing workflow | 217 checks passed | build/nikon-final-editing/report.json |
| Release owned NEF library workflow, serial | 147 checks passed | build/nikon-final-library/library-workflow.json |
| Owned NEF default render | decoded and RGB16 TIFF written | build/vertical-input/blur-fixed.json, blur-fixed.tiff |
| Before/after visual inspection | severe dark/red corruption removed with unchanged default film settings | build/vertical-input/blur-fix-comparison.png |
| Live monitor branch | display ICC read and reported in the running app | native Qt live inspection on the local Windows display |

The DIR/halation comparison uses the existing independent spektrafilm 0.3.4 fixture and reference from ../windows-port/build/parity-default-20261115, with unseeded grain and glare disabled. It previously failed at max error 0.8277110063785368. This is a 240×180 numerical fixture, not a matched Mac full-resolution reference.

## Limits and next work

- No physical monitor calibration, HDR/ACM-enabled monitor or second GPU was available. Preview remains 8-bit; ICC support does not establish HDR output.
- The native Save dialog was observed. The UI automation bridge could not reliably target its owned-window controls; do not describe this as a product failure or claim a completed manual Save interaction.
- Run GPU-heavy workflows serially on this laptop. An earlier concurrent library run reported VkResult -4; a later isolated 147-check run passed. This does not establish concurrent multi-process GPU reliability.
- This baseline does not implement the planned digital RAW exposure/white-balance controls, local-mask stack or real negative inversion. Film exposure changes negative density and must not be presented as a camera exposure control. Continue those as separate stages.
- Mac-matched parity, a larger numerical fixture and broader camera/GPU acceptance remain future gates.
