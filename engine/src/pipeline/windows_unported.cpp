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

// RFC-052 §6.4: the 场景 layers' kernel is Metal only. `windows_unported_error`
// refuses a stamp at build; this is the node's own backstop.
bool Pipeline::node_scene_layers(const Image&, Image&, std::string& error) {
    error = "scene layers are not implemented by the Windows Vulkan backend yet";
    return false;
}

// The contrast mask is compiled on every backend (contrast_mask.cpp; spk_mask_*.comp).

}  // namespace spk
#endif  // !__APPLE__
