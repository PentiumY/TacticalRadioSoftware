param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Configuration = "Release",

    [string]$ReleaseNotes = "",

    [string]$ReleaseNotesFile = "",

    [switch]$Draft,

    [switch]$Prerelease,

    [switch]$SkipBuild,

    [switch]$SkipCommit,

    [switch]$SkipPush,

    [switch]$SkipTag,

    [switch]$SkipRelease,

    [switch]$ReplaceExistingAsset,

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
$BuildInstallerScript = Join-Path $Root "build-installer.ps1"

function Invoke-ExternalChecked {
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

function Invoke-PowerShellScriptChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "PowerShell script was not found: $ScriptPath"
    }

    Write-Host ""
    Write-Host "Running PowerShell script:"
    Write-Host "  $ScriptPath"

    foreach ($key in ($Parameters.Keys | Sort-Object)) {
        $value = $Parameters[$key]

        if ($value -is [switch] -or $value -is [bool]) {
            Write-Host "  -$key $value"
        }
        elseif ($null -ne $value -and "$value" -ne "") {
            Write-Host "  -$key `"$value`""
        }
    }

    Write-Host ""

    & $ScriptPath @Parameters

    if (-not $?) {
        throw "PowerShell script failed: $ScriptPath"
    }
}

function Assert-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$InstallHint
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw @"
Required command was not found: $Name

$InstallHint
"@
    }
}

function Normalize-ReleaseVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputVersion
    )

    $cleanVersion = $InputVersion.Trim()

    if ([string]::IsNullOrWhiteSpace($cleanVersion)) {
        throw "Version cannot be empty."
    }

    $cleanVersion = $cleanVersion -replace "^[vV]", ""

    if ($cleanVersion -notmatch "^\d+\.\d+\.\d+([.-][A-Za-z0-9.-]+)?$") {
        throw @"
Invalid version: $InputVersion

Use a version like:

    1.0.2

or:

    v1.0.2
"@
    }

    return $cleanVersion
}

function Test-GitHasChanges {
    $status = & git status --porcelain

    if ($LASTEXITCODE -ne 0) {
        throw "Could not read git status."
    }

    return -not [string]::IsNullOrWhiteSpace(($status | Out-String).Trim())
}

function Test-GitTagExistsLocal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    & git rev-parse -q --verify "refs/tags/$Tag" *> $null
    return $LASTEXITCODE -eq 0
}

function Test-GitTagExistsRemote {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $remoteTag = & git ls-remote --tags origin "refs/tags/$Tag"

    if ($LASTEXITCODE -ne 0) {
        throw "Could not check remote tag: $Tag"
    }

    return -not [string]::IsNullOrWhiteSpace(($remoteTag | Out-String).Trim())
}

function Assert-GitHubCliReady {
    Assert-Command `
        -Name "gh" `
        -InstallHint "Install GitHub CLI with: winget install -e --id GitHub.cli"

    & gh auth status *> $null

    if ($LASTEXITCODE -ne 0) {
        throw @"
GitHub CLI is installed, but you are not logged in.

Run:

    gh auth login

Then run this release script again.
"@
    }
}

Push-Location $Root

try {
    if (-not (Test-Path $BuildInstallerScript)) {
        throw "Could not find build-installer.ps1 in repo root: $BuildInstallerScript"
    }

    Assert-Command `
        -Name "git" `
        -InstallHint "Install Git for Windows, then reopen PowerShell."

    Assert-GitHubCliReady

    $CleanVersion = Normalize-ReleaseVersion -InputVersion $Version
    $Tag = "v$CleanVersion"
    $InstallerPath = Join-Path $Root "dist\installer\TacticalRadioSetup-$CleanVersion.exe"
    $WrongInstallerPath = Join-Path $Root "dist\installer\TacticalRadioSetup--Configuration.exe"

    Write-Host ""
    Write-Host "== Tactical Radio release publish =="
    Write-Host "Root:          $Root"
    Write-Host "Version:       $CleanVersion"
    Write-Host "Tag:           $Tag"
    Write-Host "Configuration: $Configuration"
    Write-Host "Installer:     $InstallerPath"
    Write-Host ""

    if (Test-Path $WrongInstallerPath) {
        Write-Host "Removing old incorrectly named installer:"
        Write-Host "  $WrongInstallerPath"
        Remove-Item -LiteralPath $WrongInstallerPath -Force -ErrorAction SilentlyContinue
    }

    if (-not $SkipBuild) {
        Write-Host ""
        Write-Host "== Building installer =="

        $buildParams = @{
            Configuration = $Configuration
            Version = $CleanVersion
        }

        if ($Sign) {
            $buildParams["Sign"] = $true
        }

        if ($CertificatePath) {
            $buildParams["CertificatePath"] = $CertificatePath
        }

        if ($CertificatePassword) {
            $buildParams["CertificatePassword"] = $CertificatePassword
        }

        if ($CertificateThumbprint) {
            $buildParams["CertificateThumbprint"] = $CertificateThumbprint
        }

        if ($UseMachineStore) {
            $buildParams["UseMachineStore"] = $true
        }

        if ($SignToolPath) {
            $buildParams["SignToolPath"] = $SignToolPath
        }

        if ($TimestampUrl) {
            $buildParams["TimestampUrl"] = $TimestampUrl
        }

        Invoke-PowerShellScriptChecked `
            -ScriptPath $BuildInstallerScript `
            -Parameters $buildParams
    }
    else {
        Write-Host "Skipping installer build."
    }

    if (-not (Test-Path $InstallerPath)) {
        $availableInstallers = @(
            Get-ChildItem -LiteralPath (Join-Path $Root "dist\installer") -Filter "TacticalRadioSetup-*.exe" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending
        )

        if ($availableInstallers.Count -gt 0) {
            Write-Host ""
            Write-Host "Installers currently in dist\installer:"
            foreach ($installer in $availableInstallers) {
                Write-Host "  $($installer.Name)"
            }
        }

        throw "Installer was not found: $InstallerPath"
    }

    Write-Host ""
    Write-Host "== Installer ready =="
    Write-Host $InstallerPath

    if (-not $SkipCommit) {
        Write-Host ""
        Write-Host "== Committing source changes =="

        if (Test-GitHasChanges) {
            Invoke-ExternalChecked -FilePath "git" -Arguments @("add", "-A")
            Invoke-ExternalChecked -FilePath "git" -Arguments @("commit", "-m", "Release $Tag")
        }
        else {
            Write-Host "No source changes to commit."
        }
    }
    else {
        Write-Host "Skipping git commit."
    }

    if (-not $SkipPush) {
        Write-Host ""
        Write-Host "== Pushing current branch =="

        Invoke-ExternalChecked -FilePath "git" -Arguments @("push")
    }
    else {
        Write-Host "Skipping branch push."
    }

    if (-not $SkipTag) {
        Write-Host ""
        Write-Host "== Creating git tag =="

        if (Test-GitTagExistsLocal -Tag $Tag) {
            throw "Local tag already exists: $Tag"
        }

        if (Test-GitTagExistsRemote -Tag $Tag) {
            throw "Remote tag already exists on origin: $Tag"
        }

        Invoke-ExternalChecked -FilePath "git" -Arguments @(
            "tag",
            "-a",
            $Tag,
            "-m",
            "Tactical Radio $Tag"
        )

        if (-not $SkipPush) {
            Invoke-ExternalChecked -FilePath "git" -Arguments @(
                "push",
                "origin",
                $Tag
            )
        }
        else {
            Write-Host "Tag created locally but not pushed because -SkipPush was used."
        }
    }
    else {
        Write-Host "Skipping tag creation."
    }

    if (-not $SkipRelease) {
        Write-Host ""
        Write-Host "== Creating GitHub release =="

        $releaseExists = $false
        & gh release view $Tag *> $null

        if ($LASTEXITCODE -eq 0) {
            $releaseExists = $true
        }

        if ($releaseExists) {
            if (-not $ReplaceExistingAsset) {
                throw @"
GitHub release already exists: $Tag

Use -ReplaceExistingAsset to upload the installer again with --clobber.
"@
            }

            Write-Host "Release already exists. Replacing installer asset..."

            Invoke-ExternalChecked -FilePath "gh" -Arguments @(
                "release",
                "upload",
                $Tag,
                $InstallerPath,
                "--clobber"
            )
        }
        else {
            $releaseArgs = @(
                "release",
                "create",
                $Tag,
                $InstallerPath,
                "--title",
                "Tactical Radio $Tag"
            )

            if ($ReleaseNotesFile) {
                if (-not (Test-Path $ReleaseNotesFile)) {
                    throw "Release notes file does not exist: $ReleaseNotesFile"
                }

                $releaseArgs += @("--notes-file", $ReleaseNotesFile)
            }
            elseif ($ReleaseNotes) {
                $releaseArgs += @("--notes", $ReleaseNotes)
            }
            else {
                $releaseArgs += @("--notes", "Release $Tag")
            }

            if ($Draft) {
                $releaseArgs += "--draft"
            }

            if ($Prerelease) {
                $releaseArgs += "--prerelease"
            }

            Invoke-ExternalChecked -FilePath "gh" -Arguments $releaseArgs
        }
    }
    else {
        Write-Host "Skipping GitHub release creation."
    }

    Write-Host ""
    Write-Host "DONE"
    Write-Host "Release tag:"
    Write-Host "  $Tag"
    Write-Host "Installer:"
    Write-Host "  $InstallerPath"
    Write-Host ""
    Write-Host "Open release page:"
    Write-Host "  gh release view $Tag --web"
    Write-Host ""
}
finally {
    Pop-Location
}