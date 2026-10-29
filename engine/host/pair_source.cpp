#include "pair_source.hpp"
#include "platform.hpp"
#include <algorithm>
#include <bit>
#include <cmath>
#include <cwctype>
#include <limits>
#include <stdexcept>

namespace spkhost {
namespace {
using spk::Json;
constexpr const char* sides[] = {"left", "right"};
constexpr size_t cache_budget = 256u << 20;
double number(const Json& object, const char* key, double fallback, double low, double high) {
    const auto& v = object.at(key);
    if (v.is_null()) return fallback;
    if (!v.is_number() || !std::isfinite(v.as_double()) || v.as_double() < low || v.as_double() > high)
        throw std::invalid_argument(std::string("pair: invalid ") + key);
    return v.as_double();
}
bool flag(const Json& object, const char* key, bool fallback = false) {
    const auto& v = object.at(key);
    if (v.is_null()) return fallback;
    if (!v.is_bool()) throw std::invalid_argument(std::string("pair: invalid ") + key);
    return v.as_bool();
}
int turn(const Json& object) {
    const double n = number(object, "quarterTurns", 0, -1000, 1000);
    if (std::round(n) != n) throw std::invalid_argument("pair: quarterTurns must be integral");
    return (int(n) % 4 + 4) % 4;
}
struct Geometry {
    double x = 0, y = 0, width = 1, height = 1, angle = 0;
    int turns = 0; bool flip_h = false, flip_v = false;
    explicit Geometry(const Json& j) {
        if (!j.is_null() && !j.is_object()) throw std::invalid_argument("pair: geometry must be an object");
        const auto& c = j.at("crop");
        x = number(c, "x", 0, 0, 1); y = number(c, "y", 0, 0, 1);
        width = number(c, "width", 1, 1e-9, 1); height = number(c, "height", 1, 1e-9, 1);
        if (x + width > 1.000001 || y + height > 1.000001) throw std::invalid_argument("pair: crop outside source");
        angle = number(j, "angle", 0, -45, 45) * 3.14159265358979323846 / 180;
        turns = turn(j); flip_h = flag(j, "flipH"); flip_v = flag(j, "flipV");
    }
    std::array<double, 2> size(uint32_t w, uint32_t h) const {
        std::array<double, 2> result{std::max(1., std::round(w * width)), std::max(1., std::round(h * height))};
        if (turns % 2) std::swap(result[0], result[1]);
        return result;
    }
};
std::array<double, 2> unturn(double x, double y, int turns) {
    if (turns == 1) return {y, 1 - x};
    if (turns == 2) return {1 - x, 1 - y};
    if (turns == 3) return {1 - y, x};
    return {x, y};
}
std::array<double, 4> placement(const Json& p, double w, double h, double aspect, bool fit = false) {
    double cw = w, ch = h;
    if (w / h > aspect) cw = ch * aspect; else ch = cw / aspect;
    const double scale = fit ? 1 : number(p, "scale", 1, 1, 4);
    cw /= scale; ch /= scale;
    const double x = number(p, "x", 0, -1, 1), y = number(p, "y", 0, -1, 1);
    return {(w - cw) * (1 + x) / 2, (h - ch) * (1 + y) / 2, cw, ch};
}
void validate(const Json& pair) {
    if (!pair.is_object()) throw std::invalid_argument("pair must be an object");
    if (number(pair, "schemaVersion", 1, 1, 1) != 1) throw std::invalid_argument("pair: unsupported schema");
    number(pair, "spacingMM", 1, .5, 2); flag(pair, "turned"); flag(pair, "onStrip");
    for (const char* side : sides) {
        const auto& hole = pair.at(side); if (hole.is_null()) continue;
        if (!hole.is_object() || !hole.at("path").is_string() || hole.at("path").as_string().empty())
            throw std::invalid_argument("pair: hole needs a photograph path");
        auto extension = utf8_path(hole.at("path").as_string()).extension().wstring();
        std::transform(extension.begin(), extension.end(), extension.begin(), ::towlower);
        if (extension == L".spektrapair") throw std::invalid_argument("pair: nested pair sources are not supported");
        Geometry geometry(hole.at("geometry"));
        const auto& p = hole.at("placement"); turn(p); placement(p, 24, 18, .75);
        number(hole, "exposureEV", 0, -5, 5); flag(hole, "autoExposure", true);
        number(hole, "exposureBaselineEV", 0, -64, 64);
        if (!hole.at("decode").is_null() && !hole.at("decode").is_object()) throw std::invalid_argument("pair: decode must be an object");
    }
}
std::string stamp(const std::string& path) {
    std::error_code ec; const auto file = utf8_path(path);
    const auto time = std::filesystem::last_write_time(file, ec);
    if (ec) return path + "|missing";
    const auto size = std::filesystem::file_size(file, ec);
    return path + "|" + std::to_string(static_cast<long long>(time.time_since_epoch().count())) + "|" + std::to_string(size);
}
std::string method(const Json& hole, const Json& params) {
    auto m = hole.at("meterMethod").as_string();
    if (m.empty()) m = params.at("auto_exposure_method").as_string();
    return m.empty() ? "balanced" : m;
}
std::string meter_key(const Json& hole, const Json& params) {
    return stamp(hole.at("path").as_string()) + "|" + hole.at("decode").dump() + "|" + hole.at("geometry").dump() + "|" + method(hole,params);
}
std::optional<double> saved_meter(const Json& hole, const Json& params) {
    const auto& value=hole.at("meteredEV");
    // Far wider than the meter's half-float input and 12-stop luminance floor,
    // but bounded so a forged cache value cannot overflow the source plane.
    if (!flag(hole,"autoExposure",true) || !value.is_number() || !std::isfinite(value.as_double()) || std::abs(value.as_double())>64 ||
        hole.at("meteredFor").as_string()!=meter_key(hole,params)) return {};
    return value.as_double();
}
// IEEE binary16, nearest-even. PairComposer's cached RGBAh is the same
// quantization boundary; half precision is deliberately limited to pair holes.
uint16_t half(float f) {
    const uint32_t bits = std::bit_cast<uint32_t>(f), sign = (bits >> 16) & 0x8000;
    const int exponent = int((bits >> 23) & 255) - 127;
    const uint32_t mantissa = bits & 0x7fffff;
    if (!std::isfinite(f) || std::abs(f) > 65504.f) throw std::runtime_error("pair source exceeds finite half-float range");
    if (exponent < -25) return uint16_t(sign);
    unsigned shift = exponent < -14 ? unsigned(-exponent - 1) : 13;
    uint32_t value = exponent < -14 ? (mantissa | 0x800000) : mantissa;
    uint32_t base = value >> shift, remainder = value & ((1u << shift) - 1), midpoint = 1u << (shift - 1);
    base += remainder > midpoint || (remainder == midpoint && (base & 1));
    if (exponent >= -14) base += uint32_t(exponent + 15) << 10;
    return uint16_t(sign | base);
}
float from_half(uint16_t bits) {
    const float sign = bits & 0x8000 ? -1.f : 1.f;
    const unsigned exponent = (bits >> 10) & 31, mantissa = bits & 1023;
    return sign * (exponent ? std::ldexp(1.f + mantissa / 1024.f, int(exponent) - 15) : std::ldexp(float(mantissa), -24));
}
float bilinear(const FloatImage& src, double u, double v, unsigned channel) {
    const double x = std::clamp(u * src.width - .5, 0., double(src.width - 1));
    const double y = std::clamp(v * src.height - .5, 0., double(src.height - 1));
    const uint32_t x0 = uint32_t(x), y0 = uint32_t(y), x1 = std::min(x0 + 1, src.width - 1), y1 = std::min(y0 + 1, src.height - 1);
    const float dx = float(x - x0), dy = float(y - y0);
    auto at = [&](uint32_t xx, uint32_t yy) { return src.rgb[(size_t(yy) * src.width + xx) * 3 + channel]; };
    return (at(x0,y0) * (1-dx) + at(x1,y0) * dx) * (1-dy) + (at(x0,y1) * (1-dx) + at(x1,y1) * dx) * dy;
}
}

PairSource::Description PairSource::describe(const Json& pair) {
    validate(pair); Description d;
    const bool turned = flag(pair, "turned"); const double aspect = turned ? 4./3 : 3./4;
    double across = std::numeric_limits<double>::infinity(), longest = 0;
    for (size_t i = 0; i < 2; ++i) {
        const auto& hole = pair.at(sides[i]); if (hole.is_null()) continue;
        if (!probe_file(utf8_path(hole.at("path").as_string()), d.probes[i], d.errors[i])) continue;
        d.available[i] = true;
        auto framed = Geometry(hole.at("geometry")).size(d.probes[i].width, d.probes[i].height);
        longest = std::max({longest, framed[0], framed[1]});
        if (turn(hole.at("placement")) % 2) std::swap(framed[0], framed[1]);
        const auto cut = placement(hole.at("placement"), framed[0], framed[1], aspect, true);
        across = std::min(across, turned ? cut[2] : cut[3]);
    }
    if (!std::isfinite(across)) across = 2400;
    if (longest > 0) across = std::min(across, longest / (37./24));
    const uint32_t a = std::max(8u, uint32_t(std::floor(across)));
    const uint32_t along = std::max(6u, uint32_t(std::lround(a * 18./24)));
    const double spacing = flag(pair, "onStrip") ? 1 : number(pair, "spacingMM", 1, .5, 2);
    d.advance = uint32_t(std::lround(along * (18 + spacing) / 18));
    d.hole_width = turned ? a : along; d.hole_height = turned ? along : a;
    d.width = d.hole_width + (turned ? 0 : d.advance); d.height = d.hole_height + (turned ? d.advance : 0);
    for (size_t i = 0; i < 2; ++i) {
        Json r = Json::object(); r.set("x", Json(turned ? 0. : double(i*d.advance)/d.width));
        r.set("y", Json(turned ? double(i*d.advance)/d.height : 0.));
        r.set("width", Json(double(d.hole_width)/d.width)); r.set("height", Json(double(d.hole_height)/d.height));
        d.gates.push(std::move(r));
    }
    return d;
}

Json PairSource::carry_meter_readings(const Json& pair, const Json& params, const Json& prior) {
    Json out=pair;
    for (const char* side : sides) {
        auto hole=pair.at(side);const auto& old=prior.at(side);
        if (hole.is_null() || old.is_null() || !hole.at("meteredEV").is_null() || !hole.at("meteredFor").is_null()) continue;
        const auto reading=saved_meter(old,params);
        if (reading && meter_key(hole,params)==meter_key(old,params)) {
            hole.set("meteredEV",Json(*reading));hole.set("meteredFor",old.at("meteredFor"));out.set(side,std::move(hole));
        }
    }
    return out;
}
std::string PairSource::signature(const Json& input, const Json& params, const Json& prior) {
    const Json pair=carry_meter_readings(input,params,prior);
    validate(pair); Json key = Json::object();
    key.set("turned", Json(flag(pair,"turned")));
    key.set("spacing", Json(flag(pair,"onStrip") ? 1. : number(pair,"spacingMM",1,.5,2)));
    for (const char* side : sides) {
        const auto& hole = pair.at(side); if (hole.is_null()) continue;
        Json h = Json::object(); h.set("file", Json(stamp(hole.at("path").as_string())));
        for (const char* name : {"decode", "geometry", "placement", "exposureEV", "exposureBaselineEV", "autoExposure"}) h.set(name,hole.at(name));
        if (const auto reading=saved_meter(hole,params)) h.set("meteredEV",Json(*reading));
        h.set("method", Json(method(hole, params))); key.set(side, std::move(h));
    }
    return key.dump();
}

size_t PairSource::cached_bytes() const {
    size_t bytes = 0; for (const auto& e : images_) bytes += e.picture->rgb.size()*sizeof(uint16_t); return bytes;
}

bool PairSource::compose(const Json& pair, const Json& params, FloatImage& out, Description& d,
                          std::array<std::optional<double>,2>& metered, const Decode& decode,
                          const Meter& meter, const Checkpoint& checkpoint, std::string& error, uint32_t max_edge) {
    d = describe(pair); const bool turned = flag(pair,"turned"); const double aspect = turned ? 4./3 : 3./4;
    if (max_edge && std::max(d.width,d.height)>max_edge) {
        const double scale=double(max_edge)/std::max(d.width,d.height);
        d.hole_width=std::max(1u,uint32_t(std::lround(d.hole_width*scale)));
        d.hole_height=std::max(1u,uint32_t(std::lround(d.hole_height*scale)));
        d.advance=std::max(1u,uint32_t(std::lround(d.advance*scale)));
        d.width=d.hole_width+(turned?0:d.advance);d.height=d.hole_height+(turned?d.advance:0);
    }
    if (uint64_t(d.width)*d.height > 128000000ull) { error = "pair exceeds the 128 MP source memory limit"; return false; }
    FloatImage result; result.width = d.width; result.height = d.height;
    result.rgb.assign(size_t(d.width)*d.height*3,0);
    for (size_t side = 0; side < 2; ++side) {
        checkpoint(); if (!d.available[side]) continue;
        const auto& hole = pair.at(sides[side]); const auto& pl = hole.at("placement");
        const Geometry geom(hole.at("geometry"));
        const std::string source_key = stamp(hole.at("path").as_string()) + "|" + hole.at("decode").dump() + "|" + hole.at("geometry").dump();
        const std::string key = source_key + "|" + pl.dump() + "|" + std::to_string(d.hole_width) + "x" + std::to_string(d.hole_height);
        auto found = std::find_if(images_.begin(),images_.end(),[&](const Entry& e){return e.key==key;});
        std::shared_ptr<Picture> picture;
        if (found != images_.end()) { picture = found->picture; images_.splice(images_.begin(),images_,found); }
        else {
            FloatImage source; Probe probe;
            if (!decode(utf8_path(hole.at("path").as_string()),hole.at("decode"),source,probe,d.errors[side])) { d.available[side]=false; continue; }
            checkpoint(); d.probes[side]=probe;
            if (!source.width || !source.height || source.rgb.size()!=size_t(source.width)*source.height*3) { error="pair decoded source has invalid dimensions";return false; }
            auto framed=geom.size(source.width,source.height); const int turns=turn(pl);
            if (turns%2) std::swap(framed[0],framed[1]);
            const auto cut=placement(pl,framed[0],framed[1],aspect);
            picture=std::make_shared<Picture>(); picture->width=d.hole_width; picture->height=d.hole_height;
            picture->probe=probe; picture->raw_metadata=source.raw_metadata;
            picture->rgb.resize(size_t(d.hole_width)*d.hole_height*3);
            const double ca=std::cos(geom.angle),sa=std::sin(geom.angle);
            for(uint32_t y=0;y<d.hole_height;++y) {
                if(!(y%64))checkpoint();
                for(uint32_t x=0;x<d.hole_width;++x) {
                    auto uv=unturn((cut[0]+(x+.5)/d.hole_width*cut[2])/framed[0],
                                   (cut[1]+(y+.5)/d.hole_height*cut[3])/framed[1],turns);
                    if(geom.flip_h)uv[0]=1-uv[0]; if(geom.flip_v)uv[1]=1-uv[1]; uv=unturn(uv[0],uv[1],geom.turns);
                    const double px=(uv[0]-.5)*geom.width*source.width,py=(uv[1]-.5)*geom.height*source.height;
                    const double u=geom.x+geom.width/2+(px*ca-py*sa)/source.width;
                    const double v=geom.y+geom.height/2+(px*sa+py*ca)/source.height;
                    for(unsigned c=0;c<3;++c)picture->rgb[(size_t(y)*d.hole_width+x)*3+c]=half(bilinear(source,u,v,c));
                }
            }
            // The full decode dies before composition/meter upload. Oversized
            // holes use the exact same quantized buffer but are not retained.
            if(picture->rgb.size()*2<=cache_budget) {
                while(!images_.empty()&&(images_.size()>=3||cached_bytes()+picture->rgb.size()*2>cache_budget))images_.pop_back();
                images_.push_front({key,picture});
            }
        }
        d.probes[side]=picture->probe; d.raw_metadata[side]=picture->raw_metadata;
        double ev=number(hole,"exposureEV",0,-5,5);
        if(!flag(hole,"autoExposure",true)) ev+=number(hole,"exposureBaselineEV",0,-64,64);
        if(flag(hole,"autoExposure",true)) {
            // Moving/zooming a hole must not make its exposure pump. A new
            // source/decode/geometry/meter intent invalidates the reading.
            const std::string reading_key=meter_key(hole,params);
            d.meter_keys[side]=reading_key;
            auto existing=meters_.find(reading_key);
            double measured=0;
            if(const auto saved=saved_meter(hole,params))measured=*saved;
            else if(hole.at("meteredEV").is_null() && hole.at("meteredFor").is_null() && existing!=meters_.end())measured=existing->second;
            else {
                FloatImage small;const double scale=std::min(1.,1024./std::max(picture->width,picture->height));
                small.width=std::max(1u,uint32_t(std::lround(picture->width*scale)));small.height=std::max(1u,uint32_t(std::lround(picture->height*scale)));
                small.rgb.resize(size_t(small.width)*small.height*3);
                for(uint32_t y=0;y<small.height;++y)for(uint32_t x=0;x<small.width;++x)for(unsigned c=0;c<3;++c) {
                    // Area-average the half-float hole for the meter, bounded
                    // by its 1024-edge output; no full float hole is allocated.
                    const uint32_t x0=uint32_t(uint64_t(x)*picture->width/small.width),x1=std::max(x0+1,uint32_t(uint64_t(x+1)*picture->width/small.width));
                    const uint32_t y0=uint32_t(uint64_t(y)*picture->height/small.height),y1=std::max(y0+1,uint32_t(uint64_t(y+1)*picture->height/small.height));
                    double sum=0;for(uint32_t yy=y0;yy<y1;++yy)for(uint32_t xx=x0;xx<x1;++xx)sum+=from_half(picture->rgb[(size_t(yy)*picture->width+xx)*3+c]);
                    small.rgb[(size_t(y)*small.width+x)*3+c]=float(sum/((x1-x0)*(y1-y0)));
                }
                checkpoint();measured=meter(small,method(hole,params));
                if(!std::isfinite(measured)){error="pair meter returned a non-finite exposure";return false;}
            }
            if(meters_.size()>=16)meters_.erase(meters_.begin());meters_[reading_key]=measured;
            metered[side]=measured;ev+=measured;
        }
        const float gain=float(std::exp2(ev));const uint32_t ox=turned?0:uint32_t(side)*d.advance,oy=turned?uint32_t(side)*d.advance:0;
        if (!std::isfinite(gain)) { error="pair exposure is outside the finite float range"; return false; }
        d.gains[side]=gain;
        for(uint32_t y=0;y<picture->height;++y) {
            if(!(y%64))checkpoint();
            for(uint32_t x=0;x<picture->width;++x)for(unsigned c=0;c<3;++c)
                result.rgb[(size_t(y+oy)*d.width+x+ox)*3+c]=from_half(picture->rgb[(size_t(y)*picture->width+x)*3+c])*gain;
        }
    }
    out=std::move(result);return true;
}
}
