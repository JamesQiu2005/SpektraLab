// Off-path adapters for upstream effects that still depend on Apple services.
// Mac build.sh globs pipeline/*.cpp, so the whole translation unit is guarded.
#ifndef __APPLE__
#include "pipeline.hpp"
#include "windows_unported.hpp"

namespace spk {

// The overscan node (overscan.cpp) is compiled on every backend since the light
// leak's kernel was ported (spk_leak_frame.comp): a leak with the film edge off
// renders. The film edge and the date imprint stay refused (windows_unported.hpp)
// until the imprints' text has a replacement for CoreText.

// The 场景 layers are compiled on every backend (scene_layers.cpp; spk_scene_layers.comp).

// The contrast mask is compiled on every backend (contrast_mask.cpp; spk_mask_*.comp).

}  // namespace spk
#endif  // !__APPLE__
