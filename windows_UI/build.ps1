[CmdletBinding()]
param(
    [string]$SourceDirectory = (Split-Path $PSScriptRoot -Parent),
    [string]$BuildDirectory = (Join-Path $PSScriptRoot '.build'),
    [string]$DependencyDirectory,
    [ValidateRange(1,32)][int]$Jobs = 4,
    [switch]$RunTests,
    [switch]$Fresh
)
$ErrorActionPreference = 'Stop'
$SourceDirectory = [IO.Path]::GetFullPath($SourceDirectory)
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)
if (-not (Test-Path -LiteralPath (Join-Path $SourceDirectory 'engine/CMakeLists.txt'))) {
    throw 'Set -SourceDirectory to the source tree containing engine/CMakeLists.txt.'
}
if (-not $DependencyDirectory) { $DependencyDirectory = Join-Path (Split-Path $SourceDirectory -Parent) 'deps' }
$DependencyDirectory = [IO.Path]::GetFullPath($DependencyDirectory)
$qt = Join-Path $DependencyDirectory 'qt-6.11.3/mingw_64'
$compiler = Join-Path $DependencyDirectory 'qt-6.11.3/Tools/mingw1310_64/bin'
$cmake = Join-Path $DependencyDirectory 'cmake-3.25.0-windows-x86_64/bin/cmake.exe'
$ctest = Join-Path $DependencyDirectory 'cmake-3.25.0-windows-x86_64/bin/ctest.exe'
$libraw = Join-Path $DependencyDirectory 'LibRaw-0.22.2'
$licenseSource = Join-Path $DependencyDirectory 'qt-6.11.3/licenses'
foreach ($file in @($cmake, "$compiler/g++.exe", "$compiler/mingw32-make.exe", "$qt/bin/windeployqt.exe", "$libraw/libraw/libraw.h", "$licenseSource/manifest.json")) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing local dependency: $file" }
}
New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null
$savedPath = $env:PATH
try {
    $env:PATH = "$compiler;$qt/bin;$savedPath"
    $arguments = @('-S', $PSScriptRoot, '-B', $BuildDirectory, '-G', 'MinGW Makefiles',
        '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_CXX_COMPILER=$compiler/g++.exe",
        "-DCMAKE_MAKE_PROGRAM=$compiler/mingw32-make.exe", "-DCMAKE_PREFIX_PATH=$qt",
        "-DSPEKTRALAB_SOURCE_ROOT=$SourceDirectory", '-DBUILD_TESTING=ON',
        '-DSPEKTRALAB_REQUIRE_VULKAN=ON',
        "-DSPEKTRALAB_VULKAN_INCLUDE_DIR=$DependencyDirectory/Vulkan-Headers/include",
        "-DSPEKTRALAB_VULKAN_LIBRARY=$env:WINDIR/System32/vulkan-1.dll",
        "-DSPEKTRALAB_GLSLANG=$DependencyDirectory/glslang-build/StandAlone/glslang.exe",
        "-DSPEKTRALAB_LIBRAW_SOURCE=$libraw")
    # CMake writes compiler paths into generated source. Normalize PowerShell's
    # Windows separators before the first configure, not only on cached builds.
    $arguments = @($arguments | ForEach-Object { $_.Replace('\', '/') })
    if ($Fresh) { $arguments = @('--fresh') + $arguments }
    & $cmake @arguments
    if ($LASTEXITCODE -ne 0) { throw "Configuration failed: $LASTEXITCODE" }
    $buildArguments = @('--build', $BuildDirectory, '--parallel', $Jobs)
    if (-not $RunTests) { $buildArguments += @('--target', 'SpektraLabQt') }
    & $cmake @buildArguments
    if ($LASTEXITCODE -ne 0) { throw "Build failed: $LASTEXITCODE" }
    $app = Join-Path $BuildDirectory 'app'
    & "$qt/bin/windeployqt.exe" --release --compiler-runtime --qmldir "$PSScriptRoot/qml" "$app/SpektraLabQt.exe"
    if ($LASTEXITCODE -ne 0) { throw "Deployment failed: $LASTEXITCODE" }
    # windeployqt intentionally deploys only qwindows; keep the offscreen plugin
    # for the explicit integration-test mode as well.
    Copy-Item -LiteralPath "$qt/plugins/platforms/qoffscreen.dll" -Destination "$app/platforms/qoffscreen.dll" -Force
    # Tests run from engine/, outside the deployed app's DLL directory. Never
    # let a globally installed compiler's different runtime satisfy these DLLs.
    foreach ($runtime in @('libgcc_s_seh-1.dll','libstdc++-6.dll','libwinpthread-1.dll')) {
        Copy-Item -LiteralPath "$compiler/$runtime" -Destination "$BuildDirectory/engine/$runtime" -Force
    }
    & $cmake -E copy_directory $licenseSource "$app/licenses/Qt"
    if ($LASTEXITCODE -ne 0) { throw 'Qt license copy failed' }
    & $cmake -E copy_directory "$qt/sbom" "$app/licenses/Qt-SBOM"
    if ($LASTEXITCODE -ne 0) { throw 'Qt SBOM copy failed' }
    foreach ($component in @('gcc','mingw-w64','winpthreads')) {
        & $cmake -E copy_directory "$compiler/../licenses/$component" "$app/licenses/MinGW/$component"
        if ($LASTEXITCODE -ne 0) { throw "MinGW license copy failed: $component" }
    }
    foreach ($notice in @('LICENSE.LGPL','LICENSE.CDDL','COPYRIGHT')) {
        Copy-Item -LiteralPath "$libraw/$notice" -Destination "$app/licenses/LibRaw-$notice" -Force
    }
    Copy-Item -LiteralPath "$DependencyDirectory/qt-6.11.3-downloads/packages.json" -Destination "$app/licenses/Qt-packages.json" -Force
    Copy-Item -LiteralPath "$PSScriptRoot/THIRD_PARTY.md" -Destination "$app/licenses/THIRD_PARTY.md" -Force
    if ($RunTests) {
        & $ctest --test-dir $BuildDirectory --output-on-failure
        if ($LASTEXITCODE -ne 0) { throw "CTest failed: $LASTEXITCODE" }
    }
    [ordered]@{ qt = '6.11.3'; compiler = 'MinGW-w64 13.1.0 posix-seh';
        source_directory = $SourceDirectory; build_directory = $BuildDirectory;
        utc = [DateTime]::UtcNow.ToString('o'); ctest_run = [bool]$RunTests;
        executable_sha256 = (Get-FileHash -LiteralPath "$app/SpektraLabQt.exe" -Algorithm SHA256).Hash.ToLowerInvariant() } |
        ConvertTo-Json | Set-Content -LiteralPath "$BuildDirectory/qt-build.json" -Encoding UTF8
    Write-Output "Ready: $app/SpektraLabQt.exe"
} finally { $env:PATH = $savedPath }
