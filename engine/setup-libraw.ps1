# Download the one LibRaw source tree the native RAW path is validated against
# and verify it. No Python needed.
#
# The pin is an upstream master checkout, not a release: LibRaw's tags stop at
# 0.22.3, and only master decodes the modern bodies this product needs (Sony
# ARW 6 / A7 V, Canon EOS R6 Mark III, Nikon HE/HE*, Fujifilm GFX 100RF):
#   commit 42f89c165763272a5482a254c446337f8048e0df (0.23.0-Snapshot202611)
#   tree   865b3ac461d5b734e5bc54683e914ff8dd82b7da
#   zip    SHA-256 95a5c092fd12c16359b8a13afac58bf1b4aaad50e27d2c9221f275c496b79ca2
# The archive's SHA-256 is checked before anything is extracted. That SHA-256
# is the same one setup-libraw.sh checks, and setup-libraw.sh also recomputes
# the git tree id from the archive's entries, so this zip is that tree.
#
# An existing tree is verified file by file against the archive and refused --
# never "fixed" -- if any file was added, removed or edited. There is no
# overlay any more (RAW-SUPPORT-20261117.md, "The LibRaw pin").
[CmdletBinding()]
param([string]$DependencyDirectory = (Join-Path $PSScriptRoot '..\..\deps'))
$ErrorActionPreference = 'Stop'
$DependencyDirectory = [IO.Path]::GetFullPath($DependencyDirectory)
New-Item -ItemType Directory -Path $DependencyDirectory -Force | Out-Null

# The pin. engine/cmake/LibRaw.cmake and engine/setup-libraw.sh carry the same
# values; engine/tests/raw_pin_guard.sh fails if they drift apart.
$commit = '42f89c165763272a5482a254c446337f8048e0df'
$tree = '865b3ac461d5b734e5bc54683e914ff8dd82b7da'
$expected = '95a5c092fd12c16359b8a13afac58bf1b4aaad50e27d2c9221f275c496b79ca2'
$name = "LibRaw-$commit"
$url = "https://codeload.github.com/LibRaw/LibRaw/zip/$commit"
$archive = Join-Path $DependencyDirectory "$name.zip"
$source = Join-Path $DependencyDirectory $name

function Get-FileSha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ZipEntrySha256($Entry) {
    $stream = $Entry.Open()
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
    } finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $archive)) {
    $partial = "$archive.partial"
    Invoke-WebRequest -Uri $url -OutFile $partial
    Move-Item -LiteralPath $partial -Destination $archive
}
$actualArchive = Get-FileSha256 $archive
if ($actualArchive -ne $expected) {
    throw "LibRaw archive checksum mismatch ($actualArchive); nothing was extracted or changed."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    # Every entry must sit under the one top-level folder the pin names.
    foreach ($entry in $zip.Entries) {
        $entryName = $entry.FullName.Replace('\', '/')
        $parts = $entryName.TrimEnd('/').Split('/')
        if ($parts[0] -ne $name -or $parts -contains '..' -or $entryName.StartsWith('/')) {
            throw "Unsafe LibRaw archive path: $($entry.FullName)"
        }
    }

    $extracted = $false
    if (-not (Test-Path -LiteralPath $source)) {
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $DependencyDirectory)
        $extracted = $true
    }

    # The tree on disk is the archive, byte for byte, and nothing else.
    $expectedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $zip.Entries) {
        if (-not $entry.Name) { continue }
        $target = [IO.Path]::GetFullPath((Join-Path $DependencyDirectory $entry.FullName))
        if (-not $target.StartsWith($source + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe LibRaw archive path: $($entry.FullName)"
        }
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Incomplete LibRaw source tree: $target" }
        [void]$expectedPaths.Add($target)
        if ((Get-FileSha256 $target) -ne (Get-ZipEntrySha256 $entry)) {
            throw "Modified LibRaw source file: $target. Existing files were not overwritten."
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force) {
        if (-not $expectedPaths.Contains($file.FullName)) { throw "Unexpected file in pinned LibRaw source: $($file.FullName)" }
    }
} finally { $zip.Dispose() }

$how = if ($extracted) { 'archive SHA-256 verified, extracted' } else { 'existing source verified file by file' }
Write-Host "LibRaw $commit (tree $tree): $how."
Write-Output $source
