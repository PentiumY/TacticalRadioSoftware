param([Parameter(Mandatory)][string]$Repo,[string]$Configuration='Release',[switch]$SkipBuild)
. "$PSScriptRoot/Common.ps1"
$buildDir = Join-Path $Repo 'apps/mumble-plugin/build'
if (-not (Test-Path "$buildDir/CMakeCache.txt")) { throw "Radio plugin is not configured: $buildDir. Configure CMake first." }
if (-not $SkipBuild) { Invoke-Tool 'cmake' @('--build',$buildDir,'--config',$Configuration,'--target','tactical_radio_mumble_plugin','--parallel') }
$dll = Join-Path $buildDir "$Configuration/tactical_radio_mumble_plugin.dll"
Assert-File $dll
Write-Output $dll
