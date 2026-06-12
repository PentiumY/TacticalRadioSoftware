param(
    [string]$Version = "1.0.1",
    [string]$Configuration = "Release",
    [string]$PluginReleaseDir = "",
    [switch]$SkipNpmBuild,
    [switch]$SkipNativeBuild,
    [switch]$SkipPluginBuild,
    [switch]$SkipLauncherBuild,
    [switch]$Sign,
    [string]$CertificatePath = "",
    [string]$CertificatePassword = "",
    [string]$CertificateThumbprint = "",
    [switch]$UseMachineStore,
    [string]$SignToolPath = "",
    [string]$TimestampUrl = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = $PSScriptRoot
. (Join-Path $Root "installer\scripts\Common.ps1")

function Assert-DotNetSdk {
    $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue

    if (-not $dotnetCommand) {
        throw @"
dotnet was not found.

Install the .NET 8 SDK, then reopen PowerShell:

    winget install -e --id Microsoft.DotNet.SDK.8
"@
    }

    $sdkList = & dotnet --list-sdks 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $sdkList) {
        throw @"
dotnet exists, but no .NET SDK is installed or visible on PATH.

Install the .NET 8 SDK, then reopen PowerShell:

    winget install -e --id Microsoft.DotNet.SDK.8

If you already installed it, close and reopen PowerShell so PATH refreshes.
"@
    }

    $hasNet8Sdk = $false

    foreach ($sdk in $sdkList) {
        if ($sdk -match "^8\.") {
            $hasNet8Sdk = $true
            break
        }
    }

    if (-not $hasNet8Sdk) {
        Write-Warning "Installed .NET SDKs:"
        $sdkList | ForEach-Object {
            Write-Warning "  $_"
        }

        throw @"
The WinUI 3 launcher project targets .NET 8.

Install the .NET 8 SDK, then reopen PowerShell:

    winget install -e --id Microsoft.DotNet.SDK.8
"@
    }
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path $Source)) {
        throw "Source directory does not exist: $Source"
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Invoke-TacticalRadioSigner {
    param(
        [string]$InstallerPath = "",
        [string]$StageDir = ""
    )

    $signScript = Join-Path $Root "sign-installer.ps1"

    if (-not (Test-Path $signScript)) {
        throw "Could not find signing script: $signScript"
    }

    $signParams = @{
        TimestampUrl = $TimestampUrl
    }

    if ($InstallerPath) {
        $signParams["InstallerPath"] = $InstallerPath
    }

    if ($StageDir) {
        $signParams["StageDir"] = $StageDir
    }

    if ($CertificatePath) {
        $signParams["CertificatePath"] = $CertificatePath
    }

    if ($CertificatePassword) {
        $signParams["CertificatePassword"] = $CertificatePassword
    }

    if ($CertificateThumbprint) {
        $signParams["CertificateThumbprint"] = $CertificateThumbprint
    }

    if ($UseMachineStore) {
        $signParams["UseMachineStore"] = $true
    }

    if ($SignToolPath) {
        $signParams["SignToolPath"] = $SignToolPath
    }

    & $signScript @signParams

    if (-not $?) {
        throw "Signing failed."
    }
}

Assert-Windows

$PluginDir = Join-Path $Root "apps\mumble-plugin"

$Dist = Join-Path $Root "dist"
$Stage = Join-Path $Dist "stage"
$StageApp = Join-Path $Stage "app"
$StageAppPlugin = Join-Path $StageApp "plugin"
$StageBin = Join-Path $Stage "bin"
$StagePlugin = Join-Path $Stage "plugin"
$StagePrereqs = Join-Path $Stage "prereqs"
$InstallerOut = Join-Path $Dist "installer"
$LauncherPublishDir = Join-Path $Dist "launcher-publish"

$InstallerDir = Join-Path $Root "installer"
$InnoScript = Join-Path $InstallerDir "TacticalRadio.iss"

$LauncherDir = Join-Path $InstallerDir "launcher"
$LauncherProject = Join-Path $LauncherDir "TacticalRadioLauncher.csproj"
$LauncherBuildScript = Join-Path $LauncherDir "build-launcher.ps1"
$LauncherExeName = "TacticalRadioLauncher.exe"

$PrereqsDir = Join-Path $InstallerDir "prereqs"
$WinAppRuntimeInstallerName = "WindowsAppRuntimeInstall-x64.exe"
$WinAppRuntimeInstallerSource = Join-Path $PrereqsDir $WinAppRuntimeInstallerName

$AssetsDir = Join-Path $Root "assets"
$AssetIcon = Join-Path $AssetsDir "TacticalRadio.ico"
$AssetLogoPng = Join-Path $AssetsDir "TacticalRadioLogo.png"

Write-Host ""
Write-Host "== Tactical Radio installer build =="
Write-Host "Root: $Root"
Write-Host "Version: $Version"
Write-Host "Configuration: $Configuration"
Write-Host ""

if (-not (Test-Path $PluginDir)) {
    throw "Could not find plugin directory: $PluginDir"
}

if (-not (Test-Path $InnoScript)) {
    throw "Could not find Inno Setup script: $InnoScript"
}

if (-not (Test-Path $LauncherDir)) {
    throw "Could not find launcher directory: $LauncherDir"
}

if (-not (Test-Path $LauncherProject)) {
    throw "Could not find WinUI launcher project: $LauncherProject"
}

if (-not (Test-Path $LauncherBuildScript)) {
    throw "Could not find launcher build script: $LauncherBuildScript"
}

if (-not (Test-Path $WinAppRuntimeInstallerSource)) {
    throw @"
Missing Windows App Runtime installer:

    $WinAppRuntimeInstallerSource

Download the Windows App Runtime / Windows App SDK 2.x x64 standalone installer and save it as:

    installer\prereqs\WindowsAppRuntimeInstall-x64.exe

This is required so the WinUI 3 launcher can start on machines that do not already have the Windows App Runtime installed.
"@
}

if ($Sign) {
    if (-not $CertificatePath -and -not $CertificateThumbprint) {
        throw @"
-Sign was specified, but no signing certificate was provided.

Use either:

    -CertificatePath "C:\path\certificate.pfx" -CertificatePassword "password"

or:

    -CertificateThumbprint "YOUR_CERT_THUMBPRINT"
"@
    }
}

if (-not $SkipPluginBuild) {
    $buildPluginScript = Join-Path $Root "build-plugin.ps1"

    if (-not (Test-Path $buildPluginScript)) {
        throw "Could not find plugin build script: $buildPluginScript"
    }

    $buildPluginParams = @{
        Configuration = $Configuration
        NoManifest = $true
    }

    if ($PluginReleaseDir) {
        $buildPluginParams["PluginReleaseDir"] = $PluginReleaseDir
    }

    if ($SkipNpmBuild) {
        $buildPluginParams["SkipNpmBuild"] = $true
    }

    if ($SkipNativeBuild) {
        $buildPluginParams["SkipNativeBuild"] = $true
    }

    Write-Host ""
    Write-Host "== Building plugin before installer =="

    & $buildPluginScript @buildPluginParams

    if (-not $?) {
        throw "Plugin build failed."
    }
}
else {
    Write-Host "Skipping plugin build."
}

if (-not $SkipLauncherBuild) {
    Write-Host ""
    Write-Host "== Building WinUI 3 launcher =="

    Assert-DotNetSdk

    & $LauncherBuildScript `
        -Configuration $Configuration `
        -OutputPath $LauncherPublishDir `
        -Clean

    if (-not $?) {
        throw "Launcher build failed."
    }
}
else {
    Write-Host "Skipping launcher build."
}

$launcherExe = Join-Path $LauncherPublishDir $LauncherExeName

if (-not (Test-Path $launcherExe)) {
    throw "WinUI launcher executable was not found: $launcherExe"
}

Write-Host "Launcher: $launcherExe"

Write-Host ""
Write-Host "== Finding plugin release DLLs =="

$artifacts = Get-TacticalRadioPluginArtifacts `
    -PluginDir $PluginDir `
    -Configuration $Configuration `
    -PluginReleaseDir $PluginReleaseDir

$pluginDll = Get-Item -LiteralPath $artifacts.PluginDll
$releaseDlls = @($artifacts.ReleaseDlls | ForEach-Object { Get-Item -LiteralPath $_ })

Write-Host "Plugin DLL: $($pluginDll.FullName)"
Write-Host "Release folder: $($artifacts.ReleaseFolder)"
Write-Host "OpenSSL crypto: $($artifacts.CryptoDll)"
Write-Host "OpenSSL ssl: $($artifacts.SslDll)"

Write-Host ""
Write-Host "== Staging files =="

New-CleanDirectory $Stage

New-Item `
    -ItemType Directory `
    -Path $StageApp, $StageAppPlugin, $StageBin, $StagePlugin, $StagePrereqs, $InstallerOut `
    -Force |
    Out-Null

Write-Host "Staging WinUI launcher publish output..."
Copy-DirectoryContents -Source $LauncherPublishDir -Destination $StageApp

$stagedLauncherExe = Join-Path $StageApp $LauncherExeName

if (-not (Test-Path $stagedLauncherExe)) {
    throw "Launcher was not staged correctly: $stagedLauncherExe"
}

Copy-Item $pluginDll.FullName $StagePlugin -Force
Copy-Item $pluginDll.FullName $StageAppPlugin -Force

foreach ($dll in $releaseDlls) {
    if ($dll.FullName -ne $pluginDll.FullName) {
        Copy-Item $dll.FullName $StageBin -Force
    }
}

$requiredAssets = @(
    [pscustomobject]@{
        Name = "Windows icon"
        Source = $AssetIcon
        Destination = Join-Path $StageApp "TacticalRadio.ico"
        Hint = "Create assets\TacticalRadio.ico as a multi-size .ico containing at least 16, 24, 32, 48, 64, 128, and 256 px images."
    },
    [pscustomobject]@{
        Name = "Launcher logo"
        Source = $AssetLogoPng
        Destination = Join-Path $StageApp "TacticalRadioLogo.png"
        Hint = "Create assets\TacticalRadioLogo.png as a high-resolution PNG, ideally 1024x1024."
    }
)

foreach ($asset in $requiredAssets) {
    if (-not (Test-Path $asset.Source)) {
        throw "Missing $($asset.Name): $($asset.Source). $($asset.Hint)"
    }

    Copy-Item $asset.Source $asset.Destination -Force
    Write-Host "$($asset.Name): $($asset.Source)"
}

Write-Host ""
Write-Host "== Staging prerequisites =="

Copy-Item `
    -LiteralPath $WinAppRuntimeInstallerSource `
    -Destination (Join-Path $StagePrereqs $WinAppRuntimeInstallerName) `
    -Force

Write-Host "Windows App Runtime installer:"
Write-Host "  $WinAppRuntimeInstallerSource"

$config = [ordered]@{
    baseUrl = ""
    placeId = "16489784096"
    jobId = "studio-local"
    mumblePath = "C:\Program Files\Mumble\Client\mumble.exe"
} | ConvertTo-Json -Depth 10

$config | Set-Content -Path (Join-Path $StageApp "config.json") -Encoding UTF8

Write-Host ""
Write-Host "Staged app files:"
Write-Host "App:      $StageApp"
Write-Host "Plugin:   $StageAppPlugin"
Write-Host "Bin:      $StageBin"
Write-Host "Prereqs:  $StagePrereqs"
Write-Host "Launcher: $stagedLauncherExe"

if ($Sign) {
    Write-Host ""
    Write-Host "== Signing staged launcher and DLLs =="

    Invoke-TacticalRadioSigner -StageDir $Stage
}

Write-Host ""
Write-Host "== Compiling installer =="

$iscc = Find-Iscc

if (-not $iscc) {
    throw "Inno Setup compiler was not found. Install it once with: winget install -e --id JRSoftware.InnoSetup"
}

$finalInstallerName = "TacticalRadioSetup-$Version.exe"
$installerPath = Join-Path $InstallerOut $finalInstallerName

$innoTempRoot = Join-Path $env:LOCALAPPDATA "TacticalRadio\installer-build"
$innoTempOut = Join-Path $innoTempRoot ([guid]::NewGuid().ToString("N"))
$tempInstallerBaseName = "TacticalRadioSetup-$Version-build-$([guid]::NewGuid().ToString("N"))"
$tempInstallerPath = Join-Path $innoTempOut "$tempInstallerBaseName.exe"

New-CleanDirectory $innoTempOut
New-Item -ItemType Directory -Path $InstallerOut -Force | Out-Null

Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue

Invoke-Checked $iscc @(
    "/DAppVersion=$Version",
    "/DSourceDir=$Stage",
    "/DOutputDir=$innoTempOut",
    "/DOutputBaseName=$tempInstallerBaseName",
    "/DPluginFileName=$($pluginDll.Name)",
    "/DLauncherFileName=$LauncherExeName",
    "/DWinAppRuntimeInstallerName=$WinAppRuntimeInstallerName",
    $InnoScript
)

if (-not (Test-Path $tempInstallerPath)) {
    throw "Temporary installer was not produced: $tempInstallerPath"
}

$copySucceeded = $false

for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
        Copy-Item -LiteralPath $tempInstallerPath -Destination $installerPath -Force
        $copySucceeded = $true
        break
    }
    catch {
        if ($attempt -eq 5) {
            throw
        }

        Start-Sleep -Milliseconds (300 * $attempt)
    }
}

if (-not $copySucceeded) {
    throw "Failed to copy installer to final output: $installerPath"
}

Remove-Item -LiteralPath $innoTempOut -Recurse -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $installerPath)) {
    throw "Installer was not produced: $installerPath"
}

if ($Sign) {
    Write-Host ""
    Write-Host "== Signing installer =="

    Invoke-TacticalRadioSigner -InstallerPath $installerPath
}

Write-Host ""
Write-Host "DONE"
Write-Host "Installer:"
Write-Host $installerPath
Write-Host ""