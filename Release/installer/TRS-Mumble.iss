#ifndef AppVersion
  #error AppVersion must be supplied by Release/build.ps1
#endif
#ifndef SourceDir
  #error SourceDir must be supplied by Release/build.ps1
#endif
#ifndef OutputDir
  #error OutputDir must be supplied by Release/build.ps1
#endif
#ifndef OutputBaseName
  #define OutputBaseName "TacticalRadioSetup-" + AppVersion
#endif

[Setup]
; SAME AppId as the original Tactical Radio installer: upgrades the existing per-user install.
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
UninstallDisplayName=Tactical Radio
UninstallDisplayIcon={app}\mumble.exe
CloseApplications=yes
RestartApplications=no
ChangesAssociations=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
; The portable directory is staged by BuildMumble + StageDistribution.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Clean up only the known legacy Tactical Radio plugin DLLs in regular Mumble.
Type: files; Name: "{userappdata}\Mumble\Mumble\Plugins\tactical_radio_mumble_plugin.dll"
Type: files; Name: "{userappdata}\Mumble\Mumble\Plugins\tactical-radio-bridge_mumble_plugin.dll"
Type: files; Name: "{userappdata}\Mumble\Mumble\Plugins\tactical-radio-bridge.mumble_plugin.dll"
; The obsolete launcher is owned by the previous Tactical Radio install.
Type: files; Name: "{app}\TacticalRadioLauncher.exe"
Type: files; Name: "{app}\plugin\tactical_radio_mumble_plugin.dll"
Type: files; Name: "{app}\bin\tactical_radio_mumble_plugin.dll"
Type: files; Name: "{app}\TacticalRadioLogo.png"
; We intentionally do NOT delete all of {app}, or any Mumble user settings.

; Remove old shortcut names from the previous WinUI launcher.
Type: files; Name: "{autoprograms}\Tactical Radio Launcher.lnk"
Type: files; Name: "{autodesktop}\Tactical Radio Launcher.lnk"


[Icons]
Name: "{autoprograms}\Tactical Radio"; Filename: "{app}\mumble.exe"; WorkingDir: "{app}"; Comment: "Launch TRS-Mumble"
Name: "{autodesktop}\Tactical Radio"; Filename: "{app}\mumble.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\mumble.exe"; Description: "Launch Tactical Radio"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Remove only known legacy plugin copies; regular Mumble itself is untouched.
Type: files; Name: "{userappdata}\Mumble\Mumble\Plugins\tactical_radio_mumble_plugin.dll"
Type: files; Name: "{userappdata}\Mumble\Mumble\Plugins\tactical-radio-bridge_mumble_plugin.dll"
Type: files; Name: "{userappdata}\Mumble\Mumble\Plugins\tactical-radio-bridge.mumble_plugin.dll"
