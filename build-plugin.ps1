param(
    [string]$Configuration = "Release",
    [string]$PluginReleaseDir = "",
    [switch]$SkipNpmBuild,
    [switch]$SkipNativeBuild,
    [switch]$NoManifest,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = $PSScriptRoot
$PluginDir = Join-Path $Root "apps\mumble-plugin"
$PluginBuildDir = Join-Path $PluginDir "build"

function Assert-Windows {
    if ($PSVersionTable.PSEdition -eq "Core") {
        if (-not $IsWindows) {
            throw "This build script must be run on Windows."
        }

        return
    }

    $platform = [System.Environment]::OSVersion.Platform

    if ($platform -ne [System.PlatformID]::Win32NT) {
        throw "This build script must be run on Windows."
    }
}

function Assert-CMake {
    $cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue

    if (-not $cmakeCommand) {
        throw @"
cmake was not found.

Install CMake, then reopen PowerShell:

    winget install -e --id Kitware.CMake
"@
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host ""
    Write-Host "Running:"
    Write-Host "  $FilePath $($Arguments -join ' ')"
    Write-Host ""

    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
    }
}

function Add-UniqueFile {
    param(
        [Parameter(Mandatory = $true)]
        $List,

        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    foreach ($existing in $List) {
        if ($existing.FullName -ieq $File.FullName) {
            return
        }
    }

    [void]$List.Add($File)
}

function Get-BuiltDlls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildDir,

        [Parameter(Mandatory = $true)]
        [string]$Configuration
    )

    if (-not (Test-Path $BuildDir)) {
        throw "Build directory does not exist: $BuildDir"
    }

    $configurationDir = Join-Path $BuildDir $Configuration

    $allDlls = @(
        Get-ChildItem -LiteralPath $BuildDir -Recurse -File -Filter "*.dll" |
            Sort-Object LastWriteTime -Descending
    )

    if ($allDlls.Count -eq 0) {
        throw "No DLLs were found under build directory: $BuildDir"
    }

    $configurationDlls = @()

    if (Test-Path $configurationDir) {
        $configurationDlls = @(
            Get-ChildItem -LiteralPath $configurationDir -Recurse -File -Filter "*.dll" |
                Sort-Object LastWriteTime -Descending
        )
    }

    $searchDlls = @($configurationDlls + $allDlls)

    $pluginDll = $searchDlls |
        Where-Object {
            $_.Name -ieq "tactical_radio_mumble_plugin.dll"
        } |
        Select-Object -First 1

    if (-not $pluginDll) {
        $pluginDll = $searchDlls |
            Where-Object {
                $_.Name -ieq "tactical-radio-bridge_mumble_plugin.dll" -or
                $_.Name -ieq "tactical-radio-bridge.mumble_plugin.dll"
            } |
            Select-Object -First 1
    }

    if (-not $pluginDll) {
        $pluginDll = $searchDlls |
            Where-Object {
                $_.Name -match "mumble.*plugin" -and
                $_.Name -notmatch "wrapper" -and
                $_.Name -notmatch "cpp_wrapper"
            } |
            Select-Object -First 1
    }

    if (-not $pluginDll) {
        $pluginDll = $searchDlls |
            Where-Object {
                $_.Name -match "tactical.*radio" -and
                $_.Name -notmatch "wrapper" -and
                $_.Name -notmatch "cpp_wrapper"
            } |
            Select-Object -First 1
    }

    $releaseDlls = New-Object System.Collections.ArrayList

    if ($pluginDll) {
        Add-UniqueFile -List $releaseDlls -File $pluginDll

        $sameFolderDlls = @(
            Get-ChildItem -LiteralPath $pluginDll.Directory.FullName -File -Filter "*.dll" |
                Sort-Object Name
        )

        foreach ($dll in $sameFolderDlls) {
            Add-UniqueFile -List $releaseDlls -File $dll
        }
    }

    $opensslDlls = @(
        $allDlls |
            Where-Object {
                $_.Name -ieq "libcrypto-3-x64.dll" -or
                $_.Name -ieq "libssl-3-x64.dll"
            }
    )

    foreach ($dll in $opensslDlls) {
        Add-UniqueFile -List $releaseDlls -File $dll
    }

    if ($releaseDlls.Count -eq 0) {
        foreach ($dll in $allDlls) {
            Add-UniqueFile -List $releaseDlls -File $dll
        }
    }

    [pscustomobject]@{
        PluginDll = $pluginDll
        ReleaseDlls = @($releaseDlls)
        AllDlls = @($allDlls)
    }
}

Assert-Windows

Write-Host ""
Write-Host "== Tactical Radio plugin build =="
Write-Host "Root:          $Root"
Write-Host "Plugin dir:    $PluginDir"
Write-Host "Build dir:     $PluginBuildDir"
Write-Host "Configuration: $Configuration"
Write-Host ""

if (-not (Test-Path $PluginDir)) {
    throw "Could not find plugin directory: $PluginDir"
}

if (-not (Test-Path $PluginBuildDir)) {
    throw @"
Could not find plugin build directory:

    $PluginBuildDir

Configure the plugin project once before building, for example:

    cmake -S apps/mumble-plugin -B apps/mumble-plugin/build

Then run:

    .\build-plugin.ps1 -Configuration $Configuration
"@
}

if ($SkipNpmBuild) {
    Write-Host "Skipping npm build. This script currently only builds the native Mumble plugin."
}

if ($NoManifest) {
    Write-Host "NoManifest was specified. No installer manifest will be produced."
}

if (-not $SkipNativeBuild) {
    Assert-CMake

    if ($Clean) {
        Write-Host ""
        Write-Host "== Cleaning native plugin build =="

        Invoke-Checked -FilePath "cmake" -Arguments @(
            "--build",
            $PluginBuildDir,
            "--config",
            $Configuration,
            "--target",
            "clean"
        )
    }

    Write-Host ""
    Write-Host "== Building native Mumble plugin with CMake =="

    Invoke-Checked -FilePath "cmake" -Arguments @(
        "--build",
        $PluginBuildDir,
        "--config",
        $Configuration
    )
}
else {
    Write-Host "Skipping native plugin build."
}

Write-Host ""
Write-Host "== Locating built plugin artifacts =="

$artifacts = Get-BuiltDlls -BuildDir $PluginBuildDir -Configuration $Configuration

if ($artifacts.PluginDll) {
    Write-Host "Plugin DLL:"
    Write-Host "  $($artifacts.PluginDll.FullName)"
}
else {
    Write-Warning "Could not confidently identify the main Mumble plugin DLL."
    Write-Warning "DLLs found:"

    foreach ($dll in $artifacts.AllDlls) {
        Write-Warning "  $($dll.FullName)"
    }
}

Write-Host ""
Write-Host "Release DLLs:"

foreach ($dll in $artifacts.ReleaseDlls) {
    Write-Host "  $($dll.FullName)"
}

if ($PluginReleaseDir) {
    Write-Host ""
    Write-Host "== Copying plugin artifacts to release directory =="

    New-Item -ItemType Directory -Path $PluginReleaseDir -Force | Out-Null

    foreach ($dll in $artifacts.ReleaseDlls) {
        Copy-Item -LiteralPath $dll.FullName -Destination $PluginReleaseDir -Force
        Write-Host "Copied: $($dll.Name)"
    }

    Write-Host "Release directory:"
    Write-Host "  $PluginReleaseDir"
}

Write-Host ""
Write-Host "DONE"
Write-Host ""