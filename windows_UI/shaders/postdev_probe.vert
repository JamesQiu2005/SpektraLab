#version 440
// spk_qt_postdev_gpu's vertex shader: one triangle that covers the viewport,
// no vertex buffer.
void main()
{
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
