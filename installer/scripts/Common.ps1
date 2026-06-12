Set-StrictMode -Version Latest

function Assert-Windows {
    if ($env:OS -ne "Windows_NT") {
        throw "This script must be run on Windows."
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host "> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
    }
}

function Find-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    return $null
}

function Find-Iscc {
    $fromPath = Find-Command @("ISCC.exe", "iscc.exe", "ISCC", "iscc")
    if ($fromPath) {
        return $fromPath
    }

    $candidateRoots = New-Object System.Collections.Generic.List[string]

    if (${env:ProgramFiles(x86)}) {
        $candidateRoots.Add((Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6"))
    }

    if ($env:ProgramFiles) {
        $candidateRoots.Add((Join-Path $env:ProgramFiles "Inno Setup 6"))
        $candidateRoots.Add((Join-Path $env:ProgramFiles "WindowsApps"))
    }

    if ($env:LOCALAPPDATA) {
        $candidateRoots.Add((Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6"))
        $candidateRoots.Add((Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"))
    }

    foreach ($root in ($candidateRoots | Select-Object -Unique)) {
        if (-not (Test-Path $root)) {
            continue
        }

        $found = Get-ChildItem -Path $root -Filter "ISCC.exe" -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($found) {
            return $found.FullName
        }
    }

    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1"
    )

    foreach ($registryPath in $registryPaths) {
        if (Test-Path $registryPath) {
            $installLocation = (Get-ItemProperty $registryPath -ErrorAction SilentlyContinue).InstallLocation

            if ($installLocation) {
                $candidate = Join-Path $installLocation "ISCC.exe"

                if (Test-Path $candidate) {
                    return $candidate
                }
            }
        }
    }

    return $null
}

function New-CleanDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path $Path) {
        Remove-Item $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-ReleaseDlls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PluginDir,

        [string]$Configuration = "Release",

        [string]$PluginReleaseDir = ""
    )

    $dirs = New-Object System.Collections.Generic.List[string]

    if ($PluginReleaseDir -and (Test-Path $PluginReleaseDir)) {
        $dirs.Add((Resolve-Path $PluginReleaseDir).Path)
    }

    $commonDirs = @(
        (Join-Path $PluginDir "build\$Configuration"),
        (Join-Path $PluginDir "build\src\$Configuration"),
        (Join-Path $PluginDir "build\bin\$Configuration"),
        (Join-Path $PluginDir $Configuration),
        (Join-Path $PluginDir "release"),
        (Join-Path $PluginDir "Release"),
        (Join-Path $PluginDir "bundle")
    )

    foreach ($dir in $commonDirs) {
        if (Test-Path $dir) {
            $dirs.Add((Resolve-Path $dir).Path)
        }
    }

    if (Test-Path $PluginDir) {
        Get-ChildItem -Path $PluginDir -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notmatch "\\external\\" -and
                ($_.Name -ieq $Configuration -or $_.Name -ieq "release")
            } |
            ForEach-Object {
                $dirs.Add($_.FullName)
            }
    }

    $uniqueDirs = $dirs | Select-Object -Unique

    foreach ($dir in $uniqueDirs) {
        $dlls = @(Get-ChildItem -Path $dir -Filter "*.dll" -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)

        if ($dlls.Count -gt 0) {
            return $dlls
        }
    }

    return @()
}

function Get-TacticalRadioPluginArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PluginDir,

        [string]$Configuration = "Release",

        [string]$PluginReleaseDir = ""
    )

    $dlls = @(Get-ReleaseDlls -PluginDir $PluginDir -Configuration $Configuration -PluginReleaseDir $PluginReleaseDir)

    if ($dlls.Count -eq 0) {
        throw "Could not find any DLLs under apps\mumble-plugin. Expected them in apps\mumble-plugin\build\$Configuration."
    }

    $pluginCandidates = @(
        $dlls |
            Where-Object {
                $_.Name -notmatch "^libcrypto" -and
                $_.Name -notmatch "^libssl" -and
                $_.Name -match "(mumble|plugin|tactical|radio|bridge)"
            } |
            Sort-Object LastWriteTime -Descending
    )

    if ($pluginCandidates.Count -eq 0) {
        Write-Host "DLLs found:"
        $dlls | ForEach-Object { Write-Host " - $($_.FullName)" }
        throw "Could not identify the Mumble plugin DLL. Make sure its name contains mumble, plugin, tactical, radio, or bridge."
    }

    $pluginDll = $pluginCandidates[0]
    $releaseFolder = $pluginDll.Directory.FullName
    $releaseDlls = @(Get-ChildItem -Path $releaseFolder -Filter "*.dll" -File)

    $cryptoDll = $releaseDlls | Where-Object { $_.Name -ieq "libcrypto-3-x64.dll" } | Select-Object -First 1
    $sslDll = $releaseDlls | Where-Object { $_.Name -ieq "libssl-3-x64.dll" } | Select-Object -First 1

    if (-not $cryptoDll) {
        throw "Missing libcrypto-3-x64.dll in: $releaseFolder"
    }

    if (-not $sslDll) {
        throw "Missing libssl-3-x64.dll in: $releaseFolder"
    }

    return [pscustomobject]@{
        PluginDll = $pluginDll.FullName
        PluginFileName = $pluginDll.Name
        ReleaseFolder = $releaseFolder
        CryptoDll = $cryptoDll.FullName
        SslDll = $sslDll.FullName
        ReleaseDlls = @($releaseDlls | ForEach-Object { $_.FullName })
    }
}

function Get-LatestInstallerPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerOut
    )

    $installer = Get-ChildItem -Path $InstallerOut -Filter "TacticalRadioSetup-*.exe" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($installer) {
        return $installer.FullName
    }

    return $null
}
