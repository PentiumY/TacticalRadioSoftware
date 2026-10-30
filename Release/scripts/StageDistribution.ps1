param([Parameter(Mandatory)][string]$MumbleBuildDir,[Parameter(Mandatory)][string]$PluginDll,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Version)
. "$PSScriptRoot/Common.ps1"
if (Test-Path $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $Destination 'plugins') -Force | Out-Null
$required = @('mumble.exe','libcrypto-3-x64.dll','libssl-3-x64.dll','rnnoise.dll','speexdsp.dll')
foreach ($name in $required) {
    $path = Join-Path $MumbleBuildDir $name
    Assert-File $path
    Copy-Item -LiteralPath $path -Destination $Destination -Force
}
Assert-File $PluginDll
Copy-Item -LiteralPath $PluginDll -Destination (Join-Path $Destination 'plugins/tactical_radio_mumble_plugin.dll') -Force
# Mumble installs may include extra required runtime files; explicitly allow them in the packaging input.
$extras = Join-Path $MumbleBuildDir 'distribution-extra'
if (Test-Path $extras) { Copy-Item -Path "$extras/*" -Destination $Destination -Recurse -Force }
Write-Host "Staged portable application: $Destination"

# Keep the installed Tactical Radio version alongside the executable for update checks.
@{ version = $Version } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'trs-version.json') -Encoding UTF8
