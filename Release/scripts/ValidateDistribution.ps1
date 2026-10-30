param([Parameter(Mandatory)][string]$Distribution)
. "$PSScriptRoot/Common.ps1"
foreach ($file in @('mumble.exe','libcrypto-3-x64.dll','libssl-3-x64.dll','rnnoise.dll','speexdsp.dll','plugins/tactical_radio_mumble_plugin.dll')) {
    Assert-File (Join-Path $Distribution $file)
}
$bad = @(Get-ChildItem -LiteralPath (Join-Path $Distribution 'plugins') -Filter '*tactical*' -File)
if ($bad.Count -ne 1) { throw "Expected exactly one Tactical Radio plugin; found $($bad.Count)" }
$hashes = @(Get-ChildItem -LiteralPath $Distribution -Recurse -File | ForEach-Object { Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 })
Write-Host "Validated $($hashes.Count) files. Note: launch testing on a clean Windows VM is still required."
