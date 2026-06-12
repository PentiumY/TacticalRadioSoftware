; Include this in your generated .iss or copy the relevant lines into it.
; This assumes build-launcher.ps1 published the launcher to installer\launcher\publish.

[Files]
Source: "installer\launcher\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Tactical Radio"; Filename: "{app}\TacticalRadioLauncher.exe"
Name: "{autodesktop}\Tactical Radio"; Filename: "{app}\TacticalRadioLauncher.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\TacticalRadioLauncher.exe"; Description: "Launch Tactical Radio"; Flags: nowait postinstall skipifsilent
