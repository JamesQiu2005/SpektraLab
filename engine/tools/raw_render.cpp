// Native host: LibRaw file decode -> unchanged C API -> profiled RGB16 TIFF.
#define NOMINMAX
#include <windows.h>
#include "io/raw_decoder.hpp"
#include "io/image_writer.hpp"
#include "json.hpp"
#include "params.hpp"
#include "spektrafilm/spk_engine.h"
#include <algorithm>
#include <chrono>
#include <cstring>
#include <cstdio>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <random>
#include <stdexcept>
#include <vector>

namespace {
namespace fs = std::filesystem;
using spk::Json;
using Clock = std::chrono::steady_clock;
double ms(Clock::time_point t) { return std::chrono::duration<double,std::milli>(Clock::now()-t).count(); }
std::string utf8(const fs::path& p) { auto s=p.u8string(); return {reinterpret_cast<const char*>(s.data()),s.size()}; }
void require(bool ok, const std::string& error) { if(!ok) throw std::runtime_error(error); }
bool same_path(const fs::path& a, const fs::path& b) {
    std::error_code ec;
    if(fs::equivalent(a,b,ec) && !ec) return true;
    auto x=fs::weakly_canonical(a).wstring(), y=fs::weakly_canonical(b).wstring();
    return CompareStringOrdinal(x.c_str(),-1,y.c_str(),-1,TRUE)==CSTR_EQUAL;
}
fs::path temporary_path(const fs::path& final) {
    std::random_device random;
    for(int i=0;i<100;++i) {
        auto p=final.parent_path()/(L".spk-"+std::to_wstring(GetCurrentProcessId())+L"-"+
                                   std::to_wstring(random())+L".tmp");
        if(!fs::exists(p)) return p;
    }
    throw std::runtime_error("cannot allocate temporary output name");
}
// Keep exclusive handles through publication. Rename never replaces a file;
// an ordinary failure removes every file owned by this run using its handle.
class PendingFile {
    HANDLE h_=INVALID_HANDLE_VALUE;
    fs::path final_;
    bool committed_=false;
public:
    explicit PendingFile(const fs::path& final):final_(final) {}
    PendingFile(const fs::path& final,const fs::path& temp):PendingFile(final) {
        h_=CreateFileW(temp.c_str(),GENERIC_READ|GENERIC_WRITE|DELETE,0,nullptr,
                       CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
        require(h_!=INVALID_HANDLE_VALUE,"cannot create output: "+utf8(final));
    }
    void adopt(void* handle) noexcept { h_=handle?static_cast<HANDLE>(handle):INVALID_HANDLE_VALUE; }
    ~PendingFile() {
        if(h_!=INVALID_HANDLE_VALUE) {
            if(!committed_) {
                FILE_DISPOSITION_INFO d{TRUE};
                if(!SetFileInformationByHandle(h_,FileDispositionInfo,&d,sizeof d))
                    std::fprintf(stderr,"spk_raw_render: output rollback failed (Windows error %lu); an owned output may remain\n",GetLastError());
            }
            CloseHandle(h_);
        }
    }
    PendingFile(const PendingFile&)=delete;
    void write(const void* data,size_t n) {
        auto p=static_cast<const char*>(data);
        while(n) { DWORD chunk=DWORD(std::min<size_t>(n,16*1024*1024)),done=0;
            require(WriteFile(h_,p,chunk,&done,nullptr)&&done==chunk,"output write failed"); p+=done;n-=done; }
    }
    void publish() {
        require(FlushFileBuffers(h_),"output flush failed");
        auto s=fs::absolute(final_).wstring();
        size_t len=s.size()*sizeof(wchar_t);
        std::vector<unsigned char> buf(sizeof(FILE_RENAME_INFO)+len);
        auto* r=reinterpret_cast<FILE_RENAME_INFO*>(buf.data());
        r->ReplaceIfExists=FALSE;r->RootDirectory=nullptr;r->FileNameLength=DWORD(len);
        std::memcpy(r->FileName,s.data(),len);
        require(SetFileInformationByHandle(h_,FileRenameInfo,r,DWORD(buf.size())),
                "cannot publish output (existing files are never replaced): "+utf8(final_));
    }
    void commit() { committed_=true; }
};
Json read_json(const fs::path& path) {
    std::ifstream f(path,std::ios::binary|std::ios::ate);
    require(bool(f),"cannot read params file");auto n=f.tellg();
    require(n>0 && n<=1024*1024,"params must contain at most 1 MiB of JSON");
    std::string s(size_t(n),'\0');f.seekg(0);f.read(s.data(),n);
    require(bool(f) && s.find('\0')==std::string::npos,"invalid params bytes");
    if(s.starts_with("\xef\xbb\xbf")) s.erase(0,3);
    Json j;std::string error;auto ok=Json::parse(s,j,error);require(ok,"params: "+error);
    require(j.is_object(),"params must be an object");return j;
}
void enforce(Json& params,const char* key,Json expected) {
    require(!params.has(key)||params.at(key).dump()==expected.dump(),
            std::string("native TIFF contract requires ")+key+"="+expected.dump());
    params.set(key,std::move(expected));
}
Json parse_reply(char* text) {
    std::unique_ptr<char,decltype(&spk_string_free)> held(text,&spk_string_free);
    Json j; std::string error;
    require(text && Json::parse(text,j,error),"invalid engine reply");return j;
}
struct Result { spk_result value{}; ~Result(){spk_result_free(&value);} };

int run(int argc,wchar_t** argv) {
    if(argc==2 && std::wstring(argv[1])==L"--help") {
        std::cout<<"spk_raw_render --input RAW --output TIFF --report JSON --resources DIR "
                    "[--params JSON] [--decoded-output F32] [--decode-mode compatible16|headroom]\n"
                    "AHD, as-shot WB, linear ProPhoto 16-bit compatible decode; sRGB RGB16 TIFF.\n"
                    "headroom is opt-in: uint16 Bayer demosaic, float RGB conversion; not full-float RAW.\n"
                    "Existing outputs are never overwritten.\n";return 0;
    }
    const auto started=Clock::now();
    std::map<std::wstring,fs::path> args;
    std::wstring decode_mode=L"compatible16";
    bool mode_seen=false;
    for(int i=1;i<argc;i+=2) {
        std::wstring k=argv[i];
        if(k==L"--decode-mode") {
            require(i+1<argc && !mode_seen,"missing value or duplicate decode mode");
            decode_mode=argv[i+1];mode_seen=true;
            require(decode_mode==L"compatible16"||decode_mode==L"headroom","decode mode must be compatible16 or headroom");
            continue;
        }
        require(k==L"--input"||k==L"--output"||k==L"--report"||k==L"--resources"||k==L"--params"||k==L"--decoded-output","unknown argument");
        require(i+1<argc && !args.contains(k),"missing value or duplicate argument");
        args[k]=fs::absolute(fs::path(argv[i+1]));
    }
    for(auto k:{L"--input",L"--output",L"--report",L"--resources"}) require(args.contains(k),"missing required argument; see --help");
    std::vector<fs::path> outputs{args[L"--output"],args[L"--report"]};
    if(args.contains(L"--decoded-output")) outputs.push_back(args[L"--decoded-output"]);
    for(size_t i=0;i<outputs.size();++i) {
        require(!fs::exists(outputs[i]),"output already exists: "+utf8(outputs[i]));
        require(fs::is_directory(outputs[i].parent_path()),"output parent directory does not exist");
        require(!same_path(outputs[i],args[L"--input"]),"output aliases input");
        if(args.contains(L"--params")) require(!same_path(outputs[i],args[L"--params"]),"output aliases params");
        for(size_t j=0;j<i;++j) require(!same_path(outputs[i],outputs[j]),"output paths must be distinct");
    }
    require(fs::is_regular_file(args[L"--input"]),"RAW input is missing");
    // The legacy engine resource loader takes narrow paths on Windows. Reject
    // unsupported paths explicitly until that independent portability fix lands.
    auto resources=utf8(args[L"--resources"]);
    require(std::all_of(resources.begin(),resources.end(),[](unsigned char c){return c<128;}),
            "engine resources directory currently requires an ASCII path");
    require(fs::is_directory(args[L"--resources"]),"resources directory is missing");
    Json params=args.contains(L"--params")?read_json(args[L"--params"]):Json::object();
    enforce(params,"input_color_space",Json(std::string("ProPhoto RGB")));
    enforce(params,"input_cctf_decoding",Json(false));
    enforce(params,"output_color_space",Json(std::string("sRGB")));
    enforce(params,"output_cctf_encoding",Json(true));
    enforce(params,"extended_dynamic_range",Json(false));
    std::string error,param;
    auto valid=spk::validate_delta(params,error,param);require(valid,"params: "+error);
    Json timings=Json::object();
    auto t=Clock::now();
    std::unique_ptr<spk_engine,decltype(&spk_engine_destroy)> engine(spk_engine_create(resources.c_str(),nullptr),&spk_engine_destroy);
    require(bool(engine),"engine creation failed; check resources and Vulkan");
    timings.set("engine_create",Json(ms(t)));
    spk::io::DecodedRaw decoded;
    t=Clock::now();
    auto decoded_ok=decode_mode==L"headroom"
        ? spk::io::decode_raw_headroom(args[L"--input"],decoded,error)
        : spk::io::decode_raw_compatible(args[L"--input"],decoded,error);
    require(decoded_ok,"RAW decode: "+error);
    timings.set("decode",Json(ms(t)));
    spk_image input{decoded.rgb.data(),decoded.width,decoded.height,3};
    auto delta=params.dump();char* reply=nullptr;
    t=Clock::now();
    std::unique_ptr<spk_session,decltype(&spk_session_release)> session(spk_open(engine.get(),&input,delta.c_str(),&reply),&spk_session_release);
    if(!session) {if(reply) spk_string_free(reply);throw std::runtime_error(spk_last_error(engine.get()));}
    auto opened=parse_reply(reply);timings.set("open",Json(ms(t)));
    Result result;t=Clock::now();
    auto status=spk_render(session.get(),"full",&result.value);require(status==SPK_OK,spk_last_error(engine.get()));
    timings.set("render",Json(ms(t)));timings.set("engine_render",Json(result.value.elapsed_ms));
    // Export also exercises the independently owned result after engine teardown.
    session.reset();engine.reset();
    std::vector<std::unique_ptr<PendingFile>> files;
    t=Clock::now();
    if(args.contains(L"--decoded-output")) {
        auto f=std::make_unique<PendingFile>(args[L"--decoded-output"],temporary_path(args[L"--decoded-output"]));
        f->write(decoded.rgb.data(),decoded.rgb.size()*sizeof(float));files.push_back(std::move(f));
    }
    timings.set("decoded_write",Json(ms(t)));
    const auto temp=temporary_path(args[L"--output"]);t=Clock::now();
    auto tiff=std::make_unique<PendingFile>(args[L"--output"]);
    void* tiff_handle=nullptr;
    auto written=spk::io::write_srgb_tiff_held(temp,result.value.rgba16,result.value.width,result.value.height,
             result.value.row_stride_px,args[L"--resources"]/"io"/"sRGB.icc",tiff_handle,error);
    tiff->adopt(tiff_handle);require(written,"TIFF: "+error);
    timings.set("write",Json(ms(t)));files.push_back(std::move(tiff));
    Json report=Json::object(),in=Json::object(),out=Json::object(),decode=Json::object();
    report.set("format_version",Json(1.0));report.set("success",Json(true));
    in.set("path",Json(utf8(args[L"--input"])));in.set("width",Json(double(decoded.width)));in.set("height",Json(double(decoded.height)));
    in.set("color_space",Json(std::string("ProPhoto RGB")));in.set("transfer",Json(std::string("linear")));
    report.set("input",in);report.set("params_delta",params);report.set("resolved_params",opened.at("params"));
    decode.set("libraw_version",Json(decoded.metadata.libraw_version));
    const bool headroom=decoded.metadata.headroom_enabled;
    decode.set("mode",Json(std::string(headroom?"headroom":"compatible16")));
    decode.set("policy",Json(std::string(headroom
        ? "headroom: uint16 Bayer AHD with maximum-normalised camera WB; float ProPhoto matrix; restored WB exposure scale; RGB conversion does not clip"
        : "compatible16: AHD, as-shot WB, linear ProPhoto RGB, uint16 clip then float32 / 65535")));
    decode.set("preserves_negative_rgb",Json(headroom));decode.set("preserves_above_one_rgb",Json(headroom));
    decode.set("preservation_scope",Json(std::string(headroom?"RGB conversion after uint16 demosaic":"none")));
    decode.set("sensor_saturation_reconstructed",Json(false));decode.set("float_demosaic",Json(false));
    decode.set("white_balance_exposure_restore",Json(decoded.metadata.white_balance_exposure_restore));
    decode.set("raw_flip",Json(double(decoded.metadata.raw_flip)));
    decode.set("make",Json(decoded.metadata.make));decode.set("model",Json(decoded.metadata.model));
    decode.set("decoder_name",Json(decoded.metadata.decoder_name));
    decode.set("source_as_shot_wb_applied",Json(decoded.metadata.as_shot_wb_applied));
    decode.set("camera_wb_requested",Json(true));
    decode.set("process_warnings",Json(double(decoded.metadata.process_warnings)));
    auto array=[](const auto& values) { Json a=Json::array();for(auto value:values) a.push(Json(double(value)));return a; };
    decode.set("camera_whitebalance",array(decoded.metadata.camera_whitebalance));
    if(headroom) decode.set("camera_to_output",array(decoded.metadata.camera_to_output));
    decode.set("post_scale_pre_mul",array(decoded.metadata.post_scale_pre_mul));
    decode.set("black_level_per_channel",array(decoded.metadata.black_level_per_channel));
    decode.set("white_level",Json(double(decoded.metadata.white_level)));
    decode.set("camera_white_level_per_channel",array(decoded.metadata.camera_white_level_per_channel));
    decode.set("black_pattern",array(decoded.metadata.black_pattern));
    decode.set("black_pattern_rows",Json(double(decoded.metadata.black_pattern_rows)));
    decode.set("black_pattern_cols",Json(double(decoded.metadata.black_pattern_cols)));
    decode.set("open_ms",Json(decoded.timings.open_ms));decode.set("unpack_ms",Json(decoded.timings.unpack_ms));
    decode.set("process_ms",Json(decoded.timings.process_ms));decode.set("convert_ms",Json(decoded.timings.convert_ms));
    report.set("decode",decode);
    out.set("path",Json(utf8(args[L"--output"])));out.set("width",Json(double(result.value.width)));out.set("height",Json(double(result.value.height)));
    out.set("color_space",Json(std::string("sRGB")));out.set("output_cctf_encoding",Json(true));out.set("format",Json(std::string("RGB16 TIFF with ICC")));
    report.set("output",out);timings.set("total_before_publish",Json(ms(started)));report.set("timings_ms",timings);
    auto report_file=std::make_unique<PendingFile>(args[L"--report"],temporary_path(args[L"--report"]));
    auto json=report.dump()+"\n";report_file->write(json.data(),json.size());files.push_back(std::move(report_file));
    size_t published=0;
    try { for(auto& f:files) {f->publish();++published;} }
    catch(const std::exception& e) {
        throw std::runtime_error(std::string(e.what())+"; rolling back published outputs="+std::to_string(published));
    }
    for(auto& f:files) f->commit();
    std::cout<<json;return 0;
}
}
int wmain(int argc,wchar_t** argv) {
    try {return run(argc,argv);} catch(const std::exception& e) {std::cerr<<"spk_raw_render: "<<e.what()<<'\n';return 1;}
}
