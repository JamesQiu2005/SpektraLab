# Download the fixed official LibRaw 0.22.2 release, verify it, and apply the
# tracked Sony ARW 6 / A7 V overlay. No Python needed.
[CmdletBinding()]
param([string]$DependencyDirectory = (Join-Path $PSScriptRoot '..\..\deps'))
$ErrorActionPreference = 'Stop'
$DependencyDirectory = [IO.Path]::GetFullPath($DependencyDirectory)
New-Item -ItemType Directory -Path $DependencyDirectory -Force | Out-Null
$archive = Join-Path $DependencyDirectory 'LibRaw-0.22.2.zip'
$source = Join-Path $DependencyDirectory 'LibRaw-0.22.2'
$overlay = Join-Path $PSScriptRoot 'third_party\libraw-arw6\files'
$url = 'https://codeload.github.com/LibRaw/LibRaw/zip/refs/tags/0.22.2'
$expected = '02275a04cf0d1477ab9fd7ee231ddea59e7b14497458da6e3ba957517d6655c7'

if (-not (Test-Path -LiteralPath $overlay -PathType Container)) {
    throw "Missing tracked LibRaw ARW 6 overlay: $overlay"
}

$overlayFiles = @{}
foreach ($file in Get-ChildItem -LiteralPath $overlay -File -Recurse) {
    $relative = $file.FullName.Substring($overlay.Length + 1)
    $overlayFiles[$relative] = $file.FullName
}
if ($overlayFiles.Count -eq 0) { throw "The LibRaw ARW 6 overlay is empty: $overlay" }

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

function Get-ZipRelativePath($Entry) {
    $name = $Entry.FullName.Replace('\', '/')
    $slash = $name.IndexOf('/')
    if ($slash -lt 0 -or $slash -eq $name.Length - 1) { return $null }
    $relative = $name.Substring($slash + 1)
    $parts = $relative.Split('/')
    if ($parts -contains '..' -or $relative.StartsWith('/')) {
        throw "Unsafe LibRaw archive path: $($Entry.FullName)"
    }
    return $relative.Replace('/', '\')
}

if (-not (Test-Path -LiteralPath $archive)) { Invoke-WebRequest -Uri $url -OutFile $archive }
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw 'LibRaw archive checksum mismatch; existing files were not extracted or changed.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    # Refuse an existing tree unless every file is either the pinned archive
    # content or the exact tracked overlay. A local LibRaw patch is never
    # silently accepted as the pinned, supported source.
    if (Test-Path -LiteralPath $source) {
        $expectedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $archivePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            if (-not $entry.Name) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $DependencyDirectory $entry.FullName))
            if (-not $target.StartsWith($source + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and $target.TrimEnd('\') -ne $source) {
                throw 'Unsafe LibRaw archive path'
            }
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Incomplete LibRaw source tree: $target" }
            [void]$expectedPaths.Add($target)
            $relative = Get-ZipRelativePath $entry
            if ($null -ne $relative) { [void]$archivePaths.Add($relative) }
            $actual = Get-FileSha256 $target
            $archiveDigest = Get-ZipEntrySha256 $entry
            $overlayTarget = if ($null -ne $relative -and $overlayFiles.ContainsKey($relative)) { $overlayFiles[$relative] } else { $null }
            if ($actual -ne $archiveDigest -and
                ($null -eq $overlayTarget -or $actual -ne (Get-FileSha256 $overlayTarget))) {
                throw "Modified LibRaw source file: $target. Existing files were not overwritten."
            }
        }
        foreach ($relative in $overlayFiles.Keys) {
            $target = Join-Path $source $relative
            [void]$expectedPaths.Add($target)
            # Files that also exist in the archive were checked above, allowing
            # either pristine archive content or this exact overlay.
            if ($archivePaths.Contains($relative)) { continue }
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                if ((Get-FileSha256 $target) -ne (Get-FileSha256 $overlayFiles[$relative])) {
                    throw "Modified LibRaw overlay file: $target. Existing files were not overwritten."
                }
            } elseif (Test-Path -LiteralPath $target) {
                throw "Unexpected non-file at LibRaw overlay path: $target"
            }
        }
        foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse) {
            if (-not $expectedPaths.Contains($file.FullName)) { throw "Unexpected file in pinned LibRaw source: $($file.FullName)" }
        }
    } else {
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $DependencyDirectory)
    }

    # Apply the overlay every run: it is idempotent and also upgrades a tree
    # that was extracted before this fix existed.
    foreach ($relative in $overlayFiles.Keys) {
        $target = Join-Path $source $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $overlayFiles[$relative] -Destination $target -Force
    }

    # Verify the complete tree after the overlay, including files that only
    # exist in the overlay.
    $finalPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $zip.Entries) {
        if (-not $entry.Name) { continue }
        $target = [IO.Path]::GetFullPath((Join-Path $DependencyDirectory $entry.FullName))
        [void]$finalPaths.Add($target)
        $relative = Get-ZipRelativePath $entry
        $wanted = if ($null -ne $relative -and $overlayFiles.ContainsKey($relative)) {
            Get-FileSha256 $overlayFiles[$relative]
        } else {
            Get-ZipEntrySha256 $entry
        }
        if ((Get-FileSha256 $target) -ne $wanted) { throw "LibRaw overlay was not applied correctly: $target" }
    }
    foreach ($relative in $overlayFiles.Keys) {
        $target = Join-Path $source $relative
        [void]$finalPaths.Add($target)
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-FileSha256 $target) -ne (Get-FileSha256 $overlayFiles[$relative])) {
            throw "LibRaw overlay was not applied correctly: $target"
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse) {
        if (-not $finalPaths.Contains($file.FullName)) { throw "Unexpected file in pinned LibRaw source: $($file.FullName)" }
    }
} finally { $zip.Dispose() }

Write-Output "LibRaw 0.22.2 + Sony ARW 6 overlay: $source (archive and source verified)."
