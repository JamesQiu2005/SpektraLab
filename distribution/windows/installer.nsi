; Community Windows packaging only. The payload is a verified editor release.
; GPL-3.0-or-later. Original application: JamesQiu2005/SpektraLab.
Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!ifndef PAYLOAD
  !error "Pass /DPAYLOAD=<verified release directory>"
!endif
!ifndef BOOTSTRAP
  !error "Pass /DBOOTSTRAP=<Microsoft-signed WebView2 bootstrapper>"
!endif
!ifndef OUTPUT
  !error "Pass /DOUTPUT=<setup.exe>"
!endif
!ifndef UNINSTALL_LIST
  !error "Pass /DUNINSTALL_LIST=<generated exact-file list>"
!endif
Name "SpektraLab Windows Community"
OutFile "${OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\SpektraLab-Community"
InstallDirRegKey HKCU "Software\SpektraLab-Community" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetDatablockOptimize on
ShowInstDetails show
ShowUninstDetails show
VIProductVersion "1.3.1.1"
VIAddVersionKey /LANG=1033 "ProductName" "SpektraLab Windows Community"
VIAddVersionKey /LANG=1033 "FileDescription" "SpektraLab Windows community installer"
VIAddVersionKey /LANG=1033 "FileVersion" "1.3.1-windows.1"
VIAddVersionKey /LANG=1033 "LegalCopyright" "SpektraLab contributors; GPL-3.0-or-later"
!define MUI_ICON "..\..\desktop\src-tauri\icons\icon.ico"
!define MUI_UNICON "..\..\desktop\src-tauri\icons\icon.ico"
!define MUI_ABORTWARNING
!define MUI_LICENSEPAGE_BUTTON "Install / 安装"
!insertmacro MUI_PAGE_LICENSE "..\..\license\LICENSE"
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\SpektraLab.exe"
!define MUI_FINISHPAGE_RUN_NOTCHECKED
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "This package requires 64-bit Windows. / 此版本需要64位Windows。"
    Abort
  ${EndIf}
  SetShellVarContext current
FunctionEnd

Function DetectWebView
  StrCpy $0 ""
  SetRegView 32
  ReadRegStr $0 HKLM "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  ${If} $0 == ""
  ${OrIf} $0 == "0.0.0.0"
    ReadRegStr $0 HKCU "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  ${EndIf}
  SetRegView 64
FunctionEnd

Section "SpektraLab" MainSection
  SetShellVarContext current
  Call DetectWebView
  ${If} $0 == ""
  ${OrIf} $0 == "0.0.0.0"
    InitPluginsDir
    SetOutPath "$PLUGINSDIR"
    File /oname=MicrosoftEdgeWebview2Setup.exe "${BOOTSTRAP}"
    DetailPrint "Installing Microsoft WebView2 (network required) / 正在安装微软WebView2（需要联网）"
    ExecWait '"$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe" /silent /install' $1
    Call DetectWebView
    ${If} $0 == ""
    ${OrIf} $0 == "0.0.0.0"
      MessageBox MB_OK|MB_ICONSTOP "WebView2 installation did not finish. Check your network, install the runtime from Microsoft, then run this installer again. / WebView2未安装成功，请检查网络并从微软安装运行时后重试。" /SD IDOK
      SetErrorLevel 2
      Abort
    ${EndIf}
  ${EndIf}
  DetailPrint "WebView2: $0"
  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD}\*.*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\SpektraLab Windows Community"
  CreateShortcut "$SMPROGRAMS\SpektraLab Windows Community\SpektraLab.lnk" "$INSTDIR\SpektraLab.exe"
  CreateShortcut "$SMPROGRAMS\SpektraLab Windows Community\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\SpektraLab Windows Community.lnk" "$INSTDIR\SpektraLab.exe"
  WriteRegStr HKCU "Software\SpektraLab-Community" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SpektraLab-Community" "DisplayName" "SpektraLab Windows Community"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SpektraLab-Community" "DisplayVersion" "1.3.1-windows.1"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SpektraLab-Community" "Publisher" "SpektraLab contributors / LUOJW5566 community build"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SpektraLab-Community" "URLInfoAbout" "https://github.com/LUOJW5566/SpektraLab"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SpektraLab-Community" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SpektraLab-Community" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SpektraLab-Community" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SpektraLab-Community" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  ; Exact payload files only: never recursively delete photographs or settings.
  !include "${UNINSTALL_LIST}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$DESKTOP\SpektraLab Windows Community.lnk"
  Delete "$SMPROGRAMS\SpektraLab Windows Community\SpektraLab.lnk"
  Delete "$SMPROGRAMS\SpektraLab Windows Community\Uninstall.lnk"
  RMDir "$SMPROGRAMS\SpektraLab Windows Community"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SpektraLab-Community"
  DeleteRegKey HKCU "Software\SpektraLab-Community"
  ; Intentionally retain the app's existing sidecars/preferences and WebView2.
SectionEnd
