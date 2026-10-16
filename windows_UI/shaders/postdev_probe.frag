#version 440
#extension GL_GOOGLE_include_directive : enable
// spk_qt_postdev_gpu's fragment shader: one output texel per input texel,
// postdev() between them, the way the canvas will include it. Not part of the
// application; qsb baking it is also what proves postdev.glsl compiles for
// SPIR-V, HLSL 5.0, GLSL 300 es/330 and MSL 1.2.
#include "postdev.glsl"

layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    PostDev grade;   // offset 0, 160 bytes: postdev::std140()
    vec4 frame;      // offset 160: width, height
};
layout(binding = 1) uniform sampler2D frameTexture;
layout(binding = 2) uniform sampler2D curveTexture;

void main()
{
    ivec2 p = ivec2(gl_FragCoord.xy);
    // (gid + 0.5) / size, as Shaders.metal:340 and Grade::apply.
    vec2 uv = (vec2(p) + 0.5) / frame.xy;
    vec3 c = texelFetch(frameTexture, p, 0).rgb;
    fragColor = vec4(postdev(c, uv, grade, curveTexture), 1.0);
}
