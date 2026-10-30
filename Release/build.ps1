param(
    [Parameter(Mandatory)][string]$Version,
    [string]$MumbleRepo = '',
    [string]$MumbleBuildDir = '',
    [string]$Configuration = 'Release',
    [switch]$SkipMumbleBuild,
    [switch]$SkipPluginBuild,
    [switch]$AllowDirty
)
. "$PSScriptRoot/scripts/Common.ps1"
. "$PSScriptRoot/config.ps1"
Assert-Version $Version
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $MumbleRepo) { $MumbleRepo = Join-Path (Split-Path $root -Parent) 'TRS-Mumble' }
$MumbleRepo = (Resolve-Path $MumbleRepo).Path
if (-not $MumbleBuildDir) { $MumbleBuildDir = Join-Path $MumbleRepo 'build-2026' }
$MumbleBuildDir = (Resolve-Path $MumbleBuildDir).Path
if (-not $AllowDirty) {
    if (-not (Test-GitClean $root)) { throw 'TacticalRadioSoftware has uncommitted tracked changes. Commit them or use -AllowDirty.' }
    if (-not (Test-GitClean $MumbleRepo)) { throw 'TRS-Mumble has uncommitted tracked changes. Commit them or use -AllowDirty.' }
}
$dist = Join-Path $root 'dist'
$portable = Join-Path $dist 'portable/TRS-Mumble'
$out = Join-Path $dist 'installer'
New-Item -ItemType Directory -Path $out -Force | Out-Null
& "$PSScriptRoot/scripts/BuildMumble.ps1" -Repo $MumbleRepo -BuildDir $MumbleBuildDir -Configuration $Configuration -SkipBuild:$SkipMumbleBuild
if (-not $?) { throw 'Mumble build failed' }
$pluginDll = Join-Path $root "apps/mumble-plugin/build/$Configuration/tactical_radio_mumble_plugin.dll"
& "$PSScriptRoot/scripts/BuildPlugin.ps1" -Repo $root -Configuration $Configuration -SkipBuild:$SkipPluginBuild | Out-Host
if (-not $?) { throw 'Plugin build failed' }
& "$PSScriptRoot/scripts/StageDistribution.ps1" -MumbleBuildDir $MumbleBuildDir -PluginDll $pluginDll -Destination $portable -Version $Version
& "$PSScriptRoot/scripts/ValidateDistribution.ps1" -Distribution $portable
$iscc = Resolve-InnoCompiler
$installer = Join-Path $out "TacticalRadioSetup-$Version.exe"
Invoke-Tool $iscc @("/DAppVersion=$Version", "/DSourceDir=$portable", "/DOutputDir=$out", "/DOutputBaseName=TacticalRadioSetup-$Version", (Join-Path $PSScriptRoot 'installer/TRS-Mumble.iss'))
Assert-File $installer
$manifest = Join-Path $out "TacticalRadioSetup-$Version.manifest.json"
& "$PSScriptRoot/scripts/GenerateManifest.ps1" -Version $Version -Root $root -MumbleRepo $MumbleRepo -Distribution $portable -Installer $installer -Output $manifest
Write-Host "READY FOR TESTING: $installer"
Write-Host "MANIFEST: $manifest"
