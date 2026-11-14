# Camera exposure reference on Windows

The single-photo RAW **As Shot** checkbox matches the overall brightness of
the camera's embedded preview before applying film. Previously it disabled
automatic metering and set both exposure terms to zero. LibRaw's linear RAW
decode has no automatic brightening or camera display tone curve, so this
could place the scene deep in the film's shadows.

The preview and `render_source` are requested at a 720-pixel long edge in
sRGB, independent of film, Layer 2 adjustments and the monitor's display
space. The frontend decodes sRGB luminance and fits one exposure scalar to
the middle 20–80% quantiles. Clipped whites and very deep shadows are excluded.
This approximates overall camera brightness; it does not copy a camera look,
preserve every tone, or calibrate a camera. Film contrast still changes the
final result. No RAW pixel policy or measured material profile is altered.

The correction uses `exposure_baseline_ev`, before scene placement and film.
The post-scene compensation is zero. Re-selecting an automatic meter retains
its existing behavior. The Camera menu's **Linear source · zero compensation**
action remains available for the former zero-gain behavior.

The optional sidecar field `cameraExposureReference: {ev, decodeKey}` stores
this photograph's derived reference. It is not copied with settings, sent to
the engine, or needed to reproduce an export: the actual exposure already
resides in the existing saved exposure parameters. The checkbox requires a
matching decode key, so changing white balance does not claim the old match is
still current. Undo/redo restores the exposure edit normally. Old sidecars
are not automatically remetered or brightened.

The exposure menu distinguishes **As Shot**, **Linear source**, the automatic
meters and **Custom**. The per-photo `cameraExposurePreset` field records the
explicit choice. A manual exposure edit clears the preset even if its numeric
value coincides with the camera reference. Undo, redo and sidecar reload carry
this choice. Older camera-reference sidecars without this field are recognized
from their matching reference. New photos still start with Balanced; reopening
an edited photograph restores its saved exposure instead of applying a default.

Missing previews, aspect ratio differences greater than approximately 2.5%,
insufficient unclipped samples, inconsistent estimates or corrections outside
±6 EV leave the existing exposure untouched and show an error. A late result
is discarded after changing the photograph, decode, exposure, film, geometry
or adjustments. Explicit exposure reset also cancels an unchanged pending
request. No fallback silently resets an unsupported RAW to zero.

Rendered files retain zero-gain As Shot behavior. Half-frame pairs retain
their existing per-hole zero-gain operation, explicitly labeled **Linear
baseline**; estimating individual camera references for paired sources is
outside this patch.

Validation uses synthetic linear-light controls, session save/reload and
undo/redo checks, stale-request cases, the exposure widget browser regression,
and the released beta.3 Vulkan host with Sony ILCE-7CM2 ARW, Canon EOS R6 Mark
III CR3 and Fujifilm X-E5 RAF. These samples do not establish all-camera support.
