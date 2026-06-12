param(
    [string]$Configuration = "Release",
    [string]$OutputPath = "",
    [switch]$Clean,
    [string]$Version = "1.0.1"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$LauncherDir = $PSScriptRoot
$ProjectPath = Join-Path $LauncherDir "TacticalRadioLauncher.csproj"
$LauncherExeName = "TacticalRadioLauncher.exe"

if (-not $OutputPath) {
    $OutputPath = Join-Path $LauncherDir "publish"
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

function Convert-VersionForDotNetProperties {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputVersion
    )

    $cleanVersion = $InputVersion.Trim()

    if ([string]::IsNullOrWhiteSpace($cleanVersion)) {
        $cleanVersion = "0.0.0"
    }

    $cleanVersion = $cleanVersion -replace "^[vV]", ""

    $versionCore = ($cleanVersion -split "\+")[0]
    $versionCore = ($versionCore -split "-")[0]

    $rawParts = @($versionCore -split "\.")
    $numericParts = New-Object System.Collections.ArrayList

    foreach ($part in $rawParts) {
        $digits = $part -replace "[^0-9]", ""

        if ([string]::IsNullOrWhiteSpace($digits)) {
            [void]$numericParts.Add("0")
        }
        else {
            [void]$numericParts.Add($digits)
        }
    }

    while ($numericParts.Count -lt 4) {
        [void]$numericParts.Add("0")
    }

    if ($numericParts.Count -gt 4) {
        $numericParts = @($numericParts[0], $numericParts[1], $numericParts[2], $numericParts[3])
    }

    $fileVersion = "$($numericParts[0]).$($numericParts[1]).$($numericParts[2]).$($numericParts[3])"

    return [pscustomobject]@{
        InformationalVersion = $cleanVersion
        PackageVersion = $cleanVersion
        AssemblyVersion = $fileVersion
        FileVersion = $fileVersion
    }
}

function Find-LauncherBuildOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDir,

        [Parameter(Mandatory = $true)]
        [string]$Configuration,

        [Parameter(Mandatory = $true)]
        [string]$ExeName
    )

    $binDir = Join-Path $BaseDir "bin"

    if (-not (Test-Path $binDir)) {
        throw "Launcher bin directory does not exist: $binDir"
    }

    $candidateExes = @(
        Get-ChildItem -LiteralPath $binDir -Recurse -File -Filter $ExeName |
            Where-Object {
                $_.FullName -match "\\$Configuration\\" -and
                $_.FullName -match "\\win-x64\\"
            } |
            Sort-Object LastWriteTime -Descending
    )

    if ($candidateExes.Count -eq 0) {
        $candidateExes = @(
            Get-ChildItem -LiteralPath $binDir -Recurse -File -Filter $ExeName |
                Where-Object {
                    $_.FullName -match "\\$Configuration\\"
                } |
                Sort-Object LastWriteTime -Descending
        )
    }

    if ($candidateExes.Count -eq 0) {
        Write-Host ""
        Write-Host "Could not find $ExeName. Files found under bin:"

        Get-ChildItem -LiteralPath $binDir -Recurse -File |
            Select-Object -First 100 |
            ForEach-Object {
                Write-Host "  $($_.FullName)"
            }

        throw "Launcher build failed. EXE was not produced under: $binDir"
    }

    return $candidateExes[0].Directory.FullName
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet was not found. Install the .NET 8 SDK."
}

if (-not (Test-Path $ProjectPath)) {
    throw "Could not find launcher project: $ProjectPath"
}

$dotNetVersion = Convert-VersionForDotNetProperties -InputVersion $Version

if ($Clean) {
    Remove-Item -LiteralPath (Join-Path $LauncherDir "bin") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $LauncherDir "obj") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $OutputPath -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "== Building Tactical Radio WinUI launcher =="
Write-Host "Project:               $ProjectPath"
Write-Host "Configuration:         $Configuration"
Write-Host "Output:                $OutputPath"
Write-Host "Version:               $($dotNetVersion.PackageVersion)"
Write-Host "Assembly/File version: $($dotNetVersion.FileVersion)"
Write-Host ""

Invoke-Checked -FilePath "dotnet" -Arguments @(
    "restore",
    $ProjectPath,
    "--runtime",
    "win-x64"
)

Invoke-Checked -FilePath "dotnet" -Arguments @(
    "build",
    $ProjectPath,
    "--configuration",
    $Configuration,
    "--runtime",
    "win-x64",
    "--no-restore",
    "/p:WindowsPackageType=None",
    "/p:WindowsAppSDKSelfContained=false",
    "/p:SelfContained=false",
    "/p:Platform=x64",
    "/p:PlatformTarget=x64",
    "/p:Version=$($dotNetVersion.PackageVersion)",
    "/p:AssemblyVersion=$($dotNetVersion.AssemblyVersion)",
    "/p:FileVersion=$($dotNetVersion.FileVersion)",
    "/p:InformationalVersion=$($dotNetVersion.InformationalVersion)"
)

$buildOutput = Find-LauncherBuildOutput `
    -BaseDir $LauncherDir `
    -Configuration $Configuration `
    -ExeName $LauncherExeName

$launcherExe = Join-Path $buildOutput $LauncherExeName

if (-not (Test-Path $launcherExe)) {
    throw "Launcher EXE was not found: $launcherExe"
}

Remove-Item -LiteralPath $OutputPath -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Write-Host ""
Write-Host "Copying known-working build output..."
Write-Host "From: $buildOutput"
Write-Host "To:   $OutputPath"

Copy-DirectoryContents -Source $buildOutput -Destination $OutputPath

$publishedLauncherExe = Join-Path $OutputPath $LauncherExeName

if (-not (Test-Path $publishedLauncherExe)) {
    throw "Launcher output copy failed. EXE was not staged: $publishedLauncherExe"
}

$fileCount = @(Get-ChildItem -LiteralPath $OutputPath -Recurse -File).Count

try {
    $fileVersionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($publishedLauncherExe)

    Write-Host ""
    Write-Host "Stamped launcher version:"
    Write-Host "  ProductVersion: $($fileVersionInfo.ProductVersion)"
    Write-Host "  FileVersion:    $($fileVersionInfo.FileVersion)"
}
catch {
    Write-Warning "Could not read stamped launcher version from: $publishedLauncherExe"
}

Write-Host ""
Write-Host "Launcher output ready:"
Write-Host "  $publishedLauncherExe"
Write-Host "File count: $fileCount"
Write-Host ""
Write-Host "Run it with:"
Write-Host "  Start-Process -FilePath `"$publishedLauncherExe`" -WorkingDirectory `"$OutputPath`""
Write-Host ""