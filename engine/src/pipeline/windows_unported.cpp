// Off-path adapters for upstream effects that still depend on Apple services.
// Mac build.sh globs pipeline/*.cpp, so the whole translation unit is guarded.
#ifndef __APPLE__
#include "pipeline.hpp"
#include "windows_unported.hpp"

namespace spk {

// overscan.cpp (the film edge and the date back) compiles everywhere now; its
// raster is overscan_raster_portable.cpp off Apple. Overscan itself stays
// refused by windows_unported.hpp until its canvas kernels are ported.

}  // namespace spk
#endif  // !__APPLE__
