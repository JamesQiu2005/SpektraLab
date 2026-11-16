[CmdletBinding()]
param(
    [string]$DependencyDirectory = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'deps'),
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
$DependencyDirectory = [IO.Path]::GetFullPath($DependencyDirectory)
$manifestPath = Join-Path $PSScriptRoot 'dependencies/glslang.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$cache = Join-Path $DependencyDirectory 'glslang-downloads'
$root = Join-Path $DependencyDirectory "glslang-$($manifest.version)"
$executable = Join-Path $root 'bin/glslang.exe'
$tar = Join-Path $env:WINDIR 'System32/tar.exe'

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
    Invoke-WebRequest -Uri $Url -OutFile "$Path.partial" -UseBasicParsing
    if (-not (Confirm-Hash "$Path.partial" $Hash)) { throw "Download failed: $Url" }
    Move-Item -LiteralPath "$Path.partial" -Destination $Path
}

$archive = Join-Path $cache $manifest.archive.file
Fetch-Verified $manifest.archive.url $archive $manifest.archive.sha256
if (-not $VerifyOnly -and -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $entries = & $tar -tf $archive
    if ($LASTEXITCODE -ne 0) { throw "Cannot list archive: $archive" }
    foreach ($entry in $entries) {
        if ([IO.Path]::IsPathRooted($entry) -or $entry -match '(^|[/\\])\.\.([/\\]|$)' -or $entry -match ':') {
            throw "Unsafe archive entry: $entry"
        }
    }
    & $tar -xf $archive -C $root
    if ($LASTEXITCODE -ne 0) { throw "Extraction failed: $archive" }
}

$license = Join-Path $root $manifest.license.file
Fetch-Verified $manifest.license.url $license $manifest.license.sha256
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $root 'manifest.json') -Force

if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Missing glslang executable: $executable" }
$versionOutput = (& $executable --version 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch "Glslang Version: 11:$([regex]::Escape($manifest.version))") {
    throw "glslang version check failed: $versionOutput"
}
Write-Output "Verified glslang $($manifest.version) ($($manifest.commit)). Dependency root: $DependencyDirectory"
