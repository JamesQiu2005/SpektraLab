[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$ScratchRoot,
    [string]$Python = 'python',
    [switch]$VerifyDesktop
)

$ErrorActionPreference = 'Stop'
$installerPath = (Get-Item -LiteralPath $Installer).FullName
$artifacts = (Get-Item -LiteralPath $ArtifactDirectory).FullName
$scratch = (Get-Item -LiteralPath $ScratchRoot).FullName
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$config = Get-Content -LiteralPath (Join-Path $repo 'desktop/src-tauri/tauri.windows.conf.json') -Raw | ConvertFrom-Json
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$($config.productName)"
if (Test-Path -LiteralPath $uninstallKey) { throw 'A v2 installation already exists for this Windows account' }

$run = Join-Path $scratch "spk-package-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $run | Out-Null
$install = Join-Path $run 'Installed SpektraLab v2'
$app = Join-Path $install "$($config.mainBinaryName).exe"
$uninstaller = Join-Path $install 'uninstall.exe'
$hello = Join-Path $PSScriptRoot 'host_hello.py'
$cleanupError = $null

function Test-Desktop([string]$Executable, [string]$ProfileName) {
    node (Join-Path $PSScriptRoot 'windows-desktop-smoke.mjs') $Executable (Join-Path $run $ProfileName)
    if ($LASTEXITCODE -ne 0) { throw "Desktop smoke test failed: $Executable" }
}

try {
    Write-Host "Installing $($config.productName) in $install"
    # NSIS requires /D to be the final argument, with no quotes even for spaces.
    $process = Start-Process -FilePath $installerPath -ArgumentList "/S /D=$install" -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { throw "Installer exited $($process.ExitCode)" }
    $entry = Get-ItemProperty -LiteralPath $uninstallKey
    if (!(Test-Path -LiteralPath $app -PathType Leaf) -or !(Test-Path -LiteralPath $uninstaller -PathType Leaf) -or
        $entry.DisplayName -ne $config.productName -or $entry.UninstallString.Trim('"') -ne $uninstaller) {
        throw "Wrong install layout or registration at $install"
    }
    Write-Host "Installed $($config.productName) at $install"
    if ($VerifyDesktop) { Test-Desktop $app 'Installed WebView2' }

    & $Python $hello --host (Join-Path $install 'spektralab-host.exe') --resources (Join-Path $install 'host/engine')
    if ($LASTEXITCODE -ne 0) { throw 'Installed render host failed hello' }

    $helper = Join-Path $install 'spklib-host.exe'
    $vendor = Join-Path $repo 'vendor/spklib/windows-x64'
    $pin = Join-Path $vendor 'spklib-host.exe.sha256'
    $expected = ((Get-Content -LiteralPath $pin -Raw).Trim() -split '\s+')[0]
    if ((Get-FileHash -LiteralPath $helper).Hash -ne $expected) { throw 'Installed library helper hash mismatch' }

    $versionPin = Join-Path $vendor 'VERSION'
    $installedVersion = Join-Path $install 'host/licenses/spklib-VERSION.txt'
    if ((Get-FileHash -LiteralPath $installedVersion).Hash -ne (Get-FileHash -LiteralPath $versionPin).Hash) {
        throw 'Installed library helper version notice mismatch'
    }
    $declared = [regex]::Match((Get-Content -LiteralPath $versionPin -Raw),
        '(?m)^version[ \t]+(\S+)[ \t]+\(abi (\d+), schema (\d+)\)\r?$')
    if (!$declared.Success) { throw 'Could not read the pinned library helper version' }

    $requests = '{"id":1,"method":"sdk.version","params":{}}', '{"id":2,"method":"host.shutdown","params":{}}'
    $replies = $requests | & $helper --store (Join-Path $run 'Test library')
    if ($LASTEXITCODE -ne 0) { throw "Installed library helper exited $LASTEXITCODE" }
    $version = @($replies | ForEach-Object { ConvertFrom-Json -InputObject $_ } | Where-Object id -eq 1)
    if ($version.Count -ne 1 -or $version[0].result.version -cne $declared.Groups[1].Value -or
        $version[0].result.abi -ne [int]$declared.Groups[2].Value -or
        $version[0].result.schema -ne [int]$declared.Groups[3].Value) {
        throw 'Installed library helper identity or protocol differs from the version pin'
    }
    $identity = $version[0].result
    if ($identity.abi -ne 1 -or $identity.schema -ne 3) { throw 'Unexpected library protocol' }
    Write-Host "Installed library helper $($identity.version), ABI $($identity.abi), schema $($identity.schema)"

    $runtimeNotices = Join-Path $install 'host/licenses/windows-v2-runtime-notices.zip'
    $runtimePin = Get-Content -LiteralPath (Join-Path $repo 'license/windows-v2-runtime-notices.json') -Raw | ConvertFrom-Json
    if (!(Test-Path -LiteralPath $runtimeNotices -PathType Leaf) -or
        (Get-FileHash -LiteralPath $runtimeNotices).Hash -ne $runtimePin.archive_sha256) {
        throw 'Installed runtime dependency notice archive is missing or differs from its pin'
    }
    Write-Host 'Installed runtime dependency notices match the source archive'

    node (Join-Path $PSScriptRoot 'windows-portable.mjs') --installed $install --output-root $run
    if ($LASTEXITCODE -ne 0) { throw 'Portable staging failed' }
    $portables = @(Get-ChildItem -LiteralPath $run -Directory -Filter '*-portable')
    if ($portables.Count -ne 1) { throw 'Expected one staged portable directory' }
    $portable = $portables[0]
    $archive = "$($portable.FullName).zip"
    $destination = Join-Path $artifacts "$($portable.Name).zip"
    if (Test-Path -LiteralPath $destination) { throw "Archive already exists: $destination" }
    [IO.Compression.ZipFile]::CreateFromDirectory($portable.FullName, $archive, [IO.Compression.CompressionLevel]::Optimal, $true)

    $extract = Join-Path $run 'Portable 验证'
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extract)
    $payload = Join-Path $extract $portable.Name
    $manifestPath = 'BUILD-MANIFEST.json'
    $manifest = Get-Content -LiteralPath (Join-Path $portable.FullName $manifestPath) -Raw | ConvertFrom-Json
    $manifestHash = (Get-FileHash -LiteralPath (Join-Path $portable.FullName $manifestPath)).Hash
    if ((Get-FileHash -LiteralPath (Join-Path $payload $manifestPath)).Hash -ne $manifestHash) {
        throw 'Portable ZIP manifest hash mismatch'
    }
    $count = @(Get-ChildItem -LiteralPath $payload -Recurse -Force -File).Count
    if ($count -ne ($manifest.files.Count + 1)) { throw "Unexpected portable ZIP file count: $count" }
    foreach ($entry in $manifest.files) {
        $file = Get-Item -LiteralPath (Join-Path $payload $entry.path)
        if ($file.Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $file.FullName).Hash -ne $entry.sha256) {
            throw "Portable ZIP payload mismatch: $($entry.path)"
        }
    }
    Write-Host "Verified $count files in the extracted portable ZIP"
    & $Python $hello --host (Join-Path $payload 'spektralab-host.exe') --resources (Join-Path $payload 'host/engine')
    if ($LASTEXITCODE -ne 0) { throw 'Extracted portable render host failed hello' }
    if ($VerifyDesktop) { Test-Desktop (Join-Path $payload "$($config.mainBinaryName).exe") 'Portable WebView2' }
} finally {
    try {
        if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
            Write-Host "Uninstalling the test copy at $install"
            $removed = Start-Process -FilePath $uninstaller -ArgumentList '/S' -Wait -PassThru -WindowStyle Hidden
            if ($removed.ExitCode -ne 0) { throw "Uninstaller exited $($removed.ExitCode)" }
        }
        if ((Test-Path -LiteralPath $app) -or (Test-Path -LiteralPath $uninstallKey)) {
            throw "V2 uninstall left the app or its registration at $install"
        }
        Write-Host 'Verified installer cleanup'
    } catch {
        $cleanupError = $_
        Write-Warning $cleanupError.ToString()
    }
}
if ($cleanupError) { throw $cleanupError }
Move-Item -LiteralPath $archive -Destination $destination
Write-Host "Verified package: $destination"
