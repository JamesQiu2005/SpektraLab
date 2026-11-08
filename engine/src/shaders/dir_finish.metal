// Preserve lincomb rounding before curve interpolation, without its temporary.
#include "spk_common.h"
kernel void spk_dir_finish(device const float* x [[buffer(0)]],
                       device const float* xa [[buffer(1)]],
                       device const float* inv [[buffer(2)]],
                       device const float* y [[buffer(3)]],
                       device const uint* meta [[buffer(4)]],
                       device float* out [[buffer(5)]],
                       device const float* corr [[buffer(6)]],
                       uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint K = meta[0], n = meta[1];
    if (i >= n) return;
    for (uint c = 0u; c < 3u; ++c) out[3u * i + c] = interp_channel(xa, inv, y, K, c, 1.0f * x[3u * i + c] + -1.0f * corr[3u * i + c]);
}
