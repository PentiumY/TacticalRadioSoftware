param([Parameter(Mandatory)][string]$Version,[switch]$Draft,[switch]$Prerelease,[switch]$AllowDirty)
. "$PSScriptRoot/scripts/Common.ps1"
Assert-Version $Version
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dir = Join-Path $root 'dist/installer'
$installer = Join-Path $dir "TacticalRadioSetup-$Version.exe"
$manifestPath = Join-Path $dir "TacticalRadioSetup-$Version.manifest.json"
Assert-File $installer
Assert-File $manifestPath
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.version -ne $Version -or $manifest.installerName -ne (Split-Path $installer -Leaf)) { throw 'Manifest version/name mismatch.' }
$hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $manifest.installerSha256) { throw 'Installer hash differs from tested build; refusing publication.' }
if (-not $AllowDirty -and -not (Test-GitClean $root)) { throw 'Working tree has uncommitted tracked changes.' }
if ((Get-GitRevision $root) -ne $manifest.tacticalRadioCommit) { throw 'Source commit differs from build manifest; refusing publication.' }
$tag = "v$Version"
Invoke-Tool 'gh' @('auth','status')
$remoteTag = & git -C $root ls-remote --tags origin "refs/tags/$tag"
if ($LASTEXITCODE -ne 0) { throw 'Cannot query remote Git tags.' }
if ($remoteTag) { throw "Tag already exists on remote: $tag" }
$oldRelease = & gh release view $tag --repo 'PentiumY/TacticalRadioSoftware' --json tagName 2>$null
if ($LASTEXITCODE -eq 0) { throw "GitHub release already exists: $tag" }
$branch = (& git -C $root branch --show-current).Trim()
if (-not $branch) { throw 'Detached HEAD. Check out the release branch.' }
Invoke-Tool 'git' @('-C',$root,'push','origin',$branch)
Invoke-Tool 'git' @('-C',$root,'tag','-a',$tag,'-m',"Tactical Radio $tag")
Invoke-Tool 'git' @('-C',$root,'push','origin',$tag)
$args = @('release','create',$tag,$installer,$manifestPath,'--repo','PentiumY/TacticalRadioSoftware','--title',"Tactical Radio $tag",'--notes',"TRS-Mumble bundled installer $tag")
if ($Draft) { $args += '--draft' }
if ($Prerelease) { $args += '--prerelease' }
Invoke-Tool 'gh' $args
Write-Host "Published $tag"
