# Build-time sources only; fixed releases and SHA256, no dependency DLLs.
[CmdletBinding()]
param([string]$DependencyDirectory = (Join-Path $PSScriptRoot '..\build\deps\export-codecs'))
$ErrorActionPreference = 'Stop'
$DependencyDirectory = [IO.Path]::GetFullPath($DependencyDirectory)
New-Item -ItemType Directory -Path $DependencyDirectory -Force | Out-Null
$pins = @(
    @('libjpeg-turbo-3.2.0', 'libjpeg-turbo-3.2.0.tar.gz', 'https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz', '6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e'),
    @('libpng-1.6.59', 'libpng-1.6.59.tar.xz', 'https://download.sourceforge.net/libpng/libpng-1.6.59.tar.xz', 'd80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389'),
    @('zlib-ng-2.3.3', 'zlib-ng-2.3.3.tar.gz', 'https://codeload.github.com/zlib-ng/zlib-ng/tar.gz/refs/tags/2.3.3', 'f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1'),
    @('nasm-2.16.03', 'nasm-2.16.03-win64.zip', 'https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/win64/nasm-2.16.03-win64.zip', '3ee4782247bcb874378d02f7eab4e294a84d3d15f3f6ee2de2f47a46aa7226e6')
)
foreach ($pin in $pins) {
    $archive = Join-Path $DependencyDirectory $pin[1]
    if (-not (Test-Path -LiteralPath $archive)) { Invoke-WebRequest -Uri $pin[2] -OutFile $archive }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin[3]) {
        throw "Codec checksum mismatch: $archive. Nothing extracted."
    }
    $temp = Join-Path $DependencyDirectory ('.verify-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $entries = & tar -tf $archive
        if ($LASTEXITCODE) { throw "Cannot list $archive" }
        foreach ($entry in $entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $temp $entry))
            if (-not $target.StartsWith($temp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe codec archive path' }
        }
        & tar -xf $archive -C $temp
        if ($LASTEXITCODE) { throw "Cannot extract $archive" }
        $fresh = Join-Path $temp $pin[0]
        $source = Join-Path $DependencyDirectory $pin[0]
        if (Test-Path -LiteralPath $source) {
            $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($file in Get-ChildItem -LiteralPath $fresh -File -Recurse -Force) {
                $relative = $file.FullName.Substring($fresh.Length + 1)
                [void]$expected.Add($relative)
                $existing = Join-Path $source $relative
                if (-not (Test-Path -LiteralPath $existing -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $existing -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
                    throw "Modified or incomplete codec source: $existing. Existing files not overwritten."
                }
            }
            foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force) {
                if (-not $expected.Contains($file.FullName.Substring($source.Length + 1))) { throw "Unexpected codec source file: $($file.FullName)" }
            }
        } else {
            # Both resolved paths are checked against the explicitly chosen dependency directory.
            if (-not ([IO.Path]::GetFullPath($fresh)).StartsWith($DependencyDirectory + [IO.Path]::DirectorySeparatorChar) -or
                -not ([IO.Path]::GetFullPath($source)).StartsWith($DependencyDirectory + [IO.Path]::DirectorySeparatorChar)) { throw 'Unsafe codec move' }
            Move-Item -LiteralPath $fresh -Destination $source
        }
    } finally {
        $resolvedTemp = [IO.Path]::GetFullPath($temp)
        if (-not $resolvedTemp.StartsWith($DependencyDirectory + [IO.Path]::DirectorySeparatorChar) -or
            -not ([IO.Path]::GetFileName($resolvedTemp)).StartsWith('.verify-')) { throw 'Unsafe temporary codec cleanup' }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
    Write-Output "$($pin[0]): archive and source verified."
}
