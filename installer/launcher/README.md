# Tactical Radio WinUI 3 launcher

This replaces the old PowerShell WinForms launcher with a WinUI 3 desktop launcher while keeping the same runtime folder layout and behavior.

## Preserved behavior

The launcher still uses the launcher app directory as its app directory by default.

Expected runtime layout:

```text
TacticalRadioLauncher.exe
config.json                 optional, created by Save Settings
TacticalRadio.ico           optional window icon
TacticalRadioLogo.png       optional header logo
plugin\*.dll                Mumble plugin DLLs copied to %APPDATA%\Mumble\Mumble\Plugins
bin\*.dll                   optional native dependency DLLs prepended to PATH when Mumble is launched
```

The launcher still:

- loads and saves `config.json`
- defaults `placeId` to `16489784096`
- defaults `jobId` to `studio-local`
- auto-detects `C:\Program Files\Mumble\Client\mumble.exe` first, then Program Files (x86)
- validates that Base URL is empty or starts with `http://` / `https://`
- copies every DLL from `plugin` into `%APPDATA%\Mumble\Mumble\Plugins`
- removes old plugin DLL names before copying the current plugin DLLs
- best-effort unblocks copied files by deleting the `Zone.Identifier` alternate data stream
- launches Mumble with:
  - `TRADIO_BASE_URL`
  - `TRADIO_PLACE_ID`
  - `TRADIO_JOB_ID`
- prepends the local `bin` folder to the launched Mumble process `PATH` if `bin` exists

## Development run

From `installer/launcher`:

```powershell
.\dev-launcher.ps1
```

That runs the WinUI launcher directly and uses `installer/launcher` as the app directory, so you can test with:

```text
installer/launcher/plugin/*.dll
installer/launcher/bin/*.dll
installer/launcher/TacticalRadioLogo.png
installer/launcher/TacticalRadio.ico
```

You can override the app directory:

```powershell
.\dev-launcher.ps1 -AppDir "C:\Path\To\Installed\TacticalRadio"
```

## Publish for Inno Setup

From `installer/launcher`:

```powershell
.\build-launcher.ps1 -Clean
```

This publishes to:

```text
installer/launcher/publish
```

Package the contents of that `publish` folder with Inno Setup.

## Root build-installer.ps1 integration

Add this before your Inno compiler step:

```powershell
$LauncherDir = Join-Path $PSScriptRoot "installer\launcher"
$LauncherPublishDir = Join-Path $LauncherDir "publish"

& (Join-Path $LauncherDir "build-launcher.ps1") -OutputPath $LauncherPublishDir -Clean
if ($LASTEXITCODE -ne 0) {
    throw "Launcher build failed with exit code $LASTEXITCODE"
}
```

Then make your `.iss` file include the published launcher folder:

```ini
[Files]
Source: "installer\launcher\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Tactical Radio"; Filename: "{app}\TacticalRadioLauncher.exe"
Name: "{autodesktop}\Tactical Radio"; Filename: "{app}\TacticalRadioLauncher.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\TacticalRadioLauncher.exe"; Description: "Launch Tactical Radio"; Flags: nowait postinstall skipifsilent
```

If your installer currently installs to `Program Files`, remember that saving `config.json` beside the exe may require admin rights. The old PowerShell launcher had the same behavior. Installing to `{localappdata}` or another user-writable app directory avoids that.
