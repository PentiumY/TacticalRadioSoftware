param(
    [string]$Version = "0.1.1",
    [string]$Configuration = "Release",
    [string]$PluginReleaseDir = "",
    [switch]$SkipNpmBuild,
    [switch]$SkipNativeBuild
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:OS -ne "Windows_NT") {
    throw "This installer build script must be run on Windows."
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$PluginDir = Join-Path $Root "apps\mumble-plugin"
$PluginBuildDir = Join-Path $PluginDir "build"

$Dist = Join-Path $Root "dist"
$Stage = Join-Path $Dist "stage"
$StageApp = Join-Path $Stage "app"
$StageAppPlugin = Join-Path $StageApp "plugin"
$StageBin = Join-Path $Stage "bin"
$StagePlugin = Join-Path $Stage "plugin"
$InstallerOut = Join-Path $Dist "installer"
$GeneratedInstallerDir = Join-Path $Root "installer"
$GeneratedIss = Join-Path $GeneratedInstallerDir "TacticalRadio.generated.iss"

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    Write-Host "> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
    }
}

function Find-Command {
    param([string[]]$Names)

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

    $candidateRoots = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6",
        "$env:ProgramFiles\Inno Setup 6",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
        "$env:ProgramFiles\WindowsApps"
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $candidateRoots) {
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
    param([string]$Path)

    if (Test-Path $Path) {
        Remove-Item $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-ReleaseDlls {
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

Write-Host ""
Write-Host "== Tactical Radio installer build =="
Write-Host "Root: $Root"
Write-Host "Version: $Version"
Write-Host "Configuration: $Configuration"
Write-Host ""

if (-not (Test-Path $PluginDir)) {
    throw "Could not find plugin directory: $PluginDir"
}

if (-not $SkipNpmBuild) {
    $npm = Find-Command @("npm.cmd", "npm")
    if ($npm) {
        Write-Host ""
        Write-Host "== Building npm workspace =="
        Push-Location $Root
        try {
            Invoke-Checked $npm @("run", "build", "--if-present")
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Warning "npm was not found. Skipping npm build."
    }
}

if (-not $SkipNativeBuild) {
    $cmake = Find-Command @("cmake.exe", "cmake")

    if ($cmake) {
        Write-Host ""
        Write-Host "== Building Mumble plugin with CMake =="

        if (Test-Path $PluginBuildDir) {
            try {
                Invoke-Checked $cmake @("--build", $PluginBuildDir, "--config", $Configuration)
            }
            catch {
                Write-Warning "Existing CMake build failed. Re-configuring build directory."
                Invoke-Checked $cmake @("-S", $PluginDir, "-B", $PluginBuildDir, "-A", "x64")
                Invoke-Checked $cmake @("--build", $PluginBuildDir, "--config", $Configuration)
            }
        }
        else {
            Invoke-Checked $cmake @("-S", $PluginDir, "-B", $PluginBuildDir, "-A", "x64")
            Invoke-Checked $cmake @("--build", $PluginBuildDir, "--config", $Configuration)
        }
    }
    else {
        Write-Warning "cmake was not found. Using existing Release DLLs."
    }
}

Write-Host ""
Write-Host "== Finding plugin release DLLs =="

$dlls = @(Get-ReleaseDlls)

if ($dlls.Count -eq 0) {
    throw "Could not find any DLLs under apps\mumble-plugin. Expected them in apps\mumble-plugin\build\Release."
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

$PluginDll = $pluginCandidates[0]
$ReleaseFolder = $PluginDll.Directory.FullName

Write-Host "Plugin DLL: $($PluginDll.FullName)"
Write-Host "Release folder: $ReleaseFolder"

$releaseDlls = @(Get-ChildItem -Path $ReleaseFolder -Filter "*.dll" -File)

$CryptoDll = $releaseDlls | Where-Object { $_.Name -ieq "libcrypto-3-x64.dll" } | Select-Object -First 1
$SslDll = $releaseDlls | Where-Object { $_.Name -ieq "libssl-3-x64.dll" } | Select-Object -First 1

if (-not $CryptoDll) {
    throw "Missing libcrypto-3-x64.dll in: $ReleaseFolder"
}

if (-not $SslDll) {
    throw "Missing libssl-3-x64.dll in: $ReleaseFolder"
}

Write-Host "OpenSSL crypto: $($CryptoDll.FullName)"
Write-Host "OpenSSL ssl: $($SslDll.FullName)"

Write-Host ""
Write-Host "== Staging files =="

New-CleanDirectory $Stage
New-Item -ItemType Directory -Path $StageApp, $StageAppPlugin, $StageBin, $StagePlugin, $InstallerOut, $GeneratedInstallerDir -Force | Out-Null

Copy-Item $PluginDll.FullName $StagePlugin -Force
Copy-Item $PluginDll.FullName $StageAppPlugin -Force

foreach ($dll in $releaseDlls) {
    if ($dll.FullName -ne $PluginDll.FullName) {
        Copy-Item $dll.FullName $StageBin -Force
    }
}

$config = [ordered]@{
    baseUrl = "http://83.254.129.17:3000"
    placeId = "16489784096"
    jobId = "studio-local"
    mumblePath = "C:\Program Files\Mumble\Client\mumble.exe"
} | ConvertTo-Json -Depth 10

$config | Set-Content -Path (Join-Path $StageApp "config.json") -Encoding UTF8

$launcherPs1 = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $AppDir "config.json"
$PluginSourceDir = Join-Path $AppDir "plugin"
$PluginDestDir = Join-Path $env:APPDATA "Mumble\Mumble\Plugins"

function Get-DefaultMumblePath {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Mumble\Client\mumble.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Mumble\Client\mumble.exe")
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return "C:\Program Files\Mumble\Client\mumble.exe"
}

function Get-Config {
    $default = [ordered]@{
        baseUrl = "http://83.254.129.17:3000"
        placeId = "16489784096"
        jobId = "studio-local"
        mumblePath = Get-DefaultMumblePath
    }

    if (Test-Path $ConfigPath) {
        try {
            $loaded = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

            foreach ($key in @("baseUrl", "placeId", "jobId", "mumblePath")) {
                if ($loaded.PSObject.Properties.Name -contains $key) {
                    $default[$key] = [string]$loaded.$key
                }
            }
        }
        catch {
        }
    }

    return $default
}

function Save-Config {
    $obj = [ordered]@{
        baseUrl = $BaseUrlText.Text.Trim()
        placeId = $PlaceIdText.Text.Trim()
        jobId = $JobIdText.Text.Trim()
        mumblePath = $MumblePathText.Text.Trim()
    }

    $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Install-Plugin {
    New-Item -ItemType Directory -Path $PluginDestDir -Force | Out-Null

    $plugins = @(Get-ChildItem -Path $PluginSourceDir -Filter "*.dll" -File -ErrorAction SilentlyContinue)

    if ($plugins.Count -eq 0) {
        throw "No plugin DLL was found in: $PluginSourceDir"
    }

    $oldPluginNames = @(
        "tactical_radio_mumble_plugin.dll",
        "tactical-radio-bridge_mumble_plugin.dll",
        "tactical-radio-bridge.mumble_plugin.dll"
    )

    foreach ($oldName in $oldPluginNames) {
        $oldPath = Join-Path $PluginDestDir $oldName
        if (Test-Path $oldPath) {
            Remove-Item $oldPath -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($plugin in $plugins) {
        Copy-Item $plugin.FullName $PluginDestDir -Force
        Unblock-File -LiteralPath (Join-Path $PluginDestDir $plugin.Name) -ErrorAction SilentlyContinue
    }

    Get-ChildItem -Path $AppDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    $StatusLabel.Text = "Plugin installed/repaired in Mumble plugin folder."
}

function Launch-Mumble {
    Save-Config
    Install-Plugin

    $mumblePath = $MumblePathText.Text.Trim()

    if (-not (Test-Path $mumblePath)) {
        throw "Mumble was not found at: $mumblePath"
    }

    $binDir = Join-Path $AppDir "bin"
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "Process")
    [Environment]::SetEnvironmentVariable("PATH", "$binDir;$currentPath", "Process")

    [Environment]::SetEnvironmentVariable("TRADIO_BASE_URL", $BaseUrlText.Text.Trim(), "Process")
    [Environment]::SetEnvironmentVariable("TRADIO_PLACE_ID", $PlaceIdText.Text.Trim(), "Process")
    [Environment]::SetEnvironmentVariable("TRADIO_JOB_ID", $JobIdText.Text.Trim(), "Process")

    Start-Process -FilePath $mumblePath -WorkingDirectory (Split-Path -Parent $mumblePath)

    $StatusLabel.Text = "Mumble launched with Tactical Radio environment."
}

function Show-Error {
    param([string]$Message)

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        "Tactical Radio Launcher",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

$config = Get-Config

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Tactical Radio Launcher"
$form.Size = New-Object System.Drawing.Size(660, 360)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

function Add-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size(120, 24)
    $form.Controls.Add($label)
    return $label
}

function Add-TextBox {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 440
    )

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Text = $Text
    $textBox.Location = New-Object System.Drawing.Point($X, $Y)
    $textBox.Size = New-Object System.Drawing.Size($Width, 24)
    $form.Controls.Add($textBox)
    return $textBox
}

Add-Label "Base URL:" 20 24 | Out-Null
$BaseUrlText = Add-TextBox $config.baseUrl 150 20

Add-Label "Place ID:" 20 64 | Out-Null
$PlaceIdText = Add-TextBox $config.placeId 150 60

Add-Label "Job ID:" 20 104 | Out-Null
$JobIdText = Add-TextBox $config.jobId 150 100

Add-Label "Mumble path:" 20 144 | Out-Null
$MumblePathText = Add-TextBox $config.mumblePath 150 140 360

$BrowseButton = New-Object System.Windows.Forms.Button
$BrowseButton.Text = "Browse"
$BrowseButton.Location = New-Object System.Drawing.Point(520, 138)
$BrowseButton.Size = New-Object System.Drawing.Size(90, 28)
$BrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Mumble executable|mumble.exe|Executable files|*.exe|All files|*.*"
    $dialog.Title = "Select mumble.exe"

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $MumblePathText.Text = $dialog.FileName
    }
})
$form.Controls.Add($BrowseButton)

$SaveButton = New-Object System.Windows.Forms.Button
$SaveButton.Text = "Save Settings"
$SaveButton.Location = New-Object System.Drawing.Point(150, 190)
$SaveButton.Size = New-Object System.Drawing.Size(130, 36)
$SaveButton.Add_Click({
    try {
        Save-Config
        $StatusLabel.Text = "Settings saved."
    }
    catch {
        Show-Error $_.Exception.Message
    }
})
$form.Controls.Add($SaveButton)

$RepairButton = New-Object System.Windows.Forms.Button
$RepairButton.Text = "Install / Repair Plugin"
$RepairButton.Location = New-Object System.Drawing.Point(290, 190)
$RepairButton.Size = New-Object System.Drawing.Size(150, 36)
$RepairButton.Add_Click({
    try {
        Save-Config
        Install-Plugin
    }
    catch {
        Show-Error $_.Exception.Message
    }
})
$form.Controls.Add($RepairButton)

$LaunchButton = New-Object System.Windows.Forms.Button
$LaunchButton.Text = "Launch Mumble"
$LaunchButton.Location = New-Object System.Drawing.Point(450, 190)
$LaunchButton.Size = New-Object System.Drawing.Size(160, 36)
$LaunchButton.Add_Click({
    try {
        Launch-Mumble
    }
    catch {
        Show-Error $_.Exception.Message
    }
})
$form.Controls.Add($LaunchButton)

$StatusLabel = New-Object System.Windows.Forms.Label
$StatusLabel.Text = "Ready."
$StatusLabel.Location = New-Object System.Drawing.Point(20, 260)
$StatusLabel.Size = New-Object System.Drawing.Size(600, 40)
$form.Controls.Add($StatusLabel)

[System.Windows.Forms.Application]::Run($form)
'@

$launcherPs1 | Set-Content -Path (Join-Path $StageApp "TacticalRadioLauncher.ps1") -Encoding UTF8

$launcherCmd = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0TacticalRadioLauncher.ps1"
'@

$launcherCmd | Set-Content -Path (Join-Path $StageApp "TacticalRadioLauncher.cmd") -Encoding ASCII

$iss = @'
#ifndef AppVersion
#define AppVersion "0.1.1"
#endif

#ifndef SourceDir
#define SourceDir "..\dist\stage"
#endif

#ifndef PluginFileName
#define PluginFileName "tactical-radio-bridge_mumble_plugin.dll"
#endif

[Setup]
AppId={{C4A7A0D7-42EA-4B2D-95C6-D65FD9A2EFBE}
AppName=Tactical Radio
AppVersion={#AppVersion}
AppPublisher=Tactical Radio
DefaultDirName={localappdata}\TacticalRadio
DefaultGroupName=Tactical Radio
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputBaseFilename=TacticalRadioSetup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Tactical Radio

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Dirs]
Name: "{userappdata}\Mumble\Mumble\Plugins"
Name: "{app}\bin"
Name: "{app}\plugin"

[InstallDelete]
Type: files; Name: "{userappdata}\Mumble\Mumble\Plugins\tactical_radio_mumble_plugin.dll"
Type: files; Name: "{userappdata}\Mumble\Mumble\Plugins\tactical-radio-bridge_mumble_plugin.dll"
Type: files; Name: "{userappdata}\Mumble\Mumble\Plugins\tactical-radio-bridge.mumble_plugin.dll"

[Files]
Source: "{#SourceDir}\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\bin\*"; DestDir: "{app}\bin"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\plugin\{#PluginFileName}"; DestDir: "{userappdata}\Mumble\Mumble\Plugins"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Tactical Radio Launcher"; Filename: "{app}\TacticalRadioLauncher.cmd"; WorkingDir: "{app}"
Name: "{autodesktop}\Tactical Radio Launcher"; Filename: "{app}\TacticalRadioLauncher.cmd"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Get-ChildItem -LiteralPath '{app}' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue; Get-ChildItem -LiteralPath '{userappdata}\Mumble\Mumble\Plugins' -Filter '*.dll' | Unblock-File -ErrorAction SilentlyContinue"""; Flags: runhidden

Filename: "{app}\TacticalRadioLauncher.cmd"; Description: "Launch Tactical Radio"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{userappdata}\Mumble\Mumble\Plugins\{#PluginFileName}"
'@

$iss | Set-Content -Path $GeneratedIss -Encoding UTF8

Write-Host ""
Write-Host "== Compiling installer =="

$iscc = Find-Iscc

if (-not $iscc) {
    throw "Inno Setup compiler was not found. Install it once with: winget install -e --id JRSoftware.InnoSetup"
}

Invoke-Checked $iscc @(
    "/DAppVersion=$Version",
    "/DSourceDir=$Stage",
    "/DPluginFileName=$($PluginDll.Name)",
    "/O$InstallerOut",
    "/FTacticalRadioSetup-$Version",
    $GeneratedIss
)

$InstallerPath = Join-Path $InstallerOut "TacticalRadioSetup-$Version.exe"

if (-not (Test-Path $InstallerPath)) {
    throw "Installer was not produced: $InstallerPath"
}

Write-Host ""
Write-Host "DONE"
Write-Host "Installer:"
Write-Host $InstallerPath
Write-Host ""