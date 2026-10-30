# Sign staged TRS-Mumble binaries, rebuild the installer, sign the installer,
# and regenerate the release manifest. Run from the repository root.
# Requires a publicly trusted code-signing certificate and Windows SDK SignTool.
[CmdletBinding(DefaultParameterSetName='Pfx')]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')][string]$Version,
    [Parameter(Mandatory,ParameterSetName='Pfx')][string]$PfxPath,
    [Parameter(ParameterSetName='Pfx')][securestring]$PfxPassword,
    [Parameter(Mandatory,ParameterSetName='Store')][string]$Thumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [string]$SignToolPath = '',
    [string]$InnoCompilerPath = '',
    [switch]$SkipManifest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$portable = Join-Path $root 'dist\portable\TRS-Mumble'
$output = Join-Path $root 'dist\installer'
$installer = Join-Path $output "TacticalRadioSetup-$Version.exe"
$plugin = Join-Path $portable 'plugins\tactical_radio_mumble_plugin.dll'
$mumble = Join-Path $portable 'mumble.exe'
$iss = Join-Path $PSScriptRoot 'installer\TRS-Mumble.iss'
$manifest = Join-Path $output "TacticalRadioSetup-$Version.manifest.json"

function Find-Executable([string]$given, [string]$name, [string]$pattern) {
    if ($given) {
        if (-not (Test-Path -LiteralPath $given -PathType Leaf)) { throw "Not found: $given" }
        return (Resolve-Path -LiteralPath $given).Path
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $paths = @()
    foreach ($base in @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:LOCALAPPDATA\Programs\Inno Setup 6")) {
        if ($base -and (Test-Path $base)) {
            $paths += Get-ChildItem -Path $base -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        }
    }
    if (-not $paths) { throw "Cannot locate $name. Supply its explicit path." }
    return ($paths | Sort-Object -Descending | Select-Object -First 1)
}

foreach ($file in @($mumble,$plugin,$iss)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required file missing: $file" }
}
$signTool = Find-Executable $SignToolPath 'signtool.exe' 'signtool.exe'
$iscc = Find-Executable $InnoCompilerPath 'ISCC.exe' 'ISCC.exe'

# Do not log PFX passwords or commit certificates into Git.
$signArgs = @('sign','/fd','SHA256','/tr',$TimestampUrl,'/td','SHA256','/v')
if ($PSCmdlet.ParameterSetName -eq 'Store') {
    $signArgs += @('/sha1',($Thumbprint -replace '\s',''))
} else {
    if (-not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) { throw "PFX not found: $PfxPath" }
    if (-not $PfxPassword) { $PfxPassword = Read-Host 'PFX password' -AsSecureString }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PfxPassword)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $signArgs += @('/f',(Resolve-Path -LiteralPath $PfxPath).Path,'/p',$plain)
}

function Invoke-Sign([string]$file) {
    Write-Host "Signing $file"
    & $signTool @signArgs $file
    if ($LASTEXITCODE -ne 0) { throw "Signing failed: $file" }
    & $signTool verify /pa /v $file
    if ($LASTEXITCODE -ne 0) { throw "Signature verification failed: $file" }
}
try {
    # Sign in the staging directory before Inno Setup compresses the files.
    Invoke-Sign $mumble
    Invoke-Sign $plugin

    Write-Host 'Rebuilding Inno Setup installer from signed staged binaries...'
    & $iscc "/DAppVersion=$Version" "/DSourceDir=$portable" "/DOutputDir=$output" "/DOutputBaseName=TacticalRadioSetup-$Version" $iss
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed' }
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Installer missing: $installer" }
    Invoke-Sign $installer

    if (-not $SkipManifest) {
        $generator = Join-Path $PSScriptRoot 'scripts\GenerateManifest.ps1'
        if (-not (Test-Path $generator)) { throw "Manifest generator missing: $generator" }
        $mumbleRepo = Join-Path (Split-Path $root -Parent) 'TRS-Mumble'
        & $generator -Version $Version -Root $root -MumbleRepo $mumbleRepo -Distribution $portable -Installer $installer -Output $manifest
        if (-not $?) { throw 'Manifest regeneration failed' }
    }
    Write-Host "SIGNED RELEASE READY: $installer" -ForegroundColor Green
} finally {
    if (Get-Variable plain -ErrorAction SilentlyContinue) { $plain = $null }
    $signArgs = @()
}
