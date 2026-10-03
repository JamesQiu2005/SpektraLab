// Minimal Windows desktop host. Rendering and file IO belong to one worker;
// only immutable, independently owned completed frames reach the window.
#define NOMINMAX
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <commdlg.h>
#include <shellapi.h>
#include "desktop/preview_host.hpp"
#include "desktop/viewport.hpp"
#include "json.hpp"
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <memory>
#include <map>
#include <mutex>
#include <optional>
#include <sstream>
#include <thread>

namespace {
namespace fs=std::filesystem;
namespace desktop=spk::desktop;
using Clock=std::chrono::steady_clock;
constexpr UINT Completed=WM_APP+1;
enum Control { Open=100, Save, Apply, Fit, Actual, Film, Paper, Mode, Exposure, Reset };
std::wstring wide(const std::string& s) {
    if(s.empty()) return {};
    int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s.data(),int(s.size()),nullptr,0);
    if(!n) return L"无法读取错误信息";
    std::wstring r(n,0);MultiByteToWideChar(CP_UTF8,0,s.data(),int(s.size()),r.data(),n);return r;
}
std::string utf8(const std::wstring& s) {
    if(s.empty()) return {};
    int n=WideCharToMultiByte(CP_UTF8,0,s.data(),int(s.size()),nullptr,0,nullptr,nullptr);
    std::string r(n,0);WideCharToMultiByte(CP_UTF8,0,s.data(),int(s.size()),r.data(),n,nullptr,nullptr);return r;
}
std::wstring seconds(double ms) { std::wostringstream s;s<<std::fixed<<std::setprecision(2)<<ms/1000<<L" 秒";return s.str(); }
struct Options { fs::path resources, open, reject, test; };
struct Reply {
    enum Kind { Init, Opened, Rendered, Saved } kind=Init;
    desktop::FramePtr frame;
    desktop::Catalog catalog;
    std::string error;
    fs::path output;
};
class Worker {
    HWND window_;fs::path resources_;
    std::mutex mutex_;std::condition_variable wake_;
    std::deque<std::function<Reply(desktop::PreviewHost&)>> jobs_;
    std::deque<Reply> replies_;bool stop_=false;std::thread thread_;
    void deliver(Reply r) {
        {std::lock_guard lock(mutex_);replies_.push_back(std::move(r));}
        PostMessageW(window_,Completed,0,0);
    }
    void loop() {
        std::unique_ptr<desktop::PreviewHost> host;
        Reply init;
        try { host=std::make_unique<desktop::PreviewHost>(resources_);init.catalog=host->catalog(); }
        catch(const std::exception& e) {init.error=e.what();}
        deliver(std::move(init));
        if(!host) return;
        for(;;) {
            std::function<Reply(desktop::PreviewHost&)> job;
            {std::unique_lock lock(mutex_);wake_.wait(lock,[&]{return stop_||!jobs_.empty();});
             if(stop_) break;
             job=std::move(jobs_.front());jobs_.pop_front();}
            deliver(job(*host));
        }
    }
public:
    Worker(HWND w,fs::path resources):window_(w),resources_(std::move(resources)),thread_([this]{loop();}){}
    ~Worker() { {std::lock_guard lock(mutex_);stop_=true;jobs_.clear();}wake_.notify_one();if(thread_.joinable())thread_.join(); }
    void submit(std::function<Reply(desktop::PreviewHost&)> job) {
        {std::lock_guard lock(mutex_);jobs_.push_back(std::move(job));}wake_.notify_one();
    }
    std::deque<Reply> take() {std::lock_guard lock(mutex_);std::deque<Reply> r; r.swap(replies_);return r;}
};
struct App {
    Options options;HWND window=nullptr;std::unique_ptr<Worker> worker;
    std::map<int,HWND> controls;desktop::Catalog catalog;desktop::FramePtr frame;
    HFONT font=nullptr,title_font=nullptr;HBRUSH panel=CreateSolidBrush(RGB(35,37,40));
    int dpi=96;bool busy=true,ready=false,closing=false,fit=true,drag=false;
    double pan_x=0,pan_y=0;POINT drag_start{};double drag_x=0,drag_y=0;
    std::wstring status=L"正在启动渲染引擎…", detail=L"选择一张 RAW 开始";
    bool error=false,icm=false,blit_ok=true;int test_step=0,busy_ticks=0,paint_count=0,label_draws=0;bool test_ok=true;
    spk::Json test_report=spk::Json::object();desktop::FramePtr held;
    int px(int v) const{return MulDiv(v,dpi,96);}
    RECT canvas() const {RECT r{};GetClientRect(window,&r);r.left=px(292);r.top=px(70);r.right-=px(18);r.bottom-=px(72);return r;}
    ~App(){worker.reset();if(font)DeleteObject(font);if(title_font)DeleteObject(title_font);DeleteObject(panel);}
    void fonts() {
        if(font)DeleteObject(font);
        if(title_font)DeleteObject(title_font);
        font=CreateFontW(-px(14),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Microsoft YaHei UI");
        title_font=CreateFontW(-px(22),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI");
        for(auto [id,h]:controls)SendMessageW(h,WM_SETFONT,WPARAM(font),TRUE);
    }
    HWND add(int id,const wchar_t* cls,const wchar_t* text,DWORD style) {
        HWND h=CreateWindowExW(0,cls,text,WS_CHILD|WS_VISIBLE|WS_TABSTOP|style,0,0,1,1,window,HMENU(INT_PTR(id)),GetModuleHandleW(nullptr),nullptr);
        if(!h)throw std::runtime_error("Cannot create window control");
        controls[id]=h;return h;
    }
    void layout() {
        RECT r{};GetClientRect(window,&r);
        auto place=[&](int id,int x,int y,int w,int h){MoveWindow(controls.at(id),px(x),px(y),px(w),px(h),TRUE);};
        place(Open,18,76,250,36);place(Film,18,165,250,280);place(Paper,18,240,250,240);
        place(Mode,18,315,250,120);place(Exposure,12,408,260,38);place(Reset,18,454,250,30);
        place(Apply,18,506,250,38);place(Save,18,560,250,38);
        MoveWindow(controls[Fit],r.right-px(206),px(18),px(86),px(30),TRUE);
        MoveWindow(controls[Actual],r.right-px(110),px(18),px(86),px(30),TRUE);
        InvalidateRect(window,nullptr,FALSE);
    }
    void clamp_pan() {
        if(!frame||fit)return;
        RECT c=canvas();int w=c.right-c.left,h=c.bottom-c.top;
        auto v=desktop::viewport(int(frame->width()),int(frame->height()),w,h,false,pan_x,pan_y);
        pan_x=frame->width()>unsigned(w)?v.x-(w-int(frame->width()))*0.5:0;
        pan_y=frame->height()>unsigned(h)?v.y-(h-int(frame->height()))*0.5:0;
    }
    void enabled() {
        EnableWindow(controls[Open],ready&&!busy&&!closing);
        for(int id:{Film,Paper,Mode,Exposure,Reset})EnableWindow(controls[id],ready&&!busy&&!closing);
        for(int id:{Apply,Save})EnableWindow(controls[id],bool(frame)&&!busy&&!closing);
        for(int id:{Fit,Actual})EnableWindow(controls[id],bool(frame)&&!closing);
    }
    void message(std::wstring s,bool failed=false) {status=std::move(s);error=failed;InvalidateRect(window,nullptr,FALSE);}
    void begin(std::wstring s) {busy=true;message(std::move(s));enabled();}
    desktop::RenderSettings settings() {
        desktop::RenderSettings s;
        auto f=SendMessageW(controls[Film],CB_GETCURSEL,0,0),p=SendMessageW(controls[Paper],CB_GETCURSEL,0,0);
        if(f>=0&&size_t(f)<catalog.films.size())s.film_stock=catalog.films[f].id;
        if(p>=0&&size_t(p)<catalog.papers.size())s.print_stock=catalog.papers[p].id;
        // Positive print brightness reduces enlarger exposure, not film exposure.
        double ev=double(SendMessageW(controls[Exposure],TBM_GETPOS,0,0))/10;
        s.print_exposure=std::exp2(-ev);return s;
    }
    desktop::DecodeMode mode() {return SendMessageW(controls[Mode],CB_GETCURSEL,0,0)==1?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16;}
    void select_settings(const desktop::RenderSettings& s,desktop::DecodeMode m) {
        for(size_t i=0;i<catalog.films.size();++i)if(catalog.films[i].id==s.film_stock)SendMessageW(controls[Film],CB_SETCURSEL,i,0);
        for(size_t i=0;i<catalog.papers.size();++i)if(catalog.papers[i].id==s.print_stock)SendMessageW(controls[Paper],CB_SETCURSEL,i,0);
        SendMessageW(controls[Mode],CB_SETCURSEL,m==desktop::DecodeMode::headroom?1:0,0);
        SendMessageW(controls[Exposure],TBM_SETPOS,TRUE,int(std::lround(-10*std::log2(s.print_exposure))));
    }
    void open(const fs::path& p) {
        if(busy||!ready)return;
        auto s=settings();auto m=mode();begin(L"正在解码并渲染："+p.filename().wstring());
        worker->submit([p,s,m](auto& host){Reply r;r.kind=Reply::Opened;
            try{r.frame=host.open_raw(p,m,s);}catch(const std::exception& e){r.error=e.what();}return r;});
    }
    void apply() {
        if(busy||!frame)return;
        auto s=settings();auto m=mode();if(m!=frame->decode_mode){open(frame->source);return;}
        begin(L"正在更新胶片效果…");worker->submit([s](auto& host){Reply r;r.kind=Reply::Rendered;
            try{r.frame=host.render(s);}catch(const std::exception& e){r.error=e.what();}return r;});
    }
    void save(const fs::path& p) {
        if(busy||!frame)return;
        auto snapshot=frame;begin(L"正在导出当前画面…");
        worker->submit([snapshot,p](auto& host){Reply r;r.kind=Reply::Saved;r.output=p;
            try{host.export_tiff(*snapshot,p);}catch(const std::exception& e){r.error=e.what();}return r;});
    }
    void choose_file(bool save_dialog) {
        std::vector<wchar_t> buf(32768,0);
        if(save_dialog&&frame) {auto name=frame->source.stem().wstring()+L"-SpektraLab.tif";std::copy(name.begin(),name.end(),buf.begin());}
        OPENFILENAMEW d{};d.lStructSize=sizeof d;d.hwndOwner=window;d.lpstrFile=buf.data();d.nMaxFile=DWORD(buf.size());
        d.lpstrFilter=save_dialog?L"16 位 TIFF\0*.tif;*.tiff\0\0":L"相机 RAW\0*.arw;*.nef;*.nrw;*.dng;*.cr2;*.cr3;*.raf;*.rw2;*.orf;*.pef;*.srw\0所有文件\0*.*\0\0";
        d.lpstrTitle=save_dialog?L"导出当前画面（现有文件不会被覆盖）":L"打开 RAW";
        d.Flags=OFN_EXPLORER|OFN_NOCHANGEDIR|OFN_PATHMUSTEXIST|(save_dialog?0:OFN_FILEMUSTEXIST);d.lpstrDefExt=save_dialog?L"tif":nullptr;
        if(save_dialog?GetSaveFileNameW(&d):GetOpenFileNameW(&d)) {
            if(save_dialog)save(fs::path(buf.data()));else open(fs::path(buf.data()));
        }
    }
    void label(HDC dc,const std::wstring& s,RECT r,COLORREF color,int flags=DT_LEFT|DT_TOP|DT_WORDBREAK) {
        SetTextColor(dc,color);DrawTextW(dc,s.c_str(),int(s.size()),&r,flags|DT_NOPREFIX);
    }
    void paint(HDC dc,bool snapshot=false) {
        ++paint_count;RECT client{};GetClientRect(window,&client);
        HBRUSH bg=CreateSolidBrush(RGB(24,26,29));FillRect(dc,&client,bg);DeleteObject(bg);
        RECT left{0,px(64),px(284),client.bottom};FillRect(dc,&left,panel);
        SetBkMode(dc,TRANSPARENT);SelectObject(dc,title_font);
        label(dc,L"SpektraLab",{px(18),px(14),px(230),px(50)},RGB(240,240,240));
        SelectObject(dc,font);
        label(dc,L"Windows  ·  RAW 胶片模拟",{px(292),px(22),client.right-px(220),px(50)},RGB(175,179,185));
        for(auto pair: {std::pair{138,L"胶片"}, {213,L"相纸"}, {288,L"RAW 解码"}})
            label(dc,pair.second,{px(18),px(pair.first),px(260),px(pair.first+24)},RGB(206,209,214));
        label(dc,L"高光扩展仍为实验功能。",{px(18),px(353),px(268),px(383)},RGB(155,161,170));
        auto ev=double(SendMessageW(controls[Exposure],TBM_GETPOS,0,0))/10;
        std::wostringstream exposure;exposure<<L"相纸亮度   "<<std::showpos<<std::fixed<<std::setprecision(1)<<ev<<L" EV";
        label(dc,exposure.str(),{px(18),px(387),px(265),px(411)},RGB(206,209,214));
        label(dc,L"修改后点击“应用效果”\n导出保存当前已显示的画面。",{px(18),px(614),px(267),px(670)},RGB(155,161,170));
        RECT c=canvas();HBRUSH surround=CreateSolidBrush(RGB(62,64,67));FillRect(dc,&c,surround);DeleteObject(surround);
        if(frame) {
            auto v=desktop::viewport(int(frame->width()),int(frame->height()),c.right-c.left,c.bottom-c.top,fit,pan_x,pan_y);
            int saved=SaveDC(dc);IntersectClipRect(dc,c.left,c.top,c.right,c.bottom);
            BITMAPV5HEADER b{};b.bV5Size=sizeof b;b.bV5Width=LONG(frame->width());b.bV5Height=-LONG(frame->height());
            b.bV5Planes=1;b.bV5BitCount=32;b.bV5Compression=BI_BITFIELDS;
            b.bV5RedMask=0x00ff0000;b.bV5GreenMask=0x0000ff00;b.bV5BlueMask=0x000000ff;b.bV5AlphaMask=0xff000000;
            b.bV5CSType=0x73524742; // LCS_sRGB ('sRGB'); avoid MinGW multichar warning.
            b.bV5Intent=LCS_GM_IMAGES;
            // A diagnostic memory-DC snapshot is explicitly NOT a monitor proof.
            bool active=!snapshot && SetICMMode(dc,ICM_ON)!=0;if(!snapshot)icm=active;
            SetStretchBltMode(dc,fit?HALFTONE:COLORONCOLOR);SetBrushOrgEx(dc,0,0,nullptr);
            int copied=StretchDIBits(dc,c.left+v.x,c.top+v.y,v.width,v.height,0,0,frame->width(),frame->height(),
                           frame->bgra8.data(),reinterpret_cast<BITMAPINFO*>(&b),DIB_RGB_COLORS,SRCCOPY);
            blit_ok=copied!=int(GDI_ERROR)&&copied!=0;
            RestoreDC(dc,saved);
            if(!blit_ok)label(dc,L"预览绘制失败",c,RGB(255,160,140),DT_CENTER|DT_VCENTER|DT_SINGLELINE);
            std::wostringstream meta;meta<<frame->width()<<L" × "<<frame->height()<<L"   ·   "<<std::fixed<<std::setprecision(1)<<v.scale*100<<L"%   ·   SDR sRGB / 8 位预览";
            label(dc,meta.str(),{c.left,c.bottom+px(8),c.right,c.bottom+px(32)},RGB(178,184,192));
        } else {
            label(dc,L"打开一张 RAW\n查看完整分辨率的胶片效果",{c.left,c.top+(c.bottom-c.top)/2-px(34),c.right,c.bottom},RGB(204,208,214),DT_CENTER|DT_TOP|DT_WORDBREAK);
        }
        RECT s{px(292),client.bottom-px(31),client.right-px(18),client.bottom-px(5)};
        label(dc,status,s,error?RGB(255,174,148):RGB(196,201,208),DT_LEFT|DT_SINGLELINE|DT_END_ELLIPSIS);
    }
    void snapshot(const fs::path& file) {
        RECT r{};GetClientRect(window,&r);HDC screen=GetDC(window),dc=CreateCompatibleDC(screen);
        BITMAPINFO b{};b.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);b.bmiHeader.biWidth=r.right;b.bmiHeader.biHeight=-r.bottom;
        b.bmiHeader.biPlanes=1;b.bmiHeader.biBitCount=32;b.bmiHeader.biCompression=BI_RGB;void* data=nullptr;
        HBITMAP bitmap=CreateDIBSection(screen,&b,DIB_RGB_COLORS,&data,nullptr,0);ReleaseDC(window,screen);
        if(!bitmap||!dc) {if(bitmap)DeleteObject(bitmap);if(dc)DeleteDC(dc);throw std::runtime_error("snapshot allocation failed");}
        HGDIOBJ old=SelectObject(dc,bitmap);paint(dc,true);
        for(auto [id,h]:controls) {
            RECT cr{};GetWindowRect(h,&cr);MapWindowPoints(nullptr,window,reinterpret_cast<POINT*>(&cr),2);
            int save=SaveDC(dc);SetViewportOrgEx(dc,cr.left,cr.top,nullptr);SendMessageW(h,WM_PRINT,WPARAM(dc),PRF_CLIENT|PRF_NONCLIENT|PRF_CHILDREN|PRF_ERASEBKGND);RestoreDC(dc,save);
        }
        GdiFlush();
        if(frame&&!fit) {
            RECT c=canvas();auto v=desktop::viewport(int(frame->width()),int(frame->height()),c.right-c.left,c.bottom-c.top,false,pan_x,pan_y);
            bool exact=true;size_t compared=0;
            for(int y=std::max(c.top,c.top+v.y);y<std::min(c.bottom,c.top+v.y+v.height);++y)
                for(int x=std::max(c.left,c.left+v.x);x<std::min(c.right,c.left+v.x+v.width);++x) {
                    const auto* source=frame->bgra8.data()+((size_t(y-c.top-v.y)*frame->width())+x-c.left-v.x)*4;
                    const auto* target=static_cast<unsigned char*>(data)+(size_t(y)*r.right+x)*4;
                    for(int ch=0;ch<3;++ch){exact&=source[ch]==target[ch];++compared;}
                }
            test_report.set("one_to_one_bgr_exact",spk::Json(exact&&compared>0));test_report.set("one_to_one_channels_compared",spk::Json(double(compared)));test_ok&=exact&&compared>0;
        }
        BITMAPFILEHEADER f{};f.bfType=0x4d42;f.bfOffBits=sizeof f+sizeof b.bmiHeader;f.bfSize=f.bfOffBits+r.right*r.bottom*4;
        std::ofstream out(file,std::ios::binary);out.write(reinterpret_cast<char*>(&f),sizeof f);out.write(reinterpret_cast<char*>(&b.bmiHeader),sizeof b.bmiHeader);
        out.write(static_cast<char*>(data),std::streamsize(r.right)*r.bottom*4);bool ok=bool(out);
        SelectObject(dc,old);DeleteObject(bitmap);DeleteDC(dc);if(!ok)throw std::runtime_error("snapshot write failed");
    }
    void finish_test() {
        test_report.set("success",spk::Json(test_ok));test_report.set("busy_timer_ticks",spk::Json(double(busy_ticks)));
        test_report.set("paint_calls",spk::Json(double(paint_count)));test_report.set("capture_kind",spk::Json(std::string("offscreen-window memory-DC, not a live monitor capture")));
        test_report.set("dpi",spk::Json(double(dpi)));test_report.set("combo_label_draws",spk::Json(double(label_draws)));
        test_report.set("source",spk::Json(utf8(options.open.wstring())));
        std::ofstream f(options.test/"ui-report.json");f<<test_report.dump()<<'\n';if(!f)test_ok=false;
        PostMessageW(window,WM_CLOSE,0,0);
    }
    void advance_test(const Reply& r) {
        if(options.test.empty())return;
        try {
            if(!r.error.empty())test_report.set("last_error",spk::Json(r.error));
            if(test_step==0 && r.kind==Reply::Init) {
                if(!r.error.empty()||options.open.empty()) {test_ok=false;finish_test();return;}
                test_step=1;open(options.open);
            } else if(test_step==1) {
                if(!r.error.empty()||!frame){test_ok=false;finish_test();return;}
                test_report.set("width",spk::Json(double(frame->width())));test_report.set("height",spk::Json(double(frame->height())));
                bool selections=true;
                for(int id:{Film,Paper,Mode}) {
                    auto selected=SendMessageW(controls[id],CB_GETCURSEL,0,0);
                    selections&=selected>=0&&SendMessageW(controls[id],CB_GETLBTEXTLEN,selected,0)>0;
                }
                test_report.set("controls_have_selected_labels",spk::Json(selections));test_ok&=selections;
                test_report.set("decode_ms",spk::Json(frame->timings.decode_ms));test_report.set("render_ms",spk::Json(frame->timings.render_ms));
                int previous_labels=label_draws;
                snapshot(options.test/"window-fit.bmp");bool fit_ok=blit_ok;
                test_report.set("combo_labels_painted",spk::Json(label_draws-previous_labels>=3));test_ok&=label_draws-previous_labels>=3;
                SendMessageW(window,WM_COMMAND,Actual,0);snapshot(options.test/"window-100.bmp");
                test_report.set("fit_and_100_blit",spk::Json(fit_ok&&blit_ok));test_ok&=fit_ok&&blit_ok;
                SendMessageW(window,WM_COMMAND,Fit,0);test_step=2;save(options.test/L"界面导出.tif");
            } else if(test_step==2) {
                test_ok&=r.error.empty()&&fs::exists(options.test/L"界面导出.tif");held=frame;
                SendMessageW(controls[Exposure],TBM_SETPOS,TRUE,5);test_step=3;SendMessageW(window,WM_COMMAND,Apply,0);
            } else if(test_step==3) {
                bool ok=r.error.empty()&&frame&&frame!=held&&frame->reprint();test_ok&=ok;
                test_report.set("brightness_cached_reprint",spk::Json(ok));held=frame;
                auto current=SendMessageW(controls[Paper],CB_GETCURSEL,0,0);
                SendMessageW(controls[Paper],CB_SETCURSEL,(current+1)%catalog.papers.size(),0);
                test_step=4;SendMessageW(window,WM_COMMAND,Apply,0);
            } else if(test_step==4) {
                bool ok=r.error.empty()&&frame&&frame!=held&&frame->settings.print_stock!=held->settings.print_stock;test_ok&=ok;
                test_report.set("paper_selection_applied",spk::Json(ok));held=frame;
                if(options.reject.empty()){finish_test();return;}test_step=5;open(options.reject);
            } else if(test_step==5) {
                bool ok=!r.error.empty()&&frame==held;test_ok&=ok;
                test_report.set("failed_open_preserves_frame",spk::Json(ok));test_report.set("rejected_reason",spk::Json(r.error));
                test_ok&=busy_ticks>0;finish_test();
            }
        }catch(const std::exception& e){test_ok=false;test_report.set("test_error",spk::Json(std::string(e.what())));finish_test();}
    }
    void completed() {
        for(auto& r:worker->take()) {
            busy=false;
            if(!r.error.empty()) {
                message(wide(r.error),true);
                if(frame)select_settings(frame->settings,frame->decode_mode);
                if(options.test.empty()&&!closing)MessageBoxW(window,status.c_str(),L"无法完成操作",MB_OK|MB_ICONWARNING);
            } else if(r.kind==Reply::Init) {
                ready=true;catalog=std::move(r.catalog);
                for(const auto& s:catalog.films)SendMessageW(controls[Film],CB_ADDSTRING,0,LPARAM(wide(s.label).c_str()));
                for(const auto& s:catalog.papers)SendMessageW(controls[Paper],CB_ADDSTRING,0,LPARAM(wide(s.label).c_str()));
                select_settings({},desktop::DecodeMode::compatible16);message(L"就绪 · 打开 RAW 开始");
            } else if(r.frame) {
                bool opened=r.kind==Reply::Opened;frame=r.frame;
                if(opened){fit=true;pan_x=pan_y=0;}
                select_settings(frame->settings,frame->decode_mode);
                SetWindowTextW(window,(frame->source.filename().wstring()+L" — SpektraLab").c_str());
                message(L"渲染完成 "+seconds(frame->timings.render_ms)+(frame->reprint()?L" · 已复用负片":L"")+L" · 16 位 TIFF 可导出");
            } else if(r.kind==Reply::Saved)message(L"已导出："+r.output.wstring());
            enabled();
            if(closing){DestroyWindow(window);return;}
            if(!options.test.empty())advance_test(r);
            else if(r.kind==Reply::Init&&ready&&!options.open.empty())open(options.open);
        }
    }
};
LRESULT dispatch(HWND h,UINT msg,WPARAM w,LPARAM l) {
    App* a=reinterpret_cast<App*>(GetWindowLongPtrW(h,GWLP_USERDATA));
    if(msg==WM_NCCREATE) {a=static_cast<App*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);a->window=h;SetWindowLongPtrW(h,GWLP_USERDATA,LONG_PTR(a));}
    if(!a)return DefWindowProcW(h,msg,w,l);
    switch(msg) {
    case WM_CREATE:
        a->dpi=GetDpiForWindow(h);
        a->add(Open,L"BUTTON",L"打开 RAW…",BS_PUSHBUTTON);a->add(Save,L"BUTTON",L"导出 16 位 TIFF…",BS_PUSHBUTTON);
        a->add(Apply,L"BUTTON",L"应用效果",BS_PUSHBUTTON);a->add(Fit,L"BUTTON",L"适合窗口",BS_PUSHBUTTON);a->add(Actual,L"BUTTON",L"100%",BS_PUSHBUTTON);
        for(int id:{Film,Paper,Mode})a->add(id,WC_COMBOBOXW,L"",CBS_DROPDOWNLIST|CBS_OWNERDRAWFIXED|CBS_HASSTRINGS|WS_VSCROLL);
        SendMessageW(a->controls[Mode],CB_ADDSTRING,0,LPARAM(L"兼容模式（默认）"));SendMessageW(a->controls[Mode],CB_ADDSTRING,0,LPARAM(L"高光扩展（实验）"));
        a->add(Exposure,TRACKBAR_CLASSW,L"",TBS_HORZ|TBS_AUTOTICKS);SendMessageW(a->controls[Exposure],TBM_SETRANGE,TRUE,MAKELONG(-20,20));
        SendMessageW(a->controls[Exposure],TBM_SETTICFREQ,10,0);a->add(Reset,L"BUTTON",L"重置选择与亮度",BS_PUSHBUTTON);
        a->fonts();a->layout();a->enabled();SetTimer(h,1,50,nullptr);DragAcceptFiles(h,TRUE);return 0;
    case WM_SIZE:a->layout();return 0;
    case WM_DPICHANGED:{a->dpi=HIWORD(w);auto r=reinterpret_cast<RECT*>(l);SetWindowPos(h,nullptr,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER|SWP_NOACTIVATE);a->fonts();a->layout();return 0;}
    case WM_GETMINMAXINFO:{auto m=reinterpret_cast<MINMAXINFO*>(l);m->ptMinTrackSize={a->px(1000),a->px(760)};return 0;}
    case WM_ERASEBKGND:return 1;
    case WM_PAINT:{PAINTSTRUCT p{};HDC dc=BeginPaint(h,&p);a->paint(dc);EndPaint(h,&p);return 0;}
    case WM_CTLCOLORSTATIC:case WM_CTLCOLORBTN:SetBkColor(HDC(w),RGB(35,37,40));SetTextColor(HDC(w),RGB(230,230,230));return LRESULT(a->panel);
    case WM_MEASUREITEM:{auto item=reinterpret_cast<MEASUREITEMSTRUCT*>(l);if(item->CtlType==ODT_COMBOBOX){item->itemHeight=a->px(24);return TRUE;}break;}
    case WM_DRAWITEM:{auto item=reinterpret_cast<DRAWITEMSTRUCT*>(l);if(item->CtlType!=ODT_COMBOBOX)break;
        bool selected=(item->itemState&ODS_SELECTED)!=0;COLORREF color=selected?RGB(68,86,102):RGB(35,37,40);
        HBRUSH brush=CreateSolidBrush(color);FillRect(item->hDC,&item->rcItem,brush);DeleteObject(brush);
        auto index=item->itemID;if(index==UINT(-1))index=UINT(SendMessageW(item->hwndItem,CB_GETCURSEL,0,0));
        if(index!=UINT(-1)){auto n=SendMessageW(item->hwndItem,CB_GETLBTEXTLEN,index,0);if(n>0&&n<4096){std::vector<wchar_t> text(size_t(n)+1);SendMessageW(item->hwndItem,CB_GETLBTEXT,index,LPARAM(text.data()));
            RECT r=item->rcItem;r.left+=a->px(7);r.right-=a->px(3);SetBkMode(item->hDC,TRANSPARENT);SelectObject(item->hDC,a->font);
            a->label(item->hDC,text.data(),r,(item->itemState&ODS_DISABLED)?RGB(135,140,148):RGB(232,235,239),DT_LEFT|DT_SINGLELINE|DT_VCENTER|DT_END_ELLIPSIS);++a->label_draws;}}
        if(item->itemState&ODS_FOCUS)DrawFocusRect(item->hDC,&item->rcItem);
        return TRUE;}
    case WM_HSCROLL:InvalidateRect(h,nullptr,FALSE);return 0;
    case WM_COMMAND:
        if(HIWORD(w)==CBN_SELCHANGE){a->message(L"设置已修改 · 点击“应用效果”更新画面");return 0;}
        switch(LOWORD(w)) {
        case Open:if(!a->busy&&a->ready)a->choose_file(false);break;
        case Save:if(!a->busy&&a->frame)a->choose_file(true);break;
        case Apply:a->apply();break;
        case Fit:a->fit=true;a->pan_x=a->pan_y=0;InvalidateRect(h,nullptr,FALSE);break;
        case Actual:a->fit=false;a->pan_x=a->pan_y=0;InvalidateRect(h,nullptr,FALSE);break;
        case Reset:if(!a->busy){a->select_settings({},desktop::DecodeMode::compatible16);a->message(L"设置已重置 · 点击“应用效果”更新画面");}break;
        }return 0;
    case WM_DROPFILES:{auto drop=HDROP(w);if(!a->busy&&a->ready&&DragQueryFileW(drop,0xffffffff,nullptr,0)==1){UINT n=DragQueryFileW(drop,0,nullptr,0);std::vector<wchar_t> p(n+1);DragQueryFileW(drop,0,p.data(),n+1);a->open(fs::path(p.data()));}DragFinish(drop);return 0;}
    case WM_LBUTTONDOWN:{POINT p{GET_X_LPARAM(l),GET_Y_LPARAM(l)};RECT c=a->canvas();if(a->frame&&!a->fit&&PtInRect(&c,p)){a->clamp_pan();a->drag=true;a->drag_start=p;a->drag_x=a->pan_x;a->drag_y=a->pan_y;SetCapture(h);}return 0;}
    case WM_MOUSEMOVE:if(a->drag){a->pan_x=a->drag_x+GET_X_LPARAM(l)-a->drag_start.x;a->pan_y=a->drag_y+GET_Y_LPARAM(l)-a->drag_start.y;a->clamp_pan();a->drag_start={GET_X_LPARAM(l),GET_Y_LPARAM(l)};a->drag_x=a->pan_x;a->drag_y=a->pan_y;InvalidateRect(h,nullptr,FALSE);}return 0;
    case WM_LBUTTONUP:if(a->drag){a->drag=false;ReleaseCapture();}return 0;
    case WM_CAPTURECHANGED:a->drag=false;return 0;
    case WM_TIMER:if(a->busy)++a->busy_ticks;return 0;
    case Completed:a->completed();return 0;
    case WM_CLOSE:if(a->busy){a->closing=true;a->message(L"正在等待当前操作完成后关闭…");a->enabled();}else DestroyWindow(h);return 0;
    case WM_DESTROY:KillTimer(h,1);PostQuitMessage(a->test_ok?0:1);return 0;
    }
    return DefWindowProcW(h,msg,w,l);
}
LRESULT CALLBACK proc(HWND h,UINT msg,WPARAM w,LPARAM l) {
    try {return dispatch(h,msg,w,l);}
    catch(const std::exception& e) {
        auto* app=reinterpret_cast<App*>(GetWindowLongPtrW(h,GWLP_USERDATA));
        if(app) {app->test_ok=false;if(app->options.test.empty())MessageBoxW(h,wide(e.what()).c_str(),L"SpektraLab",MB_OK|MB_ICONERROR);}
        PostQuitMessage(2);return msg==WM_CREATE?-1:0;
    }
}
Options options() {
    int count=0;wchar_t** args=CommandLineToArgvW(GetCommandLineW(),&count);
    std::unique_ptr<wchar_t*,decltype(&LocalFree)> held(args,&LocalFree);Options o;
    std::vector<wchar_t> path(32768);DWORD n=GetModuleFileNameW(nullptr,path.data(),DWORD(path.size()));
    if(!n||n==path.size())throw std::runtime_error("Cannot resolve executable location");
    o.resources=fs::path(path.data()).parent_path()/"resources";
    for(int i=1;i<count;++i){std::wstring k=args[i];if(i+1==count)throw std::runtime_error("Missing argument value");
        fs::path p=fs::absolute(args[++i]);
        if(k==L"--resources")o.resources=p;else if(k==L"--open")o.open=p;else if(k==L"--self-test")o.test=p;else if(k==L"--reject")o.reject=p;else throw std::runtime_error("Unknown argument");}
    if(!o.test.empty()){if(fs::exists(o.test))throw std::runtime_error("Self-test directory must not exist");fs::create_directories(o.test);}return o;
}
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,PWSTR,int show) {
    try {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        INITCOMMONCONTROLSEX cc{sizeof cc,ICC_BAR_CLASSES|ICC_STANDARD_CLASSES};InitCommonControlsEx(&cc);
        App app;app.options=options();WNDCLASSEXW wc{};wc.cbSize=sizeof wc;wc.lpfnWndProc=proc;wc.hInstance=instance;wc.hCursor=LoadCursorW(nullptr,IDC_ARROW);wc.lpszClassName=L"SpektraLabPreviewWindow";
        if(!RegisterClassExW(&wc))throw std::runtime_error("Cannot register window");
        UINT dpi=GetDpiForSystem();RECT initial{0,0,MulDiv(1280,dpi,96),MulDiv(800,dpi,96)};
        AdjustWindowRectExForDpi(&initial,WS_OVERLAPPEDWINDOW,FALSE,0,dpi);
        HWND h=CreateWindowExW(0,wc.lpszClassName,L"SpektraLab",WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN,CW_USEDEFAULT,CW_USEDEFAULT,initial.right-initial.left,initial.bottom-initial.top,nullptr,nullptr,instance,&app);
        if(!h)throw std::runtime_error("Cannot create window");
        if(app.options.test.empty())ShowWindow(h,show);
        else {SetWindowPos(h,nullptr,-30000,-30000,0,0,SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE);ShowWindow(h,SW_SHOWNOACTIVATE);}
        app.worker=std::make_unique<Worker>(h,app.options.resources);
        MSG m{};BOOL result;while((result=GetMessageW(&m,nullptr,0,0))>0){if(!IsDialogMessageW(h,&m)){TranslateMessage(&m);DispatchMessageW(&m);}}
        return result<0?1:int(m.wParam);
    }catch(const std::exception& e){MessageBoxW(nullptr,wide(e.what()).c_str(),L"SpektraLab",MB_OK|MB_ICONERROR);return 1;}
}
