# Reproducible MinGW/Vulkan validation gate. Paths can all be overridden.
[CmdletBinding()]
param(
    [string]$BuildDirectory,
    [string]$CMakeExecutable,
    [string]$CTestExecutable,
    [string]$Compiler,
    [string]$MakeExecutable,
    [string]$VulkanIncludeDirectory,
    [string]$VulkanLibrary,
    [string]$GlslangExecutable,
    [switch]$Fresh,
    [ValidateRange(1, 64)][int]$Jobs = 4
)

$ErrorActionPreference = 'Stop'
$sourceDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspaceDirectory = Split-Path $sourceDirectory -Parent
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $sourceDirectory 'build/windows' }
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null
$manifestPath = Join-Path $BuildDirectory 'toolchain.json'
[ordered]@{ run_id = $runId; timestamp_utc = [DateTime]::UtcNow.ToString('o');
    source_directory = $sourceDirectory; build_directory = $BuildDirectory;
    status = 'preparing'; ctest_passed = $false } |
    ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
trap {
    [ordered]@{ run_id = $runId; timestamp_utc = [DateTime]::UtcNow.ToString('o');
        source_directory = $sourceDirectory; build_directory = $BuildDirectory;
        status = 'failed'; ctest_passed = $false; error = $_.Exception.Message } |
        ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    throw $_
}

function Resolve-Tool([string]$Explicit, [string]$Name, [string[]]$Candidates) {
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) { throw "Missing $Name at $Explicit" }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    $found = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw "Cannot find $Name; pass its executable path explicitly."
}

$cmakeCandidates = @((Join-Path $workspaceDirectory 'deps\cmake-3.25.0-windows-x86_64\bin\cmake.exe'),
    (Join-Path $env:ProgramFiles 'CMake\bin\cmake.exe'))
$matlabDirectory = Join-Path $env:ProgramFiles 'MATLAB'
if (Test-Path -LiteralPath $matlabDirectory -PathType Container) {
    $cmakeCandidates += Get-ChildItem -LiteralPath $matlabDirectory -Directory |
        Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'bin\win64\cmake\bin\cmake.exe' }
}
$CMakeExecutable = Resolve-Tool $CMakeExecutable 'cmake.exe' $cmakeCandidates
$Compiler = Resolve-Tool $Compiler 'g++.exe' @()
$compilerDirectory = Split-Path $Compiler -Parent
$MakeExecutable = Resolve-Tool $MakeExecutable 'mingw32-make.exe' @((Join-Path $compilerDirectory 'mingw32-make.exe'))
$CTestExecutable = Resolve-Tool $CTestExecutable 'ctest.exe' @((Join-Path (Split-Path $CMakeExecutable -Parent) 'ctest.exe'))

$dependencyDirectory = Join-Path $workspaceDirectory 'deps'
if (-not $VulkanIncludeDirectory) {
    $includeCandidates = @((Join-Path $dependencyDirectory 'Vulkan-Headers\include'))
    if ($env:VULKAN_SDK) { $includeCandidates = @((Join-Path $env:VULKAN_SDK 'Include')) + $includeCandidates }
    $VulkanIncludeDirectory = $includeCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'vulkan\vulkan.h') } | Select-Object -First 1
}
if (-not $VulkanIncludeDirectory -or -not (Test-Path -LiteralPath (Join-Path $VulkanIncludeDirectory 'vulkan\vulkan.h'))) {
    throw 'Vulkan headers are missing; pass -VulkanIncludeDirectory.'
}
$VulkanIncludeDirectory = (Resolve-Path -LiteralPath $VulkanIncludeDirectory).Path
if (-not $VulkanLibrary) { $VulkanLibrary = Join-Path $env:WINDIR 'System32\vulkan-1.dll' }
if (-not (Test-Path -LiteralPath $VulkanLibrary -PathType Leaf)) { throw "Missing Vulkan loader: $VulkanLibrary" }
$VulkanLibrary = (Resolve-Path -LiteralPath $VulkanLibrary).Path
$glslangCandidates = @((Join-Path $dependencyDirectory 'glslang-build\StandAlone\glslang.exe'))
if ($env:VULKAN_SDK) { $glslangCandidates = @((Join-Path $env:VULKAN_SDK 'Bin\glslangValidator.exe')) + $glslangCandidates }
$GlslangExecutable = Resolve-Tool $GlslangExecutable 'glslangValidator.exe' $glslangCandidates

# MinGW DLL dependencies must also be discoverable when CTest starts a process.
$previousPath = $env:PATH
try {
    $env:PATH = $compilerDirectory + [IO.Path]::PathSeparator + $previousPath
    New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null
    $configureArguments = @('-S', $sourceDirectory, '-B', $BuildDirectory,
        '-G', 'MinGW Makefiles', '-DCMAKE_BUILD_TYPE=Release',
        "-DCMAKE_CXX_COMPILER=$($Compiler.Replace('\', '/'))", "-DCMAKE_MAKE_PROGRAM=$($MakeExecutable.Replace('\', '/'))",
        '-DBUILD_TESTING=ON', '-DSPEKTRALAB_REQUIRE_VULKAN=ON', '-DSPEKTRALAB_BUILD_TEST_DLL=ON',
        "-DSPEKTRALAB_VULKAN_INCLUDE_DIR=$($VulkanIncludeDirectory.Replace('\', '/'))",
        "-DSPEKTRALAB_VULKAN_LIBRARY=$($VulkanLibrary.Replace('\', '/'))", "-DSPEKTRALAB_GLSLANG=$($GlslangExecutable.Replace('\', '/'))")
    if ($Fresh) { $configureArguments = @('--fresh') + $configureArguments }
    & $CMakeExecutable @configureArguments 2>&1 | Tee-Object -FilePath (Join-Path $BuildDirectory 'configure.log')
    if ($LASTEXITCODE -ne 0) { throw "CMake configuration failed ($LASTEXITCODE)." }
    & $CMakeExecutable --build $BuildDirectory --parallel $Jobs 2>&1 | Tee-Object -FilePath (Join-Path $BuildDirectory 'build.log')
    if ($LASTEXITCODE -ne 0) { throw "Build failed ($LASTEXITCODE)." }
    # Python 3.8+ does not use PATH to resolve DLL dependencies. Keep the
    # compiler's runtime next to the engine, including libstdc++'s pthread DLL.
    $runtimeManifest = @()
    foreach ($runtimeName in @('libgcc_s_seh-1.dll', 'libstdc++-6.dll', 'libwinpthread-1.dll')) {
        $runtimeSource = Join-Path $compilerDirectory $runtimeName
        if (-not (Test-Path -LiteralPath $runtimeSource -PathType Leaf)) {
            throw "Missing x64 MinGW runtime $runtimeSource"
        }
        Copy-Item -LiteralPath $runtimeSource -Destination (Join-Path $BuildDirectory "engine\$runtimeName") -Force
        $runtimeManifest += [ordered]@{ name = $runtimeName; source = $runtimeSource;
            sha256 = (Get-FileHash -LiteralPath $runtimeSource -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    & $CTestExecutable --test-dir $BuildDirectory --output-on-failure 2>&1 | Tee-Object -FilePath (Join-Path $BuildDirectory 'ctest.log')
    if ($LASTEXITCODE -ne 0) { throw "CTest failed ($LASTEXITCODE)." }

    $sourceFiles = @('CMakeLists.txt', 'engine\CMakeLists.txt', 'engine\windows_exports.def', 'engine\build-windows.ps1') |
        ForEach-Object { Get-Item -LiteralPath (Join-Path $sourceDirectory $_) }
    foreach ($subdirectory in @('engine\src', 'engine\include', 'engine\resources', 'engine\tests', 'engine\tools')) {
        $sourceFiles += Get-ChildItem -LiteralPath (Join-Path $sourceDirectory $subdirectory) -File -Recurse |
            Where-Object { $_.FullName -notmatch '[\\/]__pycache__[\\/]' -and $_.Extension -ne '.pyc' }
    }
    $sourceManifest = $sourceFiles | Sort-Object FullName | ForEach-Object {
        [ordered]@{ path = $_.FullName.Substring($sourceDirectory.Length + 1).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $shaderManifest = Get-ChildItem -LiteralPath (Join-Path $BuildDirectory 'engine\resources\vulkan') -Filter '*.spv' -File | Sort-Object Name | ForEach-Object {
        [ordered]@{ path = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $manifest = [ordered]@{
        run_id = $runId
        status = 'passed'
        timestamp_utc = [DateTime]::UtcNow.ToString('o')
        source_directory = $sourceDirectory
        build_directory = $BuildDirectory
        cmake = $CMakeExecutable
        cmake_version = (& $CMakeExecutable --version | Select-Object -First 1)
        compiler = $Compiler
        compiler_version = (& $Compiler --version | Select-Object -First 1)
        make = $MakeExecutable
        vulkan_headers = $VulkanIncludeDirectory
        vulkan_loader = $VulkanLibrary
        vulkan_loader_sha256 = (Get-FileHash -LiteralPath $VulkanLibrary -Algorithm SHA256).Hash.ToLowerInvariant()
        glslang = $GlslangExecutable
        glslang_version = @(& $GlslangExecutable --version)
        glslang_sha256 = (Get-FileHash -LiteralPath $GlslangExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        dll = (Join-Path $BuildDirectory 'engine\spektrafilm_engine.dll')
        dll_sha256 = (Get-FileHash -LiteralPath (Join-Path $BuildDirectory 'engine\spektrafilm_engine.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
        ctest_passed = $true
        mingw_runtime = $runtimeManifest
        source_files = @($sourceManifest)
        spirv = @($shaderManifest)
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-Output "Windows validation build passed. Manifest: $(Join-Path $BuildDirectory 'toolchain.json')"
} finally {
    $env:PATH = $previousPath
}
