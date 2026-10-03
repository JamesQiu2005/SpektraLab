# Download a fixed official release, verify before extraction. No Python needed.
[CmdletBinding()]
param([string]$DependencyDirectory = (Join-Path $PSScriptRoot '..\..\deps'))
$ErrorActionPreference = 'Stop'
$DependencyDirectory = [IO.Path]::GetFullPath($DependencyDirectory)
New-Item -ItemType Directory -Path $DependencyDirectory -Force | Out-Null
$archive = Join-Path $DependencyDirectory 'LibRaw-0.22.2.zip'
$source = Join-Path $DependencyDirectory 'LibRaw-0.22.2'
$url = 'https://codeload.github.com/LibRaw/LibRaw/zip/refs/tags/0.22.2'
$expected = '02275a04cf0d1477ab9fd7ee231ddea59e7b14497458da6e3ba957517d6655c7'
if (-not (Test-Path -LiteralPath $archive)) { Invoke-WebRequest -Uri $url -OutFile $archive }
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw 'LibRaw archive checksum mismatch; existing files were not extracted or changed.'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($entry in $zip.Entries) {
        $target = [IO.Path]::GetFullPath((Join-Path $DependencyDirectory $entry.FullName))
        if (-not $target.StartsWith($source + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and $target.TrimEnd('\') -ne $source) {
            throw 'Unsafe LibRaw archive path'
        }
    }
    if (Test-Path -LiteralPath $source) {
        $expectedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            if (-not $entry.Name) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $DependencyDirectory $entry.FullName))
            [void]$expectedPaths.Add($target)
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Incomplete LibRaw source tree: $target" }
            $stream = $entry.Open()
            $hasher = [Security.Cryptography.SHA256]::Create()
            try { $digest = [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
            finally { $hasher.Dispose(); $stream.Dispose() }
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $digest) {
                throw "Modified LibRaw source file: $target. Existing files were not overwritten."
            }
        }
        foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse) {
            if (-not $expectedPaths.Contains($file.FullName)) { throw "Unexpected file in pinned LibRaw source: $($file.FullName)" }
        }
    }
} finally { $zip.Dispose() }
if (-not (Test-Path -LiteralPath $source)) { [IO.Compression.ZipFile]::ExtractToDirectory($archive, $DependencyDirectory) }
Write-Output "LibRaw 0.22.2: $source (archive SHA256 and existing source verified)."
