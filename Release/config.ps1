# Repository paths can be overridden with -MumbleRepo or -MumbleBuildDir.
$script:TrsDefaults = @{
    MumbleRepo = (Join-Path (Split-Path $PSScriptRoot -Parent) 'TRS-Mumble')
    PluginRelativeBuild = 'apps/mumble-plugin/build'
    ProductName = 'Tactical Radio'
    Executable = 'mumble.exe'
    PluginName = 'tactical_radio_mumble_plugin.dll'
    InstallerBase = 'TacticalRadioSetup'
    LegacyAppId = '{C4A7A0D7-42EA-4B2D-95C6-D65FD9A2EFBE}'
}
