param(
    [string]$Configuration = "Debug",
    [string]$AppDir = ""
)

$ErrorActionPreference = "Stop"

$LauncherDir = $PSScriptRoot
$ProjectPath = Join-Path $LauncherDir "TacticalRadioLauncher.csproj"

if (-not $AppDir) {
    $AppDir = $LauncherDir
}

& dotnet run `
    --project $ProjectPath `
    --configuration $Configuration `
    -- `
    --app-dir $AppDir

if ($LASTEXITCODE -ne 0) {
    throw "dotnet run failed with exit code $LASTEXITCODE"
}
