[CmdletBinding()]
param(
    [string]$SourceDirectory = (Split-Path $PSScriptRoot -Parent),
    [string]$BuildDirectory,
    [string]$DependencyDirectory,
    [string]$VsDevCmd = 'E:\Software\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat',
    [string]$QtDirectory,
    [ValidateSet('Release', 'RelWithDebInfo', 'Debug')][string]$Configuration = 'Release',
    [switch]$RunTests,
    [switch]$Fresh,
    [switch]$NoDeploy,
    [switch]$KeepGoing,
    [switch]$Package,
    [ValidateRange(0, 64)][int]$Jobs = 0
)
# MSVC 2022 build of the engine and the Qt Quick editor. Everything it needs
# lives in -DependencyDirectory (default: ../deps beside the checkout):
#   qt-6.11.3-msvc2022_64/   official Qt archives, msvc2022_64
#   Vulkan-Headers/          Khronos headers, tag vulkan-sdk-1.4.341.0
#   glslang-16.6.0/          Khronos release build (bin/glslang.exe)
#   LibRaw-0.22.2/           engine/setup-libraw.ps1
#   qt-6.11.3-licenses/      dependencies/qt-licenses.json (optional; warned)
# The Visual Studio environment is imported into this process only; PATH and
# the rest of the environment are restored on exit.
# -Package (Release, deployed) zips the app folder, after the tests when
# -RunTests is given, into <build>/package/SpektraLab-Windows-<version>-x64.zip.
$ErrorActionPreference = 'Stop'
if ($Package -and ($Configuration -ne 'Release' -or $NoDeploy)) {
    throw '-Package needs a deployed Release build: drop -NoDeploy and use -Configuration Release.'
}
$SourceDirectory = [IO.Path]::GetFullPath($SourceDirectory)
if (-not (Test-Path -LiteralPath (Join-Path $SourceDirectory 'engine/CMakeLists.txt'))) {
    throw 'Set -SourceDirectory to the source tree containing engine/CMakeLists.txt.'
}
$workspace = Split-Path $SourceDirectory -Parent
if (-not $DependencyDirectory) { $DependencyDirectory = Join-Path $workspace 'deps' }
$DependencyDirectory = [IO.Path]::GetFullPath($DependencyDirectory)
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $workspace "build/msvc-$($Configuration.ToLowerInvariant())" }
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)
if (-not $QtDirectory) { $QtDirectory = Join-Path $DependencyDirectory 'qt-6.11.3-msvc2022_64' }
$QtDirectory = [IO.Path]::GetFullPath($QtDirectory)
$vulkanHeaders = Join-Path $DependencyDirectory 'Vulkan-Headers/include'
$glslang = Join-Path $DependencyDirectory 'glslang-16.6.0/bin/glslang.exe'
$libraw = Join-Path $DependencyDirectory 'LibRaw-0.22.2'
foreach ($file in @($VsDevCmd, "$QtDirectory/bin/windeployqt.exe", "$QtDirectory/lib/cmake/Qt6/Qt6Config.cmake",
                    "$vulkanHeaders/vulkan/vulkan_core.h", $glslang, "$libraw/libraw/libraw.h")) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing local dependency: $file" }
}

# Windows PowerShell turns a native tool's stderr into a terminating error
# under ErrorActionPreference=Stop, even when the tool succeeds (windeployqt
# warns on stderr). Run tools with Continue and judge them by exit code only.
function Invoke-Tool([string]$Executable, [string[]]$Arguments, [string]$What) {
    $ErrorActionPreference = 'Continue'
    & $Executable @Arguments 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "$What failed: exit code $LASTEXITCODE" }
}

# Import the x64 developer environment from VsDevCmd.bat.
$saved = @{}
Get-ChildItem Env: | ForEach-Object { $saved[$_.Name] = $_.Value }
$dump = & cmd.exe /d /s /c "`"$VsDevCmd`" -arch=amd64 -host_arch=amd64 -no_logo >nul 2>&1 && set"
if ($LASTEXITCODE -ne 0 -or -not ($dump -match '^VCToolsInstallDir=')) { throw "VsDevCmd.bat failed: $VsDevCmd" }
try {
    foreach ($line in $dump) {
        $eq = $line.IndexOf('=')
        if ($eq -gt 0) { [Environment]::SetEnvironmentVariable($line.Substring(0, $eq), $line.Substring($eq + 1), 'Process') }
    }
    # Use the CMake and Ninja that ship with Visual Studio, not whichever one
    # happens to be first on PATH.
    $vsCMake = Join-Path $env:DevEnvDir 'CommonExtensions/Microsoft/CMake'
    $cmake = Join-Path $vsCMake 'CMake/bin/cmake.exe'
    $ctest = Join-Path $vsCMake 'CMake/bin/ctest.exe'
    $ninja = Join-Path $vsCMake 'Ninja/ninja.exe'
    foreach ($tool in @($cmake, $ctest, $ninja)) {
        if (-not (Test-Path -LiteralPath $tool)) { throw "Visual Studio's CMake tools are missing: $tool" }
    }
    $env:PATH = "$QtDirectory/bin;$env:PATH"

    New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null
    $arguments = @('-S', $SourceDirectory, '-B', $BuildDirectory, '-G', 'Ninja',
        "-DCMAKE_MAKE_PROGRAM=$ninja", "-DCMAKE_BUILD_TYPE=$Configuration",
        '-DCMAKE_C_COMPILER=cl.exe', '-DCMAKE_CXX_COMPILER=cl.exe',
        "-DCMAKE_PREFIX_PATH=$QtDirectory", '-DSPEKTRALAB_BUILD_QT=ON', '-DBUILD_TESTING=ON',
        '-DSPEKTRALAB_REQUIRE_VULKAN=ON',
        "-DSPEKTRALAB_DEPS_DIR=$DependencyDirectory",
        "-DSPEKTRALAB_VULKAN_HEADERS=$vulkanHeaders",
        "-DVulkan_INCLUDE_DIR=$vulkanHeaders",
        "-DSPEKTRALAB_GLSLANG=$glslang",
        "-DSPEKTRALAB_LIBRAW_SOURCE=$libraw")
    $arguments = @($arguments | ForEach-Object { $_.Replace('\', '/') })
    if ($Fresh) { $arguments = @('--fresh') + $arguments }
    Invoke-Tool $cmake $arguments 'Configuration'
    $buildArguments = @('--build', $BuildDirectory)
    # 0 lets Ninja use every core; parallel worktree builds pass a share.
    if ($Jobs -gt 0) { $buildArguments += @('--parallel', $Jobs) }
    if (-not $RunTests) { $buildArguments += @('--target', 'SpektraLabQt') }
    if ($KeepGoing) { $buildArguments += @('--', '-k', '0') }
    Invoke-Tool $cmake $buildArguments 'Build'

    $app = Join-Path $BuildDirectory 'app'
    if (-not $NoDeploy) {
        $mode = if ($Configuration -eq 'Debug') { '--debug' } else { '--release' }
        Invoke-Tool "$QtDirectory/bin/windeployqt.exe" @($mode, '--no-translations', '--qmldir', "$PSScriptRoot/qml", "$app/SpektraLabQt.exe") 'Deployment'
        # windeployqt deploys only qwindows; the offscreen plugin serves the
        # --self-test and --snapshot modes.
        Copy-Item -LiteralPath "$QtDirectory/plugins/platforms/qoffscreen.dll" -Destination "$app/platforms/qoffscreen.dll" -Force
        # The MSVC runtime the binaries were linked against, beside them, so the
        # directory runs on a machine without the VC++ redistributable.
        $crt = Get-ChildItem -Path (Join-Path $env:VCToolsRedistDir 'x64') -Directory -Filter 'Microsoft.VC*.CRT' | Select-Object -First 1
        if ($crt -and $Configuration -ne 'Debug') { Copy-Item -Path "$($crt.FullName)/*.dll" -Destination $app -Force }
        New-Item -ItemType Directory -Path "$app/licenses" -Force | Out-Null
        Invoke-Tool $cmake @('-E', 'copy_directory', "$QtDirectory/sbom", "$app/licenses/Qt-SBOM") 'Qt SBOM copy'
        # The binary archives carry no licence texts; the pinned official ones
        # (dependencies/qt-licenses.json, SHA-256 checked when fetched) do.
        $qtLicenses = Join-Path $DependencyDirectory 'qt-6.11.3-licenses'
        if (Test-Path -LiteralPath (Join-Path $qtLicenses 'qtbase/LGPL-3.0-only.txt')) {
            Invoke-Tool $cmake @('-E', 'copy_directory', $qtLicenses, "$app/licenses/Qt") 'Qt licence copy'
            # Each text's source URL and SHA-256, as setup-qt.ps1 leaves them.
            Copy-Item -LiteralPath "$PSScriptRoot/dependencies/qt-licenses.json" -Destination "$app/licenses/Qt/manifest.json" -Force
        } else {
            Write-Warning "Qt licence texts are missing from $qtLicenses; the deployed app lacks Qt's LGPL text."
        }
        foreach ($notice in @('LICENSE.LGPL', 'LICENSE.CDDL', 'COPYRIGHT')) {
            Copy-Item -LiteralPath "$libraw/$notice" -Destination "$app/licenses/LibRaw-$notice" -Force
        }
        Copy-Item -LiteralPath "$PSScriptRoot/THIRD_PARTY.md" -Destination "$app/licenses/THIRD_PARTY.md" -Force
    }
    if ($RunTests) {
        # Tests that need scratch space use the system temp directory; keep
        # every byte they write inside the build tree instead.
        $scratch = Join-Path $BuildDirectory 'tmp'
        New-Item -ItemType Directory -Path $scratch -Force | Out-Null
        $env:TEMP = $scratch; $env:TMP = $scratch
        Invoke-Tool $ctest @('--test-dir', $BuildDirectory, '--output-on-failure') 'CTest'
    }
    Write-Output "Ready: $app\SpektraLabQt.exe"
    if ($Package) {
        # The version is the one the About window shows (CMakeLists.txt's
        # SPEKTRALAB_VERSION, the macOS app's MARKETING_VERSION).
        $cmakeLists = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'CMakeLists.txt') -Raw
        if ($cmakeLists -notmatch 'set\(SPEKTRALAB_VERSION "([^"]+)"\)') { throw 'SPEKTRALAB_VERSION not found in windows_UI/CMakeLists.txt.' }
        $name = "SpektraLab-Windows-$($Matches[1])-x64"
        $packageDirectory = Join-Path $BuildDirectory 'package'
        $stage = Join-Path $packageDirectory $name
        $zip = Join-Path $packageDirectory "$name.zip"
        foreach ($old in @($stage, $zip)) {
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
        }
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        # app/ holds only the executable and what windeployqt and this script
        # put beside it: test binaries live elsewhere in the build tree, and the
        # edit store, folder orders and preferences live under the user's
        # AppData. The filters below keep it that way if that ever changes.
        # vc_redist.x64.exe is left out: the runtime DLLs are already beside
        # the executable.
        $excludedFiles = @('vc_redist.x64.exe', '*.pdb', '*.ilk', '*.exp', '*.lib', 'spk_*.exe', '*_test.exe',
                           '*.spektra.json', '*.order.json', 'settings*.json', '*.ini', '*.log')
        $excludedDirectories = @('Edits', 'Order', 'Recipes', 'tmp')
        Get-ChildItem -LiteralPath $app -Recurse -File | ForEach-Object {
            $relative = $_.FullName.Substring($app.Length + 1)
            $parts = $relative.Split([IO.Path]::DirectorySeparatorChar)
            $skipFile = $false
            foreach ($pattern in $excludedFiles) { if ($_.Name -like $pattern) { $skipFile = $true } }
            if ($parts.Length -gt 1) {
                foreach ($directory in $parts[0..($parts.Length - 2)]) { if ($excludedDirectories -contains $directory) { $skipFile = $true } }
            }
            if (-not $skipFile) {
                $target = Join-Path $stage $relative
                New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $_.FullName -Destination $target
            }
        }
        # What the folder cannot run or be distributed without.
        foreach ($required in @('SpektraLabQt.exe', 'Qt6Core.dll', 'Qt6Quick.dll', 'platforms/qwindows.dll',
                                'qml/QtQuick/Controls', 'vcruntime140.dll', 'msvcp140.dll',
                                'resources/vulkan/spk_affine3.spv', 'resources/spektrafilm_constants.bin',
                                'resources/profiles/kodak_portra_400.json',
                                'resources/profiles/kodak_tri_x_400.json', 'resources/fonts/texgyreheros-regular.otf',
                                'resources/io/sRGB.icc', 'licenses/LICENSE', 'licenses/SPEKTRAFILM_LICENSE.txt',
                                'licenses/THIRD_PARTY.md', 'licenses/LibRaw-LICENSE.LGPL', 'licenses/Qt-SBOM')) {
            if (-not (Test-Path -LiteralPath (Join-Path $stage $required))) { throw "Package is missing $required" }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $stage 'licenses/Qt/qtbase/LGPL-3.0-only.txt'))) {
            Write-Warning 'The package lacks Qt''s licence texts (see the deployment warning above); do not distribute it.'
        }
        # Entry by entry: Windows PowerShell's ZipFile.CreateFromDirectory
        # writes backslash separators, which the zip format does not allow and
        # other unzippers turn into file names.
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in $files) {
                $entry = "$name/" + $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal)
            }
        } finally { $archive.Dispose() }
        $bytes = (Get-Item -LiteralPath $zip).Length
        Write-Output ("Package: {0} ({1:N1} MB, {2} files)" -f $zip, ($bytes / 1MB), $files.Count)
    }
} finally {
    foreach ($name in @(Get-ChildItem Env: | ForEach-Object Name)) {
        if (-not $saved.ContainsKey($name)) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
