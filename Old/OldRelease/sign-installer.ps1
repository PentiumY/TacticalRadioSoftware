param(
    [string]$InstallerPath = "",
    [string]$StageDir = "",
    [string[]]$Files = @(),
    [string[]]$Directories = @(),

    [string]$CertificatePath = "",
    [string]$CertificatePassword = "",
    [string]$CertificateThumbprint = "",
    [switch]$UseMachineStore,

    [string]$TimestampUrl = "http://timestamp.digicert.com",
    [string]$SignToolPath = "",

    [switch]$Force,
    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Windows {
    if ($PSVersionTable.PSEdition -eq "Core") {
        if (-not $IsWindows) {
            throw "This signing script must be run on Windows."
        }

        return
    }

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw "This signing script must be run on Windows."
    }
}

function Find-SignTool {
    param(
        [string]$ExplicitPath = ""
    )

    if ($ExplicitPath) {
        if (-not (Test-Path $ExplicitPath)) {
            throw "Specified signtool.exe was not found: $ExplicitPath"
        }

        return (Get-Item -LiteralPath $ExplicitPath).FullName
    }

    $fromPath = Get-Command signtool.exe -ErrorAction SilentlyContinue

    if ($fromPath) {
        return $fromPath.Source
    }

    $candidateRoots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "${env:ProgramFiles}\Windows Kits\10\bin"
    )

    $candidates = @()

    foreach ($root in $candidateRoots) {
        if (Test-Path $root) {
            $candidates += Get-ChildItem -LiteralPath $root -Recurse -File -Filter "signtool.exe" -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -match "\\x64\\signtool\.exe$"
                }
        }
    }

    $best = $candidates |
        Sort-Object FullName -Descending |
        Select-Object -First 1

    if (-not $best) {
        throw @"
Could not find signtool.exe.

Install the Windows SDK or Visual Studio Build Tools with Windows SDK support.
"@
    }

    return $best.FullName
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [string[]]$SafeArguments = @()
    )

    Write-Host ""
    Write-Host "Running:"
    if ($SafeArguments.Count -gt 0) {
        Write-Host "  $FilePath $($SafeArguments -join ' ')"
    }
    else {
        Write-Host "  $FilePath $($Arguments -join ' ')"
    }
    Write-Host ""

    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath"
    }
}

function Add-CandidateFile {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "File does not exist: $Path"
    }

    $item = Get-Item -LiteralPath $Path

    if ($item.PSIsContainer) {
        throw "Expected a file but got a directory: $Path"
    }

    $extension = $item.Extension.ToLowerInvariant()

    if ($extension -ne ".exe" -and $extension -ne ".dll") {
        Write-Host "Skipping non-signable file: $($item.FullName)"
        return
    }

    $key = $item.FullName.ToLowerInvariant()

    if (-not $Map.ContainsKey($key)) {
        $Map[$key] = $item
    }
}

function Add-CandidateDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Directory does not exist: $Path"
    }

    $item = Get-Item -LiteralPath $Path

    if (-not $item.PSIsContainer) {
        throw "Expected a directory but got a file: $Path"
    }

    $signableFiles = Get-ChildItem -LiteralPath $item.FullName -Recurse -File |
        Where-Object {
            $_.Extension -ieq ".exe" -or $_.Extension -ieq ".dll"
        }

    foreach ($file in $signableFiles) {
        Add-CandidateFile -Map $Map -Path $file.FullName
    }
}

function Get-SignatureStatusText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path

    return $signature.Status.ToString()
}

function Sign-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SignTool,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $status = Get-SignatureStatusText -Path $Path

    if ($status -eq "Valid" -and -not $Force) {
        Write-Host "Already signed, skipping:"
        Write-Host "  $Path"
        return
    }

    $signArgs = New-Object System.Collections.Generic.List[string]
    $safeArgs = New-Object System.Collections.Generic.List[string]

    $signArgs.Add("sign")
    $safeArgs.Add("sign")

    $signArgs.Add("/fd")
    $signArgs.Add("SHA256")
    $safeArgs.Add("/fd")
    $safeArgs.Add("SHA256")

    $signArgs.Add("/tr")
    $signArgs.Add($TimestampUrl)
    $safeArgs.Add("/tr")
    $safeArgs.Add($TimestampUrl)

    $signArgs.Add("/td")
    $signArgs.Add("SHA256")
    $safeArgs.Add("/td")
    $safeArgs.Add("SHA256")

    $signArgs.Add("/d")
    $signArgs.Add("Tactical Radio")
    $safeArgs.Add("/d")
    $safeArgs.Add("""Tactical Radio""")

    if ($CertificatePath) {
        if (-not (Test-Path $CertificatePath)) {
            throw "Certificate file was not found: $CertificatePath"
        }

        $signArgs.Add("/f")
        $signArgs.Add($CertificatePath)
        $safeArgs.Add("/f")
        $safeArgs.Add($CertificatePath)

        if ($CertificatePassword) {
            $signArgs.Add("/p")
            $signArgs.Add($CertificatePassword)
            $safeArgs.Add("/p")
            $safeArgs.Add("<hidden>")
        }
    }
    elseif ($CertificateThumbprint) {
        $signArgs.Add("/sha1")
        $signArgs.Add($CertificateThumbprint)
        $safeArgs.Add("/sha1")
        $safeArgs.Add($CertificateThumbprint)

        if ($UseMachineStore) {
            $signArgs.Add("/sm")
            $safeArgs.Add("/sm")
        }
    }
    else {
        throw @"
No signing certificate was provided.

Use either:

    -CertificatePath path\to\certificate.pfx -CertificatePassword "password"

or:

    -CertificateThumbprint YOUR_CERT_THUMBPRINT

"@
    }

    $signArgs.Add($Path)
    $safeArgs.Add($Path)

    Invoke-Checked -FilePath $SignTool -Arguments $signArgs.ToArray() -SafeArguments $safeArgs.ToArray()

    if (-not $SkipVerify) {
        Verify-File -SignTool $SignTool -Path $Path
    }
}

function Verify-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SignTool,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $verifyArgs = @(
        "verify",
        "/pa",
        "/v",
        $Path
    )

    Invoke-Checked -FilePath $SignTool -Arguments $verifyArgs
}

Assert-Windows

Write-Host ""
Write-Host "== Tactical Radio signer =="
Write-Host ""

$resolvedSignTool = Find-SignTool -ExplicitPath $SignToolPath

Write-Host "SignTool:"
Write-Host "  $resolvedSignTool"

$candidateMap = @{}

if ($StageDir) {
    Write-Host ""
    Write-Host "Adding staged binaries:"
    Write-Host "  $StageDir"

    Add-CandidateDirectory -Map $candidateMap -Path $StageDir
}

if ($InstallerPath) {
    Write-Host ""
    Write-Host "Adding installer:"
    Write-Host "  $InstallerPath"

    Add-CandidateFile -Map $candidateMap -Path $InstallerPath
}

foreach ($directory in $Directories) {
    Add-CandidateDirectory -Map $candidateMap -Path $directory
}

foreach ($file in $Files) {
    Add-CandidateFile -Map $candidateMap -Path $file
}

$targets = @(
    $candidateMap.Values |
        Sort-Object FullName
)

if ($targets.Count -eq 0) {
    throw "No .exe or .dll files were found to sign."
}

Write-Host ""
Write-Host "Files to sign:"
foreach ($target in $targets) {
    Write-Host "  $($target.FullName)"
}

foreach ($target in $targets) {
    Write-Host ""
    Write-Host "== Signing =="
    Write-Host $target.FullName

    Sign-File -SignTool $resolvedSignTool -Path $target.FullName
}

Write-Host ""
Write-Host "DONE signing."
Write-Host ""