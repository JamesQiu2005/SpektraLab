[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DependencyDirectory,
    [string]$GitHubEnvironmentFile
)

$ErrorActionPreference = 'Stop'
$deps = [IO.Path]::GetFullPath($DependencyDirectory)
New-Item -ItemType Directory -Force -Path $deps | Out-Null

function Get-PinnedZip {
    param([string]$Url, [string]$Name, [string]$Sha)
    $zip = Join-Path $deps $Name
    if ((Test-Path -LiteralPath $zip) -and
        ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Sha)) {
        return $zip
    }
    $partial = "$zip.$([guid]::NewGuid().ToString('N')).partial"
    try {
        Write-Host "Downloading pinned $Name"
        & curl.exe --fail --location --silent --show-error --retry 2 --connect-timeout 25 --max-time 240 --retry-max-time 240 --output $partial $Url
        if ($LASTEXITCODE -ne 0) { throw "Download of $Name exited $LASTEXITCODE" }
        $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $Sha) { throw "checksum mismatch for $Url : expected $Sha, got $actual" }
        Move-Item -LiteralPath $partial -Destination $zip -Force
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
    return $zip
}

$cmakeHome = Join-Path $deps 'cmake-3.31.6-windows-x86_64'
if (!(Test-Path -LiteralPath (Join-Path $cmakeHome 'bin/cmake.exe') -PathType Leaf) -or
    !(Test-Path -LiteralPath (Join-Path $cmakeHome 'bin/ctest.exe') -PathType Leaf)) {
    $zip = Get-PinnedZip 'https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-windows-x86_64.zip' 'cmake-3.31.6-windows-x86_64.zip' 'd163cd3ab4959b0a53fa8988f2ddbd2e6c501658201e6a154386bad9dbe4f836'
    Expand-Archive -LiteralPath $zip -DestinationPath $deps -Force
}

$glslangHome = Join-Path $deps 'glslang-16.6.0'
if (-not (Test-Path -LiteralPath (Join-Path $glslangHome 'bin/glslang.exe'))) {
    $zip = Get-PinnedZip 'https://github.com/KhronosGroup/glslang/releases/download/16.6.0/glslang-16.6.0-windows-x86_64-release.zip' 'glslang-16.6.0-windows-x86_64-release.zip' '82bf434e69b9bb4829de7e2b4bc2c5e7a7861e53d66cf75e5cc70f5f694a8d9b'
    Expand-Archive -LiteralPath $zip -DestinationPath $glslangHome -Force
}

$vkHeaders = Join-Path $deps 'Vulkan-Headers'
if (-not (Test-Path -LiteralPath $vkHeaders)) {
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch vulkan-sdk-1.4.341.0 https://github.com/KhronosGroup/Vulkan-Headers.git $vkHeaders
    if ($LASTEXITCODE) { throw "Vulkan-Headers clone exited $LASTEXITCODE" }
}
$identity = @(git -C $vkHeaders rev-parse HEAD 'HEAD^{tree}')
if ($LASTEXITCODE -ne 0 -or $identity.Count -ne 2 -or
    $identity[0] -ne 'b5c8f996196ba4aa6d8f97e52b5d3b6e70f7e4e2' -or
    $identity[1] -ne '5ae5f51f37c6a7f597df2b9ec45b46d3ab573b1d') {
    throw "Vulkan-Headers does not match the pinned commit and tree: $($identity -join ', ')"
}
$changes = @(git -C $vkHeaders status --porcelain)
if ($LASTEXITCODE -ne 0 -or $changes.Count -ne 0) {
    throw "Vulkan-Headers cache contains local changes: $vkHeaders"
}

& (Join-Path $PSScriptRoot '../../engine/setup-libraw.ps1') -DependencyDirectory $deps
$librawHome = Join-Path $deps 'LibRaw-42f89c165763272a5482a254c446337f8048e0df'
$outputs = [ordered]@{
    SPK_CMAKE = Join-Path $cmakeHome 'bin/cmake.exe'
    SPK_CTEST = Join-Path $cmakeHome 'bin/ctest.exe'
    SPK_GLSLANG = Join-Path $glslangHome 'bin/glslang.exe'
    SPK_VULKAN_HEADERS = Join-Path $vkHeaders 'include'
    SPK_LIBRAW_SOURCE = $librawHome
}
$expectedFiles = @($outputs.SPK_CMAKE, $outputs.SPK_CTEST, $outputs.SPK_GLSLANG,
    (Join-Path $outputs.SPK_VULKAN_HEADERS 'vulkan/vulkan.h'), (Join-Path $librawHome 'libraw/libraw.h'))
foreach ($file in $expectedFiles) {
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Incomplete MSVC tool cache: $file"
    }
}
if ($GitHubEnvironmentFile) {
    foreach ($entry in $outputs.GetEnumerator()) {
        "$($entry.Key)=$($entry.Value)" | Add-Content -LiteralPath $GitHubEnvironmentFile -Encoding utf8
    }
}
Get-ChildItem -LiteralPath $deps -Directory | Select-Object -ExpandProperty Name
