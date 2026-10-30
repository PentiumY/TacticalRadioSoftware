# Publishes a TacticalRadioSoftware release using GitHub CLI.
# Run from the TacticalRadioSoftware repository root:
#   .\Release\release.ps1 -Version 1.1.0
# Preview without changing anything:
#   .\Release\release.ps1 -Version 1.1.0 -DryRun
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version,

    [string]$Repository = 'PentiumY/TacticalRadioSoftware',
    [string]$TargetBranch = 'main',
    [string]$MumbleRepo = '',
    [switch]$SkipBuild,
    [switch]$SkipMumbleBuild,
    [switch]$AllowDirty,
    [switch]$Prerelease,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    Write-Host ('> ' + $Executable + ' ' + ($Arguments -join ' '))
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing '$Name'. Install it and ensure it is on PATH."
    }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tag = "v$Version"
$installer = Join-Path $root "dist/installer/TacticalRadioSetup-$Version.exe"
$manifest = Join-Path $root "dist/installer/TacticalRadioSetup-$Version.manifest.json"

Require-Command 'git'
Require-Command 'gh'

# Publishing a release is meaningful only after source has been pushed.
if (-not $AllowDirty) {
    $dirty = & git -C $root status --porcelain --untracked-files=no
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect git status.' }
    if ($dirty) { throw 'Tracked changes are uncommitted in TacticalRadioSoftware. Commit them or use -AllowDirty.' }

    if (-not $MumbleRepo) { $MumbleRepo = Join-Path (Split-Path $root -Parent) 'TRS-Mumble' }
    if (Test-Path (Join-Path $MumbleRepo '.git')) {
        $mumbleDirty = & git -C $MumbleRepo status --porcelain --untracked-files=no
        if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect TRS-Mumble git status.' }
        if ($mumbleDirty) { throw 'Tracked changes are uncommitted in TRS-Mumble. Commit them or use -AllowDirty.' }
    }
}

$head = (& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to read current git commit.' }
$targetSha = (& git -C $root rev-parse "refs/remotes/origin/$TargetBranch" 2>$null)
if ($LASTEXITCODE -ne 0) { throw "Cannot find origin/$TargetBranch. Run git fetch origin first." }
$targetSha = $targetSha.Trim()
if ($head -ne $targetSha) {
    throw "HEAD ($head) differs from origin/$TargetBranch ($targetSha). Commit and push source, then run the release script."
}

# Do not silently overwrite an existing release or move an existing tag.
& gh release view $tag --repo $Repository --json tagName *> $null
if ($LASTEXITCODE -eq 0) { throw "Release $tag already exists on $Repository." }

& git -C $root tag --list $tag | ForEach-Object { if ($_ -eq $tag) { throw "Local git tag $tag already exists. Resolve it before publishing." } }

if (-not $SkipBuild) {
    if ($DryRun) {
        Write-Host "[DRY RUN] Would build $Version using Release/build.ps1"
    } else {
        $buildArgs = @('-Version', $Version)
        if ($AllowDirty) { $buildArgs += '-AllowDirty' }
        if ($SkipMumbleBuild) { $buildArgs += '-SkipMumbleBuild' }
        if ($MumbleRepo) { $buildArgs += @('-MumbleRepo', $MumbleRepo) }
        & (Join-Path $PSScriptRoot 'build.ps1') @buildArgs
        if (-not $?) { throw 'Build script reported failure.' }
    }
}

if ($DryRun) {
    Write-Host "[DRY RUN] Would publish $tag on $Repository from $TargetBranch"
    Write-Host "[DRY RUN] Assets: $installer ; $manifest"
    exit 0
}

foreach ($file in @($installer, $manifest)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Release asset missing: $file" }
}

$releaseArgs = @('release', 'create', $tag, $installer, $manifest,
                 '--repo', $Repository,
                 '--target', $TargetBranch,
                 '--title', "Tactical Radio v$Version",
                 '--generate-notes')
if ($Prerelease) { $releaseArgs += '--prerelease' }
else { $releaseArgs += '--latest' }

Invoke-Checked 'gh' $releaseArgs
Write-Host "Release published: https://github.com/$Repository/releases/tag/$tag" -ForegroundColor Green
