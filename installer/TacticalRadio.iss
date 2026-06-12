#ifndef AppVersion
#define AppVersion "0.1.1"
#endif

#ifndef SourceDir
#define SourceDir "..\dist\stage"
#endif

#ifndef OutputDir
#define OutputDir "..\dist\installer"
#endif

#ifndef OutputBaseName
#define OutputBaseName "TacticalRadioSetup-" + AppVersion
#endif

#ifndef PluginFileName
#define PluginFileName "tactical_radio_mumble_plugin.dll"
#endif

#ifndef LauncherFileName
#define LauncherFileName "TacticalRadioLauncher.exe"
#endif

#ifndef WinAppRuntimeInstallerName
#define WinAppRuntimeInstallerName "WindowsAppRuntimeInstall-x64.exe"
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

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}

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

Source: "{#SourceDir}\prereqs\{#WinAppRuntimeInstallerName}"; DestDir: "{tmp}"; Flags: deleteafterinstall

Source: "{#SourceDir}\bin\*"; DestDir: "{app}\bin"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist

Source: "{#SourceDir}\plugin\{#PluginFileName}"; DestDir: "{userappdata}\Mumble\Mumble\Plugins"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Tactical Radio Launcher"; Filename: "{app}\{#LauncherFileName}"; WorkingDir: "{app}"; IconFilename: "{app}\TacticalRadio.ico"; Comment: "Launch Tactical Radio"
Name: "{autodesktop}\Tactical Radio Launcher"; Filename: "{app}\{#LauncherFileName}"; WorkingDir: "{app}"; IconFilename: "{app}\TacticalRadio.ico"; Comment: "Launch Tactical Radio"; Tasks: desktopicon

[Run]
Filename: "{tmp}\{#WinAppRuntimeInstallerName}"; Parameters: "--quiet"; StatusMsg: "Installing Windows App Runtime..."; Flags: waituntilterminated

Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Get-ChildItem -LiteralPath '{app}' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue; Get-ChildItem -LiteralPath '{userappdata}\Mumble\Mumble\Plugins' -Filter '*.dll' | Unblock-File -ErrorAction SilentlyContinue"""; Flags: runhidden

Filename: "{app}\{#LauncherFileName}"; Description: "Launch Tactical Radio"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{userappdata}\Mumble\Mumble\Plugins\{#PluginFileName}"