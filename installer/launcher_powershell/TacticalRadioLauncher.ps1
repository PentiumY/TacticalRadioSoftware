param(
    [string]$AppDir = ""
)

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

function Get-DefaultMumblePath {
    $candidates = @()

    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles "Mumble\Client\mumble.exe")
    }

    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "Mumble\Client\mumble.exe")
    }

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

    if (Test-Path $binDir) {
        [Environment]::SetEnvironmentVariable("PATH", "$binDir;$currentPath", "Process")
    }

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

Enable-HighDpiSupport

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

if (-not $AppDir) {
    $AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$ConfigPath = Join-Path $AppDir "config.json"
$AppIconPath = Join-Path $AppDir "TacticalRadio.ico"
$AppLogoPath = Join-Path $AppDir "TacticalRadioLogo.png"
$PluginSourceDir = Join-Path $AppDir "plugin"
$PluginDestDir = Join-Path $env:APPDATA "Mumble\Mumble\Plugins"

$config = Get-Config

$DefaultFont = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
$SmallFont = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
$TitleFont = New-Object System.Drawing.Font("Segoe UI Semibold", 19, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
$SubtitleFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
$ButtonFont = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)

$DarkColor = [System.Drawing.Color]::FromArgb(21, 32, 48)
$AccentColor = [System.Drawing.Color]::FromArgb(40, 119, 219)
$SurfaceColor = [System.Drawing.Color]::FromArgb(246, 248, 251)
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
