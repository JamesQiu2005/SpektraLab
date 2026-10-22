// Encoded ProPhoto Layer 2, ported from Canvas/Shaders.metal. Input and
// output have the same UNORM16 boundaries as Mac's offscreen textures.
layout(local_size_x=256) in;
layout(binding=0,std430) readonly buffer Input { uint v[]; } src;
layout(binding=1,std430) readonly buffer Uniforms { float v[]; } u;
layout(binding=2,std430) readonly buffer Curves { float v[]; } curves;
layout(binding=3,std430) readonly buffer Meta { uint v[]; } m;
layout(binding=4,std430) writeonly buffer Output { float v[]; } dst;
uint index1D() { return gl_GlobalInvocationID.y*(gl_NumWorkGroups.x*gl_WorkGroupSize.x)+gl_GlobalInvocationID.x; }
#ifdef SPK_DI_VIEW
layout(binding=5,std430) readonly buffer Table { float value[]; } lut;
float sample_table(uvec3 p,uint channel) { return lut.value[((p.z*m.v[3]+p.y)*m.v[3]+p.x)*3u+channel]; }
vec3 di_view(vec3 codes) {
    uint n=m.v[3];
    precise vec3 p=codes*float(n-1u);
    uvec3 lo=uvec3(floor(p)),hi=min(lo+uvec3(1),uvec3(n-1u));
    precise vec3 f=p-vec3(lo),v;
    for(uint c=0u;c<3u;++c) {
        precise float z00=sample_table(lo,c)*(1.0-f.x)+sample_table(uvec3(hi.x,lo.y,lo.z),c)*f.x;
        precise float z01=sample_table(uvec3(lo.x,hi.y,lo.z),c)*(1.0-f.x)+sample_table(uvec3(hi.x,hi.y,lo.z),c)*f.x;
        precise float z10=sample_table(uvec3(lo.x,lo.y,hi.z),c)*(1.0-f.x)+sample_table(uvec3(hi.x,lo.y,hi.z),c)*f.x;
        precise float z11=sample_table(uvec3(lo.x,hi.y,hi.z),c)*(1.0-f.x)+sample_table(hi,c)*f.x;
        v[c]=(z00*(1.0-f.y)+z01*f.y)*(1.0-f.z)+(z10*(1.0-f.y)+z11*f.y)*f.z;
    }
    return v;
}
#endif
float luma(vec3 c) { return dot(c,vec3(0.2126,0.7152,0.0722)); }
float tone(float v) { return v<=u.v[12] ? 0.5*v/u.v[12] : 0.5+0.5*(v-u.v[12])/(1.0-u.v[12]); }
float curve(float v,uint row) {
    float x=clamp(v,0.0,1.0)*255.0; uint i=uint(floor(x));
    return mix(curves.v[row*256u+i],curves.v[row*256u+min(i+1u,255u)],fract(x));
}
vec3 triple(uint i) { return vec3(u.v[i],u.v[i+1u],u.v[i+2u]); }
void main() {
    uint i=index1D(); if(i>=m.v[0]) return;
    uint rg=src.v[2u*i],ba=src.v[2u*i+1u];
    vec3 c=vec3(rg&65535u,rg>>16u,ba&65535u)/65535.0;
#ifdef SPK_DI_VIEW
    c=di_view(c);
#endif
    if(u.v[0]!=0.0) {
        c*=triple(1u);
        if(u.v[4]!=1.0) c=pow(pow(max(c,vec3(0)),vec3(2.2))*u.v[4],vec3(1.0/2.2));
        if(u.v[5]!=0.0) c=(c-u.v[12])*(1.0+u.v[5]*1.2)+u.v[12];
        if(u.v[6]!=0.0) c=pow(max(c,vec3(0)),vec3(1.0/(1.0+u.v[6]*0.8)));
        float l=tone(luma(c));
        if(u.v[9]!=0.0) c+=u.v[9]*0.25*(1.0-l)*(1.0-l)*(1.0-c);
        if(u.v[8]!=0.0) c+=u.v[8]*0.25*l*l*(u.v[8]>0.0?1.0-c:c);
        c=(c-u.v[10])/max(1.0-u.v[10]-u.v[11],0.05);
        l=luma(c); c=l+(c-l)*u.v[7];
        float ls=clamp(tone(l),0.0,1.0),ws=(1.0-ls)*(1.0-ls),wh=ls*ls,wm=max(1.0-ws-wh,0.0);
        c+=triple(16u)+triple(19u)*ws+triple(22u)*wm+triple(25u)*wh;
        c*=1.0+u.v[28]+u.v[29]*ws+u.v[30]*wm+u.v[31]*wh;
        if(u.v[15]!=0.0) {
            c=clamp(c,0.0,1.0); float ly=luma(c),ly2=curve(ly,1u);
            c*=ly>1e-4?ly2/ly:1.0; c=clamp(c,0.0,1.0);
            c=vec3(curve(c.r,0u),curve(c.g,0u),curve(c.b,0u));
            c=vec3(curve(c.r,2u),curve(c.g,3u),curve(c.b,4u));
        }
        if(u.v[13]!=0.0) {
            vec2 uv=(vec2(i%m.v[1],i/m.v[1])+0.5)/vec2(m.v[1],m.v[2]);
            float fall=smoothstep(u.v[14]*1.2,1.5,length((uv-0.5)*2.0));
            c*=1.0+u.v[13]*fall*0.9;
        }
    }
    c=floor(clamp(c,0.0,1.0)*65535.0+0.5)/65535.0;
    dst.v[3u*i]=c.r; dst.v[3u*i+1u]=c.g; dst.v[3u*i+2u]=c.b;
}
