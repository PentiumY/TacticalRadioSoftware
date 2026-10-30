param([Parameter(Mandatory)][string]$Repo,[Parameter(Mandatory)][string]$BuildDir,[string]$Configuration='Release',[switch]$SkipBuild)
. "$PSScriptRoot/Common.ps1"
if (-not (Test-Path "$BuildDir/CMakeCache.txt")) { throw "TRS-Mumble is not configured: $BuildDir. Configure CMake first." }
if (-not $SkipBuild) { Invoke-Tool 'cmake' @('--build',$BuildDir,'--config',$Configuration,'--target','mumble','--parallel') }
Assert-File (Join-Path $BuildDir 'mumble.exe')
Write-Host 'TRS-Mumble build verified.'
