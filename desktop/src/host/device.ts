// device.ts — what the engine's `hello.backend.device_name` says about the
// GPU: a Vulkan device can be a CPU in disguise (Mesa's lavapipe reports
// "llvmpipe", Google's SwiftShader its own name, Windows' WARP fallback
// "Microsoft Basic Render Driver"). The interface renders every interactive
// edit at the preview edge, and on such a device a 2560 px live tier takes
// seconds per drag (NOTES.md, "Performance on real GPUs").

const SOFTWARE_DEVICE = [/llvmpipe/i, /lavapipe/i, /swiftshader/i, /microsoft basic render/i, /\bwarp\b/i, /software/i];

/** True when the device name is a known software rasterizer. Unknown or
 * empty names are taken as hardware: the engine's own tiers apply. */
export function isSoftwareDevice(name: string | null | undefined): boolean {
  return !!name && SOFTWARE_DEVICE.some((re) => re.test(name));
}
