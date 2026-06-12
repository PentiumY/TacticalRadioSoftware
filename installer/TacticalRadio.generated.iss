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
