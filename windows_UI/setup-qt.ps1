# Local, pinned bootstrap. No installer, administrator rights or global PATH.
[CmdletBinding()]
param(
    [string]$DependencyDirectory = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'deps'),
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
$DependencyDirectory = [IO.Path]::GetFullPath($DependencyDirectory)
$cache = Join-Path $DependencyDirectory 'qt-6.11.3-downloads'
$qtRoot = Join-Path $DependencyDirectory 'qt-6.11.3'
$sdk = Join-Path $qtRoot 'mingw_64'
$licenses = Join-Path $qtRoot 'licenses'
$packageManifest = Join-Path $PSScriptRoot 'dependencies/qt-packages.json'
$licenseManifest = Join-Path $PSScriptRoot 'dependencies/qt-licenses.json'
$packages = (Get-Content -LiteralPath $packageManifest -Raw | ConvertFrom-Json).packages
$notices = Get-Content -LiteralPath $licenseManifest -Raw | ConvertFrom-Json
$tar = Join-Path $env:WINDIR 'System32/tar.exe'
if (-not (Test-Path -LiteralPath $tar)) { throw 'Windows bsdtar with .7z support is required.' }
function Confirm-Hash([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) {
        throw "SHA256 mismatch: $Path. Existing file has been left in place."
    }
    return $true
}
function Fetch-Verified([string]$Url, [string]$Path, [string]$Hash) {
    if (Confirm-Hash $Path $Hash) { return }
    if ($VerifyOnly) { throw "Missing dependency: $Path" }
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    # TLS validation stays enabled. A failed download remains a .partial file;
    # only a fully verified object becomes part of the local dependency cache.
    Invoke-WebRequest -Uri $Url -OutFile "$Path.partial" -UseBasicParsing
    if (-not (Confirm-Hash "$Path.partial" $Hash)) { throw "Download failed: $Url" }
    Move-Item -LiteralPath "$Path.partial" -Destination $Path
}
foreach ($package in $packages) {
    if ([IO.Path]::GetFileName($package.file) -ne $package.file) { throw 'Unsafe archive name in manifest' }
    $archive = Join-Path $cache $package.file
    Fetch-Verified $package.url $archive $package.sha256
    if ($VerifyOnly) { continue }
    $destination = if ($package.file -eq '13.1.0-202407240918mingw1310.7z') { $qtRoot } else { $sdk }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    # Check all archive paths before extraction, including Windows drive and
    # parent-directory syntax. Packages themselves have pinned hashes above.
    $entries = & $tar -tf $archive
    if ($LASTEXITCODE -ne 0) { throw "Cannot list archive: $archive" }
    foreach ($entry in $entries) {
        if ([IO.Path]::IsPathRooted($entry) -or $entry -match '(^|[/\\])\.\.([/\\]|$)' -or $entry -match ':') {
            throw "Unsafe archive entry: $entry"
        }
    }
    & $tar -xf $archive -C $destination
    if ($LASTEXITCODE -ne 0) { throw "Extraction failed: $archive" }
}
foreach ($notice in $notices) {
    if ($notice.module -notmatch '^qt[a-z]+$' -or [IO.Path]::GetFileName($notice.file) -ne $notice.file) { throw 'Unsafe license name in manifest' }
    Fetch-Verified $notice.url (Join-Path $licenses "$($notice.module)/$($notice.file)") $notice.sha256
}
if (-not $VerifyOnly) {
    Copy-Item -LiteralPath $packageManifest -Destination "$cache/packages.json" -Force
    Copy-Item -LiteralPath $licenseManifest -Destination "$licenses/manifest.json" -Force
}
$qtVersion = & "$sdk/bin/qmake.exe" -query QT_VERSION
if ($LASTEXITCODE -ne 0 -or $qtVersion -ne '6.11.3') { throw 'Qt version check failed' }
$compilerVersion = & "$qtRoot/Tools/mingw1310_64/bin/g++.exe" -dumpfullversion
if ($LASTEXITCODE -ne 0 -or $compilerVersion -ne '13.1.0') { throw 'MinGW compiler version check failed' }
Write-Output "Verified local Qt $qtVersion / MinGW $compilerVersion. Dependency root: $DependencyDirectory"
