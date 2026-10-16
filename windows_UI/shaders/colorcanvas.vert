#version 440
// One tile of a FrameCanvas picture. The position is the tile's rectangle in
// item coordinates; the texture coordinate addresses the tile's own texture,
// inside the one-texel apron that tiling adds (ColorCanvasNode.cpp).
layout(location = 0) in vec4 qt_VertexPosition;
layout(location = 1) in vec2 qt_VertexTexCoord;
layout(location = 0) out vec2 vTexCoord;

// Same block as colorcanvas.frag; offsets are written by CanvasShader.
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float lutSize;
    float ditherAmplitude;
    float curveSize;
};

void main()
{
    vTexCoord = qt_VertexTexCoord;
    gl_Position = qt_Matrix * qt_VertexPosition;
}
