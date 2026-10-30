param([Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$MumbleRepo,[Parameter(Mandatory)][string]$Distribution,[Parameter(Mandatory)][string]$Installer,[Parameter(Mandatory)][string]$Output)
. "$PSScriptRoot/Common.ps1"
$portablePath = (Resolve-Path $Distribution).Path
$files = @(Get-ChildItem -LiteralPath $portablePath -File -Recurse | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path = $_.FullName.Substring($portablePath.Length + 1).Replace('\','/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = $_.Length }
})
$data = [ordered]@{
    schemaVersion = 1
    version = $Version
    createdUtc = [DateTime]::UtcNow.ToString('o')
    tacticalRadioCommit = Get-GitRevision $Root
    mumbleCommit = Get-GitRevision $MumbleRepo
    installerName = (Split-Path $Installer -Leaf)
    installerSha256 = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
    files = $files
}
$data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Output -Encoding UTF8
Write-Host "Manifest created: $Output"
