param(
    [string]$Version = "1.0.1",
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
$AssetsDir = Join-Path $Root "assets"
$AssetIcon = Join-Path $AssetsDir "TacticalRadio.ico"
$AssetLogoPng = Join-Path $AssetsDir "TacticalRadioLogo.png"

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

$RequiredAssets = @(
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

foreach ($asset in $RequiredAssets) {
    if (-not (Test-Path $asset.Source)) {
        throw "Missing $($asset.Name): $($asset.Source). $($asset.Hint)"
    }

    Copy-Item $asset.Source $asset.Destination -Force
    Write-Host "$($asset.Name): $($asset.Source)"
}


$config = [ordered]@{
    baseUrl = ""
    placeId = "16489784096"
    jobId = "studio-local"
    mumblePath = "C:\Program Files\Mumble\Client\mumble.exe"
} | ConvertTo-Json -Depth 10

$config | Set-Content -Path (Join-Path $StageApp "config.json") -Encoding UTF8

$launcherPs1 = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

function Enable-HighDpiSupport {
    try {
        try {
            [System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) | Out-Null
            return
        }
        catch {
        }

        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class TacticalRadioDpiNative
{
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("shcore.dll")]
    public static extern int SetProcessDpiAwareness(int awareness);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@ -ErrorAction SilentlyContinue

        $dpiWasSet = $false

        try {
            # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
            $dpiWasSet = [TacticalRadioDpiNative]::SetProcessDpiAwarenessContext([IntPtr](-4))
        }
        catch {
        }

        if (-not $dpiWasSet) {
            try {
                # PROCESS_PER_MONITOR_DPI_AWARE = 2
                [TacticalRadioDpiNative]::SetProcessDpiAwareness(2) | Out-Null
                $dpiWasSet = $true
            }
            catch {
            }
        }

        if (-not $dpiWasSet) {
            try {
                [TacticalRadioDpiNative]::SetProcessDPIAware() | Out-Null
            }
            catch {
            }
        }
    }
    catch {
    }
}

Enable-HighDpiSupport

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $AppDir "config.json"
$AppIconPath = Join-Path $AppDir "TacticalRadio.ico"
$AppLogoPath = Join-Path $AppDir "TacticalRadioLogo.png"
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
        baseUrl = ""
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
    $baseUrl = $BaseUrlText.Text.Trim()

    if ($baseUrl -and $baseUrl -notmatch "^https?://") {
        throw "Base URL must start with http:// or https://, or be left empty."
    }

    $obj = [ordered]@{
        baseUrl = $baseUrl
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

function Add-Label {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 130
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, 25)
    $label.Font = $DefaultFont
    $label.ForeColor = [System.Drawing.Color]::FromArgb(38, 48, 61)
    $label.UseCompatibleTextRendering = $false
    $Parent.Controls.Add($label)
    return $label
}

function Add-HelpText {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 520
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, 23)
    $label.Font = $SmallFont
    $label.ForeColor = [System.Drawing.Color]::FromArgb(105, 117, 130)
    $label.UseCompatibleTextRendering = $false
    $Parent.Controls.Add($label)
    return $label
}

function Add-TextBox {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 520
    )

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Text = $Text
    $textBox.Location = New-Object System.Drawing.Point($X, $Y)
    $textBox.Size = New-Object System.Drawing.Size($Width, 28)
    $textBox.Font = $DefaultFont
    $textBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $Parent.Controls.Add($textBox)
    return $textBox
}

function New-ActionButton {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, 40)
    $button.Font = $ButtonFont
    $button.BackColor = $BackColor
    $button.ForeColor = $ForeColor
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.UseVisualStyleBackColor = $false
    $button.UseCompatibleTextRendering = $false
    return $button
}

$config = Get-Config

$DefaultFont = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
$SmallFont = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
$TitleFont = New-Object System.Drawing.Font("Segoe UI Semibold", 19, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
$SubtitleFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
$ButtonFont = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)

$DarkColor = [System.Drawing.Color]::FromArgb(21, 32, 48)
$AccentColor = [System.Drawing.Color]::FromArgb(40, 119, 219)
$SurfaceColor = [System.Drawing.Color]::FromArgb(246, 248, 251)
$BorderColor = [System.Drawing.Color]::FromArgb(218, 225, 233)
$TextColor = [System.Drawing.Color]::FromArgb(34, 46, 60)
$MutedTextColor = [System.Drawing.Color]::FromArgb(77, 89, 103)

$AppIcon = $null
if (Test-Path $AppIconPath) {
    try {
        $AppIcon = New-Object System.Drawing.Icon($AppIconPath)
    }
    catch {
        $AppIcon = $null
    }
}

$LogoImage = $null
if (Test-Path $AppLogoPath) {
    try {
        $LogoImage = [System.Drawing.Image]::FromFile($AppLogoPath)
    }
    catch {
        $LogoImage = $null
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Tactical Radio"
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96.0, 96.0)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.ClientSize = New-Object System.Drawing.Size(780, 530)
$form.MinimumSize = New-Object System.Drawing.Size(780, 530)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.BackColor = $SurfaceColor
$form.Font = $DefaultFont

if ($AppIcon) {
    $form.Icon = $AppIcon
}

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$headerPanel.Height = 104
$headerPanel.BackColor = $DarkColor
$form.Controls.Add($headerPanel)

if ($LogoImage -or $AppIcon) {
    $logoBox = New-Object System.Windows.Forms.PictureBox
    $logoBox.Location = New-Object System.Drawing.Point(24, 22)
    $logoBox.Size = New-Object System.Drawing.Size(60, 60)
    $logoBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $logoBox.BackColor = $DarkColor

    if ($LogoImage) {
        $logoBox.Image = $LogoImage
    }
    elseif ($AppIcon) {
        $logoBox.Image = $AppIcon.ToBitmap()
    }

    $headerPanel.Controls.Add($logoBox)
}

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Tactical Radio"
$titleLabel.Location = New-Object System.Drawing.Point(100, 19)
$titleLabel.Size = New-Object System.Drawing.Size(630, 38)
$titleLabel.Font = $TitleFont
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.UseCompatibleTextRendering = $false
$headerPanel.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Configure the bridge connection, repair the Mumble plugin, then launch Mumble."
$subtitleLabel.Location = New-Object System.Drawing.Point(103, 61)
$subtitleLabel.Size = New-Object System.Drawing.Size(630, 26)
$subtitleLabel.Font = $SubtitleFont
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(198, 214, 235)
$subtitleLabel.UseCompatibleTextRendering = $false
$headerPanel.Controls.Add($subtitleLabel)

$connectionGroup = New-Object System.Windows.Forms.GroupBox
$connectionGroup.Text = "Bridge settings"
$connectionGroup.Location = New-Object System.Drawing.Point(20, 120)
$connectionGroup.Size = New-Object System.Drawing.Size(740, 176)
$connectionGroup.Font = $ButtonFont
$connectionGroup.ForeColor = $TextColor
$form.Controls.Add($connectionGroup)

Add-Label $connectionGroup "Base URL:" 18 36 120 | Out-Null
$BaseUrlText = Add-TextBox $connectionGroup $config.baseUrl 156 32 556
Add-HelpText $connectionGroup "Optional. Leave empty to avoid shipping a default server address." 156 62 556 | Out-Null

Add-Label $connectionGroup "Place ID:" 18 94 120 | Out-Null
$PlaceIdText = Add-TextBox $connectionGroup $config.placeId 156 90 230
$PlaceIdText.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left

Add-Label $connectionGroup "Job ID:" 412 94 80 | Out-Null
$JobIdText = Add-TextBox $connectionGroup $config.jobId 492 90 220
$JobIdText.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
Add-HelpText $connectionGroup "These values are passed to Mumble as TRADIO_PLACE_ID and TRADIO_JOB_ID." 156 120 556 | Out-Null

$mumbleGroup = New-Object System.Windows.Forms.GroupBox
$mumbleGroup.Text = "Mumble"
$mumbleGroup.Location = New-Object System.Drawing.Point(20, 310)
$mumbleGroup.Size = New-Object System.Drawing.Size(740, 96)
$mumbleGroup.Font = $ButtonFont
$mumbleGroup.ForeColor = $TextColor
$form.Controls.Add($mumbleGroup)

Add-Label $mumbleGroup "Mumble path:" 18 39 120 | Out-Null
$MumblePathText = Add-TextBox $mumbleGroup $config.mumblePath 156 35 456

$BrowseButton = New-ActionButton "Browse" 626 31 86 ([System.Drawing.Color]::FromArgb(226, 232, 240)) ([System.Drawing.Color]::FromArgb(28, 38, 52))
$BrowseButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$BrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Mumble executable|mumble.exe|Executable files|*.exe|All files|*.*"
    $dialog.Title = "Select mumble.exe"

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $MumblePathText.Text = $dialog.FileName
    }
})
$mumbleGroup.Controls.Add($BrowseButton)

$buttonPanel = New-Object System.Windows.Forms.Panel
$buttonPanel.Location = New-Object System.Drawing.Point(20, 420)
$buttonPanel.Size = New-Object System.Drawing.Size(740, 50)
$buttonPanel.BackColor = $SurfaceColor
$form.Controls.Add($buttonPanel)

$SaveButton = New-ActionButton "Save Settings" 0 5 154 ([System.Drawing.Color]::FromArgb(226, 232, 240)) ([System.Drawing.Color]::FromArgb(28, 38, 52))
$SaveButton.Add_Click({
    try {
        Save-Config
        $StatusLabel.Text = "Settings saved."
    }
    catch {
        Show-Error $_.Exception.Message
    }
})
$buttonPanel.Controls.Add($SaveButton)

$RepairButton = New-ActionButton "Install / Repair Plugin" 168 5 190 ([System.Drawing.Color]::FromArgb(226, 232, 240)) ([System.Drawing.Color]::FromArgb(28, 38, 52))
$RepairButton.Add_Click({
    try {
        Save-Config
        Install-Plugin
    }
    catch {
        Show-Error $_.Exception.Message
    }
})
$buttonPanel.Controls.Add($RepairButton)

$LaunchButton = New-ActionButton "Launch Mumble" 550 5 190 $AccentColor ([System.Drawing.Color]::White)
$LaunchButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$LaunchButton.Add_Click({
    try {
        Launch-Mumble
    }
    catch {
        Show-Error $_.Exception.Message
    }
})
$buttonPanel.Controls.Add($LaunchButton)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(20, 484)
$statusPanel.Size = New-Object System.Drawing.Size(740, 32)
$statusPanel.BackColor = [System.Drawing.Color]::White
$statusPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($statusPanel)

$StatusLabel = New-Object System.Windows.Forms.Label
$StatusLabel.Text = "Ready. Base URL is empty by default."
$StatusLabel.Location = New-Object System.Drawing.Point(10, 7)
$StatusLabel.Size = New-Object System.Drawing.Size(715, 20)
$StatusLabel.Font = $SmallFont
$StatusLabel.ForeColor = $MutedTextColor
$StatusLabel.UseCompatibleTextRendering = $false
$statusPanel.Controls.Add($StatusLabel)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.SetToolTip($BaseUrlText, "Leave empty unless you want the launcher to set TRADIO_BASE_URL automatically.")
$toolTip.SetToolTip($PlaceIdText, "Roblox placeId passed to the plugin process.")
$toolTip.SetToolTip($JobIdText, "Roblox jobId passed to the plugin process.")
$toolTip.SetToolTip($MumblePathText, "Path to the local Mumble client executable.")

$form.AcceptButton = $LaunchButton

$form.Add_FormClosed({
    if ($LogoImage) {
        $LogoImage.Dispose()
    }

    if ($AppIcon) {
        $AppIcon.Dispose()
    }
})

[System.Windows.Forms.Application]::Run($form)
'@
$launcherPs1 | Set-Content -Path (Join-Path $StageApp "TacticalRadioLauncher.ps1") -Encoding UTF8

$launcherCmd = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0TacticalRadioLauncher.ps1"
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
SetupIconFile={#SourceDir}\app\TacticalRadio.ico
UninstallDisplayName=Tactical Radio
UninstallDisplayIcon={app}\TacticalRadio.ico

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
Name: "{autoprograms}\Tactical Radio Launcher"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\TacticalRadioLauncher.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\TacticalRadio.ico"; Comment: "Launch Tactical Radio"
Name: "{autodesktop}\Tactical Radio Launcher"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\TacticalRadioLauncher.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\TacticalRadio.ico"; Comment: "Launch Tactical Radio"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Get-ChildItem -LiteralPath '{app}' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue; Get-ChildItem -LiteralPath '{userappdata}\Mumble\Mumble\Plugins' -Filter '*.dll' | Unblock-File -ErrorAction SilentlyContinue"""; Flags: runhidden

Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\TacticalRadioLauncher.ps1"""; Description: "Launch Tactical Radio"; Flags: nowait postinstall skipifsilent

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