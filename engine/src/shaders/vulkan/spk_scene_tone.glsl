// The half of scene_latitude.metal's scene tone both kernels share: a pixel's
// brightness on the stop axis. Both kernels bind the frame and the parameter
// block first; each declares its own buffers from binding 2 on.
//
// `p` is scene_latitude.metal's scene-tone block:
//   0..2 the working space's Y row   3 mid-grey   4 highlight stops
//   5 shadow stops   6 the ramp, stops   7 the floor, stops (negative)
#ifndef SPK_SCENE_TONE_GLSL
#define SPK_SCENE_TONE_GLSL

layout(set = 0, binding = 0, std430) readonly buffer Input { float value[]; } input_data;
layout(set = 0, binding = 1, std430) readonly buffer Parameters { float value[]; } p;

// vulkan_gpu.cpp folds a dispatch past maxComputeWorkGroupCount[0] (65535 on
// lavapipe and Intel) into rows of workgroups; this is the 1D index it means.
uint spk_global_index() {
    return gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * gl_WorkGroupSize.x) + gl_GlobalInvocationID.x;
}

// log2(Y / mid-grey), Y from max(RGB, 0), held to [floor, -floor]. A Y that
// is zero, negative or NaN lands on the floor: Metal's max drops the NaN, and
// GLSL's may not, so the comparisons are explicit.
float tone_x(uint i) {
    float y = 0.0;
    for (uint c = 0u; c < 3u; ++c) {
        float v = input_data.value[3u * i + c];
        if (v > 0.0) y += p.value[c] * v;
    }
    float floor_stops = p.value[7];
    float x = floor_stops;
    if (y > 0.0) {
        x = log2(y / p.value[3]);
        if (!(x > floor_stops)) x = floor_stops;
        if (x > -floor_stops) x = -floor_stops;
    }
    return x;
}

#endif
