// SPDX-License-Identifier: GPL-3.0-or-later
// Develop Camera: the JNI bridge to Develop's engine (spk_engine.h), and the RAW path.
//
// One engine, used from one thread (DevelopEngine's dispatcher). Two ways in:
//  - nativeDevelopBitmap: an ARGB_8888 bitmap of sRGB-encoded scene light (the camera's JPEG, or frames composed
//    from it) -> the engine with input sRGB.
//  - nativeDevelopRaw: the sensor's Bayer data as Camera2 delivered it, with Camera2's own per-frame corrections
//    (black/white levels, lens shading map, as-shot neutral, forward matrix, lens distortion), demosaiced
//    (Malvar-He-Cutler), to linear ProPhoto RGB -> the engine with input linear ProPhoto (Develop's RAW input).
//    LibRaw is not used: it applies a DNG's shading and distortion opcodes only through the Adobe DNG SDK.
// Both return a new ARGB_8888 bitmap of the developed picture, whatever size the engine made (a film edge makes
// it larger). Errors are thrown as RuntimeException.
#include <android/bitmap.h>
#include <jni.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include "raw_develop.hpp"
#include "spektralab/spk_engine.h"

namespace {

std::string text(JNIEnv* env, jstring s) {
    const char* c = env->GetStringUTFChars(s, nullptr);
    std::string out(c ? c : "");
    if (c) env->ReleaseStringUTFChars(s, c);
    return out;
}

void raise(JNIEnv* env, const std::string& message) {
    env->ThrowNew(env->FindClass("java/lang/RuntimeException"), message.c_str());
}

jobject new_bitmap(JNIEnv* env, int w, int h) {
    jclass bitmap = env->FindClass("android/graphics/Bitmap");
    jclass config = env->FindClass("android/graphics/Bitmap$Config");
    jmethodID create = env->GetStaticMethodID(bitmap, "createBitmap",
                                              "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;");
    jfieldID argb = env->GetStaticFieldID(config, "ARGB_8888", "Landroid/graphics/Bitmap$Config;");
    return env->CallStaticObjectMethod(bitmap, create, w, h, env->GetStaticObjectField(config, argb));
}

// Runs the engine on a 3-channel float image and returns the result as a new bitmap (null + exception on error).
jobject develop(JNIEnv* env, spk_engine* engine, const float* px, uint32_t w, uint32_t h, const std::string& params) {
    const spk_image image{px, w, h, 3};
    char* reply = nullptr;
    spk_session* session = spk_open(engine, &image, params.c_str(), &reply);
    if (!session) { raise(env, std::string("open: ") + spk_last_error(engine)); return nullptr; }
    spk_string_free(reply);
    spk_result r{};
    if (spk_render(session, "full", &r) != SPK_OK) {
        const std::string e = std::string("render: ") + spk_last_error(engine);
        spk_session_release(session);
        raise(env, e);
        return nullptr;
    }
    jobject out = new_bitmap(env, int(r.width), int(r.height));
    void* p = nullptr;
    AndroidBitmapInfo oi{};
    if (!out || AndroidBitmap_getInfo(env, out, &oi) != ANDROID_BITMAP_RESULT_SUCCESS ||
        AndroidBitmap_lockPixels(env, out, &p) != ANDROID_BITMAP_RESULT_SUCCESS) {
        spk_result_free(&r);
        spk_session_release(session);
        if (!env->ExceptionCheck()) raise(env, "no memory for the developed picture");
        return nullptr;
    }
    for (uint32_t y = 0; y < r.height; ++y) {
        uint8_t* row = static_cast<uint8_t*>(p) + size_t(y) * oi.stride;
        const uint16_t* src = r.rgba16 + size_t(y) * r.row_stride_px * 4;
        for (uint32_t x = 0; x < r.width; ++x) {
            row[4 * x] = uint8_t((src[4 * x] + 128u) / 257u);
            row[4 * x + 1] = uint8_t((src[4 * x + 1] + 128u) / 257u);
            row[4 * x + 2] = uint8_t((src[4 * x + 2] + 128u) / 257u);
            row[4 * x + 3] = 255;
        }
    }
    AndroidBitmap_unlockPixels(env, out);
    spk_result_free(&r);
    spk_session_release(session);
    return out;
}

std::vector<float> floats(JNIEnv* env, jfloatArray a) {
    std::vector<float> v(a ? size_t(env->GetArrayLength(a)) : 0);
    if (!v.empty()) env->GetFloatArrayRegion(a, 0, jsize(v.size()), v.data());
    return v;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_jegly_developcamera_engine_DevelopEngine_nativeCreate(JNIEnv* env, jobject, jstring resources) {
    return reinterpret_cast<jlong>(spk_engine_create(text(env, resources).c_str(), nullptr));
}

JNIEXPORT void JNICALL
Java_com_jegly_developcamera_engine_DevelopEngine_nativeDestroy(JNIEnv*, jobject, jlong engine) {
    spk_engine_destroy(reinterpret_cast<spk_engine*>(engine));
}

JNIEXPORT jstring JNICALL
Java_com_jegly_developcamera_engine_DevelopEngine_nativeCapabilities(JNIEnv* env, jobject, jlong engine) {
    return env->NewStringUTF(spk_capabilities(reinterpret_cast<spk_engine*>(engine)));
}

JNIEXPORT jobject JNICALL
Java_com_jegly_developcamera_engine_DevelopEngine_nativeDevelopBitmap(JNIEnv* env, jobject, jlong handle, jobject in,
                                                                       jstring params) {
    AndroidBitmapInfo ii{};
    if (AndroidBitmap_getInfo(env, in, &ii) != ANDROID_BITMAP_RESULT_SUCCESS || ii.format != ANDROID_BITMAP_FORMAT_RGBA_8888) {
        raise(env, "the input must be an ARGB_8888 bitmap");
        return nullptr;
    }
    std::vector<float> px(size_t(ii.width) * ii.height * 3);
    void* p = nullptr;
    if (AndroidBitmap_lockPixels(env, in, &p) != ANDROID_BITMAP_RESULT_SUCCESS) { raise(env, "lock input"); return nullptr; }
    for (uint32_t y = 0; y < ii.height; ++y) {
        const uint8_t* row = static_cast<const uint8_t*>(p) + size_t(y) * ii.stride;
        float* dst = &px[size_t(y) * ii.width * 3];
        for (uint32_t x = 0; x < ii.width; ++x) {
            dst[3 * x] = row[4 * x] / 255.0f;
            dst[3 * x + 1] = row[4 * x + 1] / 255.0f;
            dst[3 * x + 2] = row[4 * x + 2] / 255.0f;
        }
    }
    AndroidBitmap_unlockPixels(env, in);
    return develop(env, reinterpret_cast<spk_engine*>(handle), px.data(), ii.width, ii.height, text(env, params));
}

// raw: direct buffer of uint16 Bayer samples, rowStride bytes per row. black: 4 levels in 2x2 position order
// (row * 2 + column). neutral: as-shot camera neutral (3). forward: camera (white balanced) -> XYZ D50, row-major.
// shading: gw x gh x 4 gains (Camera2 LensShadingMap order R, G even row, G odd row, B), or empty.
// distortion: k1 k2 k3 p1 p2 (Camera2 LENS_DISTORTION), intrinsics: fx fy cx cy s, either may be empty.
// cropAspect: the frame's long/short side along the sensor's long side. maxPixels: the output's limit.
// gain, previewMedian: the app's film meter (raw_develop.hpp RawInput); without a reading the median goes to mid grey.
JNIEXPORT jobject JNICALL
Java_com_jegly_developcamera_engine_DevelopEngine_nativeDevelopRaw(
    JNIEnv* env, jobject, jlong handle, jobject raw, jint w, jint h, jint rowStride, jint cfa, jfloatArray jblack,
    jfloat white, jfloatArray jneutral, jfloatArray jforward, jfloatArray jshading, jint gw, jint gh,
    jfloatArray jdistortion, jfloatArray jintrinsics, jfloat cropAspect, jint maxPixels, jfloat gain,
    jfloat previewMedian, jstring params) {
    RawInput in;
    in.base = static_cast<const uint8_t*>(env->GetDirectBufferAddress(raw));
    in.w = w; in.h = h; in.rowStride = rowStride; in.cfa = cfa;
    in.black = floats(env, jblack); in.white = white; in.neutral = floats(env, jneutral); in.fwd = floats(env, jforward);
    in.shading = floats(env, jshading); in.gw = gw; in.gh = gh;
    in.dist = floats(env, jdistortion); in.intr = floats(env, jintrinsics);
    in.cropAspect = cropAspect; in.maxPixels = maxPixels; in.gain = gain; in.previewMedian = previewMedian;
    if (!(gain > 0 && previewMedian > 0)) in.targetMedian = 0.18f;   // no meter reading: median to mid grey
    int ow = 0, oh = 0;
    std::string error;
    std::vector<float> outpx = raw_to_prophoto(in, ow, oh, error);
    if (outpx.empty()) { raise(env, error); return nullptr; }
    return develop(env, reinterpret_cast<spk_engine*>(handle), outpx.data(), uint32_t(ow), uint32_t(oh), text(env, params));
}

// The same RAW frame, metered and straightened, as an sRGB picture (no film): the quick version's input and
// the frames of multi-shot formats. cropAspect 0 keeps the whole sensor.
JNIEXPORT jobject JNICALL
Java_com_jegly_developcamera_engine_DevelopEngine_nativeRawToBitmap(
    JNIEnv* env, jobject, jobject raw, jint w, jint h, jint rowStride, jint cfa, jfloatArray jblack, jfloat white,
    jfloatArray jneutral, jfloatArray jforward, jfloatArray jshading, jint gw, jint gh, jfloatArray jdistortion,
    jfloatArray jintrinsics, jfloat cropAspect, jint maxPixels, jfloat gain, jfloat previewMedian) {
    RawInput in;
    in.base = static_cast<const uint8_t*>(env->GetDirectBufferAddress(raw));
    in.w = w; in.h = h; in.rowStride = rowStride; in.cfa = cfa;
    in.black = floats(env, jblack); in.white = white; in.neutral = floats(env, jneutral); in.fwd = floats(env, jforward);
    in.shading = floats(env, jshading); in.gw = gw; in.gh = gh;
    in.dist = floats(env, jdistortion); in.intr = floats(env, jintrinsics);
    in.cropAspect = cropAspect; in.maxPixels = maxPixels; in.gain = gain; in.previewMedian = previewMedian;
    if (!(gain > 0 && previewMedian > 0)) in.targetMedian = 0.18f;
    int ow = 0, oh = 0;
    std::string error;
    std::vector<float> px = raw_to_prophoto(in, ow, oh, error);
    if (px.empty()) { raise(env, error); return nullptr; }
    jobject out = new_bitmap(env, ow, oh);
    void* p = nullptr;
    AndroidBitmapInfo oi{};
    if (!out || AndroidBitmap_getInfo(env, out, &oi) != ANDROID_BITMAP_RESULT_SUCCESS ||
        AndroidBitmap_lockPixels(env, out, &p) != ANDROID_BITMAP_RESULT_SUCCESS) {
        if (!env->ExceptionCheck()) raise(env, "no memory for the picture");
        return nullptr;
    }
    prophoto_to_srgb8(px.data(), ow, oh, static_cast<uint8_t*>(p), int(oi.stride));
    AndroidBitmap_unlockPixels(env, out);
    return out;
}

}  // extern "C"
