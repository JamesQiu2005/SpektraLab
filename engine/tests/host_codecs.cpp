// CPU-only codec regression: one source buffer, independent stb decode, and
// JPEG header checks. A different file hash is not a quality regression.
#include "output.hpp"
#include "platform.hpp"
#include "image_io.hpp"
#include "tiff_ifd.hpp"
#include "stb_image.h"
#include "stb_image_write.h"
#include <jpeglib.h>
#include <zlib.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <stdexcept>
#include <vector>

static void require(bool yes, const char* message) { if (!yes) throw std::runtime_error(message); }
static void stb_sink(void* p, void* d, int n) {
    auto& out = *static_cast<std::vector<uint8_t>*>(p);
    out.insert(out.end(), static_cast<uint8_t*>(d), static_cast<uint8_t*>(d) + n);
}
static std::vector<uint8_t> decode(const std::vector<uint8_t>& bytes, int w, int h) {
    int dw, dh, n;
    auto* p = stbi_load_from_memory(bytes.data(), int(bytes.size()), &dw, &dh, &n, 3);
    require(p && dw == w && dh == h, "image decode/dimensions");
    std::vector<uint8_t> out(p, p + size_t(w) * h * 3); stbi_image_free(p); return out;
}
static double psnr(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
    double mse = 0;
    for (size_t i = 0; i < a.size(); ++i) { const double d = double(a[i]) - b[i]; mse += d * d; }
    return mse ? 10 * std::log10(255.0 * 255 * a.size() / mse) : 100;
}
static std::vector<uint8_t> decode_jpeg(const std::vector<uint8_t>& bytes) {
    jpeg_decompress_struct c{}; jpeg_error_mgr e{}; c.err = jpeg_std_error(&e);
    jpeg_create_decompress(&c); jpeg_mem_src(&c, bytes.data(), bytes.size());
    jpeg_read_header(&c, TRUE); c.out_color_space = JCS_RGB; c.dct_method = JDCT_ISLOW;
    jpeg_start_decompress(&c); std::vector<uint8_t> out(size_t(c.output_width) * c.output_height * 3);
    while (c.output_scanline < c.output_height) {
        JSAMPROW row = out.data() + size_t(c.output_scanline) * c.output_width * 3;
        jpeg_read_scanlines(&c, &row, 1);
    }
    jpeg_finish_decompress(&c); jpeg_destroy_decompress(&c); return out;
}
// Per-channel luminance/contrast/structure over non-overlapping 8x8 windows.
static double ssim(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b, int w, int h) {
    double total = 0; size_t count = 0;
    for (int y = 0; y + 8 <= h; y += 8) for (int x = 0; x + 8 <= w; x += 8) for (int c = 0; c < 3; ++c) {
        double ma = 0, mb = 0, aa = 0, bb = 0, ab = 0;
        for (int yy = 0; yy < 8; ++yy) for (int xx = 0; xx < 8; ++xx) {
            const size_t i = (size_t(y + yy) * w + x + xx) * 3 + c;
            const double av = a[i], bv = b[i]; ma += av; mb += bv; aa += av * av; bb += bv * bv; ab += av * bv;
        }
        ma /= 64; mb /= 64; aa = aa / 64 - ma * ma; bb = bb / 64 - mb * mb; ab = ab / 64 - ma * mb;
        total += ((2 * ma * mb + 6.5025) * (2 * ab + 58.5225)) /
                 ((ma * ma + mb * mb + 6.5025) * (aa + bb + 58.5225)); ++count;
    }
    return total / count;
}
struct Header { std::array<unsigned, 128> quant{}; int sample_h, sample_v; std::vector<uint8_t> icc, exif; };
static Header header(const std::vector<uint8_t>& bytes) {
    jpeg_decompress_struct c{}; jpeg_error_mgr e{}; c.err = jpeg_std_error(&e);
    jpeg_create_decompress(&c); jpeg_mem_src(&c, bytes.data(), bytes.size());
    jpeg_save_markers(&c, JPEG_APP0 + 1, 65535); jpeg_save_markers(&c, JPEG_APP0 + 2, 65535);
    jpeg_read_header(&c, TRUE); Header h;
    for (int q = 0; q < 2; ++q) for (int k = 0; k < 64; ++k) h.quant[q * 64 + k] = c.quant_tbl_ptrs[q]->quantval[k];
    h.sample_h = c.comp_info[0].h_samp_factor; h.sample_v = c.comp_info[0].v_samp_factor;
    for (auto* m = c.marker_list; m; m = m->next) {
        if (m->marker == JPEG_APP0 + 1 && m->data_length >= 6 && !std::memcmp(m->data, "Exif\0\0", 6))
            h.exif.assign(m->data + 6, m->data + m->data_length);
    }
    JOCTET* profile = nullptr; unsigned len = 0;
    if (jpeg_read_icc_profile(&c, &profile, &len)) { h.icc.assign(profile, profile + len); free(profile); }
    jpeg_destroy_decompress(&c); return h;
}
static uint32_t be(const uint8_t* p) { return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3]; }
static void png_metadata(const std::vector<uint8_t>& bytes, const std::vector<uint8_t>& icc, const std::vector<uint8_t>& exif) {
    bool seen_i = false, seen_e = false;
    for (size_t p = 8; p + 12 <= bytes.size();) {
        const size_t n = be(bytes.data() + p); require(p + n + 12 <= bytes.size(), "PNG chunk bounds");
        const auto* data = bytes.data() + p + 8;
        if (!std::memcmp(bytes.data() + p + 4, "iCCP", 4)) {
            size_t z = 0; while (z < n && data[z]) ++z;
            require(z + 2 < n && data[z + 1] == 0, "PNG ICC compression");
            std::vector<uint8_t> restored(icc.size()); uLongf size = restored.size();
            require(uncompress(restored.data(), &size, data + z + 2, n - z - 2) == Z_OK && size == icc.size() && restored == icc, "PNG ICC exact"); seen_i = true;
        }
        if (!std::memcmp(bytes.data() + p + 4, "eXIf", 4)) { require(std::vector<uint8_t>(data, data + n) == exif, "PNG EXIF exact"); seen_e = true; }
        p += n + 12;
    }
    require(seen_i && seen_e, "PNG metadata absent");
}

static void tiff_contents(const std::vector<uint8_t>& bytes, uint32_t w, uint32_t h, uint32_t bits,
                          const std::vector<uint8_t>& pixels, const std::vector<uint8_t>& icc,
                          const spkhost::Exif& exif) {
    spkhost::TiffBytes t(bytes.data(), bytes.size());
    uint32_t first = 0; spkhost::TiffBytes::Ifd ifd;
    require(t.header(first) && t.little() && t.read_ifd(first, ifd), "TIFF header/IFD unreadable");
    double value = 0;
    require(t.number(ifd, 256, value) && value == w && t.number(ifd, 257, value) && value == h,
            "TIFF dimensions changed");
    require(t.number(ifd, 259, value) && value == 1 && t.number(ifd, 274, value) && value == 1,
            "TIFF compression/orientation changed");
    std::vector<double> depth, offsets, counts;
    require(t.numbers(ifd, 258, depth) && depth == std::vector<double>({double(bits), double(bits), double(bits)}),
            "TIFF sample depths changed");
    require(t.numbers(ifd, 273, offsets) && t.numbers(ifd, 279, counts) && offsets.size() == counts.size(),
            "TIFF strips unreadable");
    require(!offsets.empty() && (pixels.size() <= (1u << 20) || offsets.size() > 1), "TIFF strip coverage");
    std::vector<uint8_t> restored;
    for (size_t strip = 0; strip < offsets.size(); ++strip) {
        const size_t at = size_t(offsets[strip]), count = size_t(counts[strip]);
        require(t.in_range(at, count), "TIFF strip bounds");
        restored.insert(restored.end(), bytes.begin() + at, bytes.begin() + at + count);
    }
    require(restored == pixels, "TIFF decoded sample bytes differ");
    std::vector<uint8_t> embedded;
    require(t.bytes(ifd, 34675, embedded) && embedded == icc, "TIFF ICC changed");
    std::string text;
    require(t.text(ifd, 271, text) && text == exif.make && t.text(ifd, 272, text) && text == exif.model,
            "TIFF camera metadata changed");
    require(t.number(ifd, 34665, value), "TIFF EXIF absent");
    spkhost::TiffBytes::Ifd e;
    require(t.read_ifd(uint32_t(value), e), "TIFF EXIF unreadable");
    require(t.number(e, 0xA002, value) && value == w && t.number(e, 0xA003, value) && value == h,
            "TIFF EXIF dimensions changed");
    require(t.text(e, 0x9003, text) && text == exif.datetime_original, "TIFF timestamp changed");
}

static void tiff_streaming(const std::filesystem::path& dir, const std::vector<uint8_t>& icc,
                           const spkhost::Exif& exif) {
    // Includes a single pixel, odd row widths and several 1 MiB strips. Vary
    // both bytes of 16-bit samples so a byte-order bug cannot look correct.
    for (const auto dims : {std::array<uint32_t, 2>{1, 1}, {17, 9}, {1025, 513}}) {
        const auto w = dims[0], h = dims[1];
        std::vector<uint16_t> rgb16(size_t(w) * h * 3);
        std::vector<uint8_t> rgb8(rgb16.size()), little16(rgb16.size() * 2);
        for (size_t i = 0; i < rgb16.size(); ++i) {
            rgb16[i] = uint16_t(i * 257 + (i >> 5) * 997);
            rgb8[i] = uint8_t(rgb16[i] >> 8);
            little16[i * 2] = uint8_t(rgb16[i]); little16[i * 2 + 1] = uint8_t(rgb16[i] >> 8);
        }
        for (uint32_t bits : {8, 16}) {
            const void* rgb = bits == 8 ? static_cast<const void*>(rgb8.data()) : rgb16.data();
            std::vector<uint8_t> expected, streamed;
            std::string error;
            require(spkhost::encode_tiff(rgb, w, h, bits, icc, expected, error, &exif), error.c_str());
            const auto path = dir / "stream.tiff";
            auto* f = spkhost::open_file(path, "wb"); require(f, "open TIFF fixture");
            const bool ok = spkhost::encode_tiff_file(f, rgb, w, h, bits, icc, error, &exif);
            const bool closed = !std::fclose(f);
            require(ok && closed, "TIFF streaming write/close");
            require(spkhost::read_file(path, streamed, error) && streamed == expected, "TIFF streaming bytes differ");
            tiff_contents(streamed, w, h, bits, bits == 8 ? rgb8 : little16, icc, exif);
        }
    }
    uint16_t pixel[] = {1, 32768, 65535};
    std::string error;
    std::vector<uint8_t> out;
    require(!spkhost::encode_tiff(nullptr, 1, 1, 16, {}, out, error), "null TIFF pixels accepted");
    require(!spkhost::encode_tiff(pixel, 0, 1, 16, {}, out, error), "zero-width TIFF accepted");
    require(!spkhost::encode_tiff(pixel, UINT32_MAX, UINT32_MAX, 16, {}, out, error), "overflow TIFF accepted");
    require(!spkhost::encode_tiff_file(nullptr, pixel, 1, 1, 16, {}, error), "null TIFF file accepted");
    auto* readonly = spkhost::open_file(dir / "stream.tiff", "rb"); require(readonly, "readonly TIFF fixture");
    const bool wrote = spkhost::encode_tiff_file(readonly, pixel, 1, 1, 16, {}, error);
    std::fclose(readonly);
    require(!wrote && !error.empty(), "TIFF write failure hidden");

    const auto failed = dir / "failed-stream.tiff";
    require(!spkhost::write_file_atomic(failed, [&](std::FILE* f, std::string& why) {
        if (!spkhost::encode_tiff_file(f, pixel, 1, 1, 16, {}, why)) return false;
        why = "injected failure before commit";
        return false;
    }, false, error), "failed TIFF committed");
    require(!std::filesystem::exists(failed), "failed TIFF destination exists");
    for (const auto& entry : std::filesystem::directory_iterator(dir))
        require(entry.path().filename().string().find(".failed-stream.tiff.partial-") != 0,
                "failed TIFF temporary file leaked");
}


// Independent string-table TIFF LZW reader, deliberately unlike the encoder's
// prefix/byte hash. Reads through EOI, including width changes at the last code.
static std::vector<uint8_t> unlzw(const uint8_t* data, size_t bytes) {
    std::vector<std::vector<uint8_t>> table(4096);
    size_t bit = 0; unsigned width = 9, next = 258; int previous = -1;
    std::vector<uint8_t> result;
    auto clear = [&] { for (unsigned i = 0; i < 256; ++i) table[i] = {uint8_t(i)}; width = 9; next = 258; previous = -1; };
    clear(); bool ended = false;
    while (bit + width <= bytes * 8) {
        unsigned code = 0;
        for (unsigned i = 0; i < width; ++i, ++bit) code = (code << 1) | ((data[bit / 8] >> (7 - bit % 8)) & 1);
        if (code == 256) { clear(); continue; }
        if (code == 257) { ended = true; break; }
        std::vector<uint8_t> word;
        if (code < next) word = table[code];
        else if (code == next && previous >= 0) { word = table[previous]; word.push_back(word.front()); }
        else throw std::runtime_error("invalid TIFF LZW code");
        require(!word.empty(), "empty LZW word");
        result.insert(result.end(), word.begin(), word.end());
        if (previous >= 0 && next < 4096) { table[next] = table[previous]; table[next++].push_back(word.front()); }
        previous = int(code);
        if (next == (1u << width) - 1 && width < 12) ++width;
    }
    require(ended, "TIFF LZW EOI missing"); return result;
}
static std::vector<uint8_t> page_pixels(spkhost::TiffBytes& t, const spkhost::TiffBytes::Ifd& page,
                                         const std::vector<uint8_t>& bytes) {
    double compression = 0; std::vector<double> offsets, counts;
    require(t.number(page, 259, compression) && t.numbers(page, 273, offsets) && t.numbers(page, 279, counts) && offsets.size() == counts.size(), "TIFF strip layout");
    std::vector<uint8_t> out;
    for (size_t i = 0; i < offsets.size(); ++i) {
        const size_t at = size_t(offsets[i]), n = size_t(counts[i]);
        require(at <= bytes.size() && n <= bytes.size() - at, "TIFF strip bounds");
        auto strip = compression == 5 ? unlzw(bytes.data() + at, n) : std::vector<uint8_t>(bytes.begin() + at, bytes.begin() + at + n);
        out.insert(out.end(), strip.begin(), strip.end());
    }
    return out;
}
static void tiff_options(const std::filesystem::path& dir, const std::vector<uint8_t>& icc, const spkhost::Exif& exif) {
    std::vector<std::array<uint32_t,2>> sizes;
    for (uint32_t w = 1; w < 180; ++w) sizes.push_back({w,1});
    sizes.push_back({1025,513}); sizes.push_back({2051,17});
    uint32_t state = 0x52a8e921;
    for (const auto size : sizes) for (uint32_t bits : {8,16}) {
        const auto w = size[0], h = size[1];
        std::vector<uint16_t> rgb16(size_t(w)*h*3); std::vector<uint8_t> rgb8(rgb16.size()), expected(rgb16.size()*(bits/8));
        for (size_t i = 0; i < rgb16.size(); ++i) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5;
            rgb16[i] = uint16_t(state); rgb8[i] = uint8_t(state);
            if (bits == 8) expected[i] = rgb8[i];
            else { expected[2*i] = uint8_t(rgb16[i]); expected[2*i+1] = uint8_t(rgb16[i] >> 8); }
        }
        const bool preview = w == 1 || h > 1;
        auto* file = spkhost::open_file(dir/"options.tif", "wb"); require(file, "TIFF option fixture open"); std::string error;
        require(spkhost::encode_tiff_file(file,bits == 8 ? static_cast<const void*>(rgb8.data()) : rgb16.data(),w,h,bits,icc,{true,preview},error,&exif),error.c_str());
        require(!fclose(file), "TIFF option close");
        std::vector<uint8_t> bytes; require(spkhost::read_file(dir/"options.tif",bytes,error),error.c_str());
        spkhost::TiffBytes t(bytes.data(),bytes.size()); uint32_t first=0,next=0; spkhost::TiffBytes::Ifd page;
        require(t.header(first)&&t.read_ifd(first,page,&next),"LZW TIFF IFD");
        require(page_pixels(t,page,bytes)==expected,"LZW decoded pixels changed");
        require(bool(next)==preview,"TIFF preview policy");
        if (preview) {
            require(!(next&1)&&t.read_ifd(next,page),"TIFF preview IFD alignment"); double pw=0,ph=0,reduced=0;
            require(t.number(page,256,pw)&&t.number(page,257,ph)&&t.number(page,254,reduced)&&reduced==1,"TIFF preview tags");
            require(std::max(pw,ph)==std::min(2048u,std::max(w,h)),"TIFF preview dimensions");
            const auto small=page_pixels(t,page,bytes); require(small.size()==size_t(pw*ph)*3,"TIFF preview byte count");
            if(w<=2048) for(size_t i=0;i<small.size();++i) require(small[i] == (bits==8 ? rgb8[i] : uint8_t(std::lround(rgb16[i]/257.))),"TIFF same-size preview quantization");
            std::vector<uint8_t> profile;require(t.bytes(page,34675,profile)&&profile==icc,"TIFF preview ICC differs from file");
        }
    }
    auto* readonly=spkhost::open_file(dir/"options.tif","rb");require(readonly,"LZW readonly fixture");
    const uint8_t pixel[]={0,128,255};std::string error;
    require(!spkhost::encode_tiff_file(readonly,pixel,1,1,8,icc,{true,true},error),"LZW write failure hidden");fclose(readonly);
    std::puts("TIFF LZW: code-width boundaries, resets, odd widths, multiple strips, exact 8/16-bit pixels and preview pages passed");
}
static void extra_exif(spkhost::Exif& output) {
    spkhost::Metadata meta;
    const uint8_t program[]={0,3}, focal[]={0,85}, bias[]={255,255,255,253,0,0,0,2}, zero[]={0,0,0,0,0,0,0,1};
    spkhost::capture_exif_value(meta,0x8822,3,1,false,program,sizeof(program));
    spkhost::capture_exif_value(meta,0xA405,3,1,false,focal,sizeof(focal));
    spkhost::capture_exif_value(meta,0x9204,10,1,false,zero,sizeof(zero));
    require(meta.exposure_bias_ev && *meta.exposure_bias_ev==0,"zero exposure compensation lost");
    spkhost::capture_exif_value(meta,0x9204,10,1,false,bias,sizeof(bias));
    const uint8_t shutter[]={0,0,0,1,0,0,0,125};
    spkhost::capture_exif_value(meta,0x829A,5,1,false,shutter,sizeof(shutter));
    const uint8_t date[]="2026:10:18 12:34:56";
    spkhost::capture_exif_value(meta,0x9004,2,sizeof(date),true,date,sizeof(date));
    require(meta.exposure_program==3&&meta.focal_35mm==85&&meta.exposure_bias_ev==-1.5,"extra EXIF values/endian");
    const auto count=meta.extra_exif.size();
    spkhost::capture_exif_value(meta,0x927C,7,sizeof(date),true,date,sizeof(date));
    spkhost::capture_exif_value(meta,0x9204,10,UINT32_MAX,true,bias,sizeof(bias));
    require(meta.extra_exif.size()==count,"unsafe/malformed EXIF retained");
    output.extra=meta.extra_exif;output.exposure_program=meta.exposure_program;output.focal_35mm=meta.focal_35mm;output.exposure_bias_ev=meta.exposure_bias_ev;
    const auto block=spkhost::exif_block(output,17,9);spkhost::TiffBytes t(block.data(),block.size());uint32_t first=0;
    spkhost::Metadata restored;require(t.header(first),"EXIF block header");spkhost::read_exif_metadata(t,first,restored);
    require(restored.extra_exif.size()>=meta.extra_exif.size(),"EXIF fields missing after serialization");
    for(const auto& [tag,value]:meta.extra_exif) {const auto& actual=restored.extra_exif.at(tag);require(actual.type==value.type&&actual.count==value.count&&actual.bytes==value.bytes,"EXIF exact type/count/bytes changed");}
    require(restored.exposure_bias_ev==-1.5&&restored.focal_35mm==85&&restored.exposure_program==3,"EXIF public fields changed");
}
static void cineon_tiff(const std::filesystem::path& dir) {
    std::string error;const spkhost::Exif exif{};
    const uint16_t raw[]={0,95,65535,1234,4567,8910,32768,51700,32000,64,128,256,32,16,8,65000,0,42};
    const uint8_t preview[]={12,34,56,78,90,123};const std::vector<uint8_t> icc={1,2,3,4,5};
    auto* file=spkhost::open_file(dir/"cineon.tif","wb");require(file,"Cineon fixture open");
    require(spkhost::encode_cineon_file(file,raw,3,2,preview,2,1,icc,error,&exif),error.c_str());require(!fclose(file),"Cineon fixture close");
    std::vector<uint8_t> bytes;require(spkhost::read_file(dir/"cineon.tif",bytes,error),error.c_str());
    spkhost::TiffBytes tiff(bytes.data(),bytes.size());uint32_t first=0,next=0;spkhost::TiffBytes::Ifd a,b,metadata;
    require(tiff.header(first)&&tiff.read_ifd(first,a,&next)&&next&&tiff.read_ifd(next,b),"Cineon second IFD missing");
    require(!a.contains(34675)&&b.contains(34675),"Cineon primary must be untagged; preview must carry its own ICC");
    double pos=0,count=0,tag=0;tiff.number(a,273,pos);tiff.number(a,279,count);
    require(count==sizeof(raw)&&std::memcmp(bytes.data()+size_t(pos),raw,sizeof(raw))==0,"Cineon codes changed");
    require(tiff.number(a,34665,pos)&&tiff.read_ifd(uint32_t(pos),metadata)&&tiff.number(metadata,0xA001,tag)&&tag==65535,"Cineon EXIF is not uncalibrated");
    require(tiff.number(b,254,tag)&&tag==1,"Cineon second page is not reduced image");
    tiff.number(b,273,pos);tiff.number(b,279,count);require(count==sizeof(preview)&&std::memcmp(bytes.data()+size_t(pos),preview,sizeof(preview))==0,"Cineon preview pixels changed");
    std::vector<uint8_t> profile;require(tiff.bytes(b,34675,profile)&&profile==icc,"Cineon preview ICC changed");
    file=spkhost::open_file(dir/"cineon.tif","rb");require(file,"Cineon read-only fixture");
    require(!spkhost::encode_cineon_file(file,raw,3,2,preview,2,1,icc,error,&exif),"Cineon write failure hidden");fclose(file);
    require(!spkhost::encode_cineon_file(nullptr,raw,3,2,preview,2,1,icc,error),"Cineon null file accepted");
}

int main(int argc, char** argv) {
    try {
        require(argc >= 3 && argc <= 5, "usage: spk_host_codecs resources output-directory [benchmark PNG [quality|0=PNG]]");
        const auto dir = spkhost::utf8_path(argv[2]); std::filesystem::create_directories(dir);
        if (argc >= 4) {
            std::string error; std::vector<uint8_t> input, icc;
            require(spkhost::read_file(spkhost::utf8_path(argv[3]), input, error), error.c_str());
            int w, h, channels; auto* pixels = stbi_load_from_memory(input.data(), int(input.size()), &w, &h, &channels, 3);
            require(pixels, "benchmark input decode");
            const std::vector<uint8_t> rgb(pixels, pixels + size_t(w) * h * 3); stbi_image_free(pixels);
            require(spkhost::icc_for("sRGB", spkhost::utf8_path(argv[1]), icc, error), error.c_str());
            using Clock = std::chrono::steady_clock;
            for (int quality : {0, 92, 100}) for (int repeat = 0; repeat < 3; ++repeat) {
                if (argc == 5 && quality != std::atoi(argv[4])) continue;
                std::vector<uint8_t> old, now; double times[2]{};
                for (int step = 0; step < 2; ++step) {
                    const int variant = (step + repeat) % 2; const auto started = Clock::now();
                    if (!variant) {
                        if (!quality) require(stbi_write_png_to_func(stb_sink, &old, w, h, 3, rgb.data(), w * 3), "baseline PNG");
                        else require(stbi_write_jpg_to_func(stb_sink, &old, w, h, 3, rgb.data(), quality), "baseline JPEG");
                    } else {
                        if (!quality) require(spkhost::encode_png8(rgb.data(), w, h, icc, now, error), error.c_str());
                        else require(spkhost::encode_jpeg(rgb.data(), w, h, quality, icc, now, error), error.c_str());
                    }
                    times[variant] = std::chrono::duration<double, std::milli>(Clock::now() - started).count();
                }
                if (!quality) require(decode(now, w, h) == rgb, "full-size PNG pixels differ");
                std::printf("BENCH %dx%d Q%d repeat%d old_ms=%.3f new_ms=%.3f old_bytes=%zu new_bytes=%zu\n", w, h, quality, repeat, times[0], times[1], old.size(), now.size());
                if (quality && repeat == 0) {
                    const auto a = decode(old, w, h), b = decode(now, w, h);
                    std::printf("QUALITY Q%d PSNR %.6f -> %.6f SSIM %.7f -> %.7f\n", quality, psnr(rgb, a), psnr(rgb, b), ssim(rgb, a, w, h), ssim(rgb, b, w, h));
                }
            }
            return 0;
        }
        cineon_tiff(dir);
        constexpr int w = 513, h = 259;
        std::vector<uint8_t> rgb(size_t(w) * h * 3);
        uint32_t rng = 71;
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) for (int c = 0; c < 3; ++c) {
            rng = rng * 1664525 + 1013904223;
            const int noise = int(rng >> 27) - 16;
            const double v = 25 + 170.0 * x / (w - 1) + 30 * std::sin(double(y + c * 25) / 25) + noise;
            rgb[(size_t(y) * w + x) * 3 + c] = uint8_t(std::clamp(int(v), 0, 255));
        }
        spkhost::Exif exif; exif.make = "Codec regression"; exif.model = "Owned fixture"; exif.iso = 100; exif.shutter_s = 0.01;
        exif.datetime_original = "2026:10:12 12:00:00";
        extra_exif(exif);
        const auto expected_exif = spkhost::exif_block(exif, w, h);
        std::string error;
        for (const std::string space : {"sRGB", "Display P3", "ProPhoto RGB", "Adobe RGB (1998)", "ITU-R BT.2020"}) {
            std::vector<uint8_t> icc, png;
            require(spkhost::icc_for(space, spkhost::utf8_path(argv[1]), icc, error), error.c_str());
            if (space == "Adobe RGB (1998)" || space == "ITU-R BT.2020") {
                spkhost::RgbSpace decoded;
                require(spkhost::parse_icc(icc, decoded, error), error.c_str());
                const double white[] = {0.3457 / 0.3585, 1, (1 - 0.3457 - 0.3585) / 0.3585};
                for (int c = 0; c < 3; ++c) {
                    require(std::fabs(decoded.to_xyz_d50[c*3] + decoded.to_xyz_d50[c*3+1] + decoded.to_xyz_d50[c*3+2] - white[c]) < 5e-5, "ICC D50 whitepoint mismatch");
                    for (int k = 0; k <= 512; ++k) {
                        const double code = double(k) / 512;
                        const double expected = space == "Adobe RGB (1998)" ? std::pow(code, 563.0/256)
                            : code < 1.099*std::pow(.018,.45)-.099 ? code/4.5 : std::pow((code+.099)/1.099,1/.45);
                        require(std::fabs(decoded.trc[c].decode(code)-expected) < 3e-5, "ICC curve differs from file encoding");
                    }
                }
            }
            require(spkhost::encode_png8(rgb.data(), w, h, icc, png, error, &exif), error.c_str());
            require(decode(png, w, h) == rgb, "PNG decoded pixels differ"); png_metadata(png, icc, expected_exif);
            auto* f = spkhost::open_file(dir / "stream.png", "wb"); require(f, "open PNG fixture");
            require(spkhost::encode_png8_file(f, rgb.data(), w, h, icc, error, &exif), error.c_str()); require(!fclose(f), "PNG close");
            std::vector<uint8_t> streamed; require(spkhost::read_file(dir / "stream.png", streamed, error) && streamed == png, "PNG streaming differs");
            tiff_streaming(dir, icc, exif);
            tiff_options(dir, icc, exif);
            for (int q : {50, 80, 90, 91, 95, 96, 97, 98, 99, 100}) {
                std::vector<uint8_t> old, now;
                require(stbi_write_jpg_to_func(stb_sink, &old, w, h, 3, rgb.data(), q), "baseline JPEG");
                require(spkhost::encode_jpeg(rgb.data(), w, h, q, icc, now, error, &exif), error.c_str());
                const auto a = header(old), b = header(now);
                require(a.quant == b.quant && a.sample_h == b.sample_h && a.sample_v == b.sample_v, "JPEG quantization/subsampling changed");
                require(b.icc == icc && b.exif == expected_exif, "JPEG metadata changed");
                const auto d0 = decode(old, w, h), d1 = decode(now, w, h);
                const double p0 = psnr(rgb, d0), p1 = psnr(rgb, d1), s0 = ssim(rgb, d0, w, h), s1 = ssim(rgb, d1, w, h);
                std::printf("%s Q%d PSNR %.5f -> %.5f SSIM %.6f -> %.6f\n", space.c_str(), q, p0, p1, s0, s1);
                const auto j0 = decode_jpeg(old), j1 = decode_jpeg(now);
                std::printf("libjpeg decoder PSNR %.5f -> %.5f SSIM %.6f -> %.6f\n", psnr(rgb, j0), psnr(rgb, j1), ssim(rgb, j0, w, h), ssim(rgb, j1, w, h));
                require(p1 >= p0 - 0.1 && s1 >= s0 - 0.001, "JPEG quality regression");
                if (q >= 96) require(d0 == d1, "high-quality JPEG pixels changed");
                f = spkhost::open_file(dir / "stream.jpg", "wb"); require(f, "open JPEG fixture");
                require(spkhost::encode_jpeg_file(f, rgb.data(), w, h, q, icc, error, &exif), error.c_str()); require(!fclose(f), "JPEG close");
                require(spkhost::read_file(dir / "stream.jpg", streamed, error) && streamed == now, "JPEG streaming differs");
            }
        }
        std::vector<uint8_t> out;
        require(!spkhost::encode_png8(nullptr, 0, h, {}, out, error), "invalid PNG accepted");
        require(!spkhost::encode_jpeg(rgb.data(), 100000, h, 90, {}, out, error), "invalid JPEG accepted");
        auto* readonly = spkhost::open_file(dir / "stream.png", "rb"); require(readonly, "readonly fixture");
        require(!spkhost::encode_png8_file(readonly, rgb.data(), w, h, {}, error), "PNG write failure hidden");
        fclose(readonly);
        for (int q : {95, 100}) {
            readonly = spkhost::open_file(dir / "stream.jpg", "rb"); require(readonly, "readonly fixture");
            require(!spkhost::encode_jpeg_file(readonly, rgb.data(), w, h, q, {}, error), "JPEG write failure hidden");
            fclose(readonly);
        }
        std::puts("Codec pixel/metadata/quality/streaming/error tests passed"); return 0;
    } catch (const std::exception& e) { std::fprintf(stderr, "%s\n", e.what()); return 1; }
}
