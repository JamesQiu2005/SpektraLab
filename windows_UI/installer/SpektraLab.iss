; SpektraLab's Windows installer (Inno Setup 6). build-msvc.ps1 -Installer
; compiles it from the same staged folder the -Package zip is made of:
;
;   ISCC.exe /DAppVersion=1.3.3 /DSourceDir=<stage> /DOutputDir=<dir> SpektraLab.iss
;
; Per user without administrator rights by default (%LOCALAPPDATA%\Programs),
; or for all users (Program Files) when chosen in the first page. The MSVC
; runtime is app-local in the folder, so nothing else is installed. Edits,
; folder orders, recipes and preferences live under the user's AppData and
; are left in place by the uninstaller, as a reinstall expects them.

#ifndef AppVersion
  #error Pass /DAppVersion=<version> (build-msvc.ps1 -Installer does).
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<staged app folder> (build-msvc.ps1 -Installer does).
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
; Never change AppId: it is how an upgrade finds the installed copy.
AppId={{A1C3249B-36BE-4BC8-A969-856FB1ABFE26}
AppName=SpektraLab
AppVersion={#AppVersion}
AppVerName=SpektraLab {#AppVersion}
AppPublisher=SpektraLab contributors
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\SpektraLab
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
SetupIconFile=..\resources\SpektraLab.ico
UninstallDisplayIcon={app}\SpektraLabQt.exe
UninstallDisplayName=SpektraLab {#AppVersion}
OutputDir={#OutputDir}
OutputBaseFilename=SpektraLab-Windows-{#AppVersion}-x64-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; A running SpektraLab is asked to close (Restart Manager) before files change.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; An upgrade replaces these whole, so no QML or engine data of an older
; version is left beside the new.
Type: filesandordirs; Name: "{app}\qml"
Type: filesandordirs; Name: "{app}\resources"
Type: filesandordirs; Name: "{app}\licenses"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\SpektraLab"; Filename: "{app}\SpektraLabQt.exe"
Name: "{autodesktop}\SpektraLab"; Filename: "{app}\SpektraLabQt.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\SpektraLabQt.exe"; Description: "{cm:LaunchProgram,SpektraLab}"; Flags: nowait postinstall skipifsilent
