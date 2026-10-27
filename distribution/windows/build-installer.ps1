[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Payload,
    [Parameter(Mandatory)][string]$MakeNSIS,
    [Parameter(Mandatory)][string]$WebViewBootstrapper,
    [Parameter(Mandatory)][string]$Output
)
$ErrorActionPreference='Stop'
$taskPayload=(Resolve-Path -LiteralPath $Payload).Path
$taskCompiler=(Resolve-Path -LiteralPath $MakeNSIS).Path
$taskBootstrap=(Resolve-Path -LiteralPath $WebViewBootstrapper).Path
$taskOutput=[IO.Path]::GetFullPath($Output)
if(Test-Path -LiteralPath $taskOutput) { throw 'Choose a new installer output; existing releases are never overwritten.' }
$taskSignature=Get-AuthenticodeSignature -LiteralPath $taskBootstrap
if($taskSignature.Status -ne 'Valid' -or $taskSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'A valid Microsoft-signed WebView2 bootstrapper is required.' }
$taskManifest=Get-Content -Raw -LiteralPath (Join-Path $taskPayload 'SHA256SUMS.json') | ConvertFrom-Json
foreach($taskItem in $taskManifest.PSObject.Properties) {
    $taskPath=[IO.Path]::GetFullPath((Join-Path $taskPayload $taskItem.Name))
    if(-not $taskPath.StartsWith($taskPayload+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest path escapes payload.' }
    if((Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLower() -ne $taskItem.Value) { throw "Payload hash mismatch: $($taskItem.Name)" }
}
$taskBuild=Join-Path ([IO.Path]::GetDirectoryName($taskOutput)) 'installer-generated'
New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
$taskFiles=Get-ChildItem -LiteralPath $taskPayload -File -Recurse
if($taskFiles | Where-Object { $_.Extension -match '^\.(arw|nef|cr2|cr3|dng|raw)$' -or $_.Name.StartsWith('.env') }) { throw 'Private inputs or env files must not enter installer.' }
$taskList=[Collections.Generic.List[string]]::new()
foreach($taskFile in $taskFiles) {
    $taskRelative=$taskFile.FullName.Substring($taskPayload.Length+1).Replace('$','$$')
    $taskList.Add('Delete "$INSTDIR\'+$taskRelative+'"')
}
Get-ChildItem -LiteralPath $taskPayload -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    $taskList.Add('RMDir "$INSTDIR\'+$_.FullName.Substring($taskPayload.Length+1).Replace('$','$$')+'"')
}
$taskUninstall=Join-Path $taskBuild 'uninstall-files.nsh'
[IO.File]::WriteAllLines($taskUninstall,$taskList,[Text.UTF8Encoding]::new($false))
Push-Location $PSScriptRoot
try {
    & $taskCompiler /INPUTCHARSET UTF8 "/DPAYLOAD=$taskPayload" "/DBOOTSTRAP=$taskBootstrap" "/DOUTPUT=$taskOutput" "/DUNINSTALL_LIST=$taskUninstall" 'installer.nsi'
    if($LASTEXITCODE -ne 0) { throw 'NSIS compilation failed.' }
} finally { Pop-Location }
@{output=$taskOutput;sha256=(Get-FileHash -LiteralPath $taskOutput -Algorithm SHA256).Hash.ToLower();payload_files=$taskFiles.Count;webview_sha256=(Get-FileHash -LiteralPath $taskBootstrap -Algorithm SHA256).Hash.ToLower();webview_signature='Microsoft Corporation / Valid';scope='current user; no elevation; exact-file uninstaller retains settings and foreign files'} | ConvertTo-Json | Set-Content -LiteralPath ($taskOutput+'.build.json') -Encoding UTF8
Get-Content -LiteralPath ($taskOutput+'.build.json')
