#include "DisplayColor.hpp"
#include <QColorSpace>
#include <QFile>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string>
#include <utility>
#include <vector>

namespace {
display::Target unknown(QString status) { return {display::Mode::Unknown,{},std::move(status)}; }
struct AdvancedColorInfo2 {
    DISPLAYCONFIG_DEVICE_INFO_HEADER header;
    UINT32 flags;
    DISPLAYCONFIG_COLOR_ENCODING colorEncoding;
    UINT32 bitsPerColorChannel;
    UINT32 activeColorMode;
};
static_assert(sizeof(AdvancedColorInfo2)==36);
}
#endif

namespace display {
QImage transformToMonitorProfile(const QImage& image,const QByteArray& bytes) {
    const auto profile=QColorSpace::fromIccProfile(bytes);
    if(image.isNull()||!image.colorSpace().isValid()||!profile.isValid())return {};
    auto converted=image.convertedToColorSpace(profile);
    return converted.colorSpace()==profile?converted:QImage{};
}

Target targetForWindow(QWindow* window) {
#ifdef _WIN32
    if(!window)return unknown(QStringLiteral("显示器色彩状态未知（预览保持 sRGB）"));
    const HWND hwnd=reinterpret_cast<HWND>(window->winId());
    const HMONITOR monitor=MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST);
    MONITORINFOEXW monitorInfo{};monitorInfo.cbSize=sizeof(monitorInfo);
    if(!monitor||!GetMonitorInfoW(monitor,&monitorInfo))
        return unknown(QStringLiteral("无法识别显示器色彩状态（预览保持 sRGB）"));

    UINT32 pathCount=0,modeCount=0;
    if(GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS,&pathCount,&modeCount)!=ERROR_SUCCESS)
        return unknown(QStringLiteral("无法读取显示器色彩状态（预览保持 sRGB）"));
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(pathCount);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(modeCount);
    if(QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS,&pathCount,paths.data(),&modeCount,modes.data(),nullptr)!=ERROR_SUCCESS)
        return unknown(QStringLiteral("无法读取显示器色彩状态（预览保持 sRGB）"));

    bool matched=false;
    for(const auto& path:paths) {
        DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};
        source.header={DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,sizeof(source),path.sourceInfo.adapterId,path.sourceInfo.id};
        if(DisplayConfigGetDeviceInfo(&source.header)!=ERROR_SUCCESS)continue;
        if(_wcsicmp(source.viewGdiDeviceName,monitorInfo.szDevice)!=0)continue;
        matched=true;
        AdvancedColorInfo2 advanced2{};
        advanced2.header={static_cast<DISPLAYCONFIG_DEVICE_INFO_TYPE>(15),sizeof(advanced2),path.targetInfo.adapterId,path.targetInfo.id};
        const LONG color2=DisplayConfigGetDeviceInfo(&advanced2.header);
        if(color2==ERROR_SUCCESS) {
            if(advanced2.activeColorMode!=0)return {Mode::SystemManaged,{},QStringLiteral("Windows 色彩管理")};
        } else {
            DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO advanced{};
            advanced.header={DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO,sizeof(advanced),path.targetInfo.adapterId,path.targetInfo.id};
            if(DisplayConfigGetDeviceInfo(&advanced.header)!=ERROR_SUCCESS)
                return unknown(QStringLiteral("无法读取显示器色彩状态（预览保持 sRGB）"));
            if(advanced.advancedColorEnabled||advanced.wideColorEnforced)
                return {Mode::SystemManaged,{},QStringLiteral("Windows 色彩管理")};
        }
        break;
    }
    if(!matched)return unknown(QStringLiteral("无法匹配活动显示器（预览保持 sRGB）"));

    HDC dc=CreateDCW(L"DISPLAY",monitorInfo.szDevice,nullptr,nullptr);
    if(!dc)return unknown(QStringLiteral("无法打开显示器 ICC（预览保持 sRGB）"));
    DWORD chars=0;GetICMProfileW(dc,&chars,nullptr);
    std::wstring path(chars,L'\0');
    const BOOL got=chars&&GetICMProfileW(dc,&chars,path.data());
    DeleteDC(dc);
    if(!got)return unknown(QStringLiteral("显示器没有可读 ICC（预览保持 sRGB）"));
    path.resize(chars?chars-1:0);
    QFile file(QString::fromWCharArray(path.c_str()));
    if(!file.open(QIODevice::ReadOnly))return unknown(QStringLiteral("显示器 ICC 无法读取（预览保持 sRGB）"));
    const auto bytes=file.readAll();
    const auto space=QColorSpace::fromIccProfile(bytes);
    if(!space.isValid()||bytes.isEmpty())
        return unknown(QStringLiteral("显示器 ICC 无效（预览保持 sRGB）"));
    return {Mode::MonitorProfile,bytes,QStringLiteral("显示器 ICC")};
#else
    Q_UNUSED(window);
    return {Mode::SystemManaged,{},QStringLiteral("sRGB")};
#endif
}
}
