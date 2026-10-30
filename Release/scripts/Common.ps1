
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Tool([string]$Program, [string[]]$ToolArgs) {
    Write-Host ('> ' + $Program + ' ' + ($ToolArgs -join ' '))
    & $Program @ToolArgs
    if ($LASTEXITCODE -ne 0) {
        throw "$Program exited with $LASTEXITCODE"
    }
}

function Assert-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing file: $Path"
    }
}

function Get-GitRevision([string]$Directory) {
    $revision = & git -C $Directory rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot determine Git revision: $Directory"
    }
    return ($revision | Select-Object -First 1).Trim()
}

function Test-GitClean([string]$Directory) {
    $status = & git -C $Directory status --porcelain --untracked-files=no 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read Git status: $Directory"
    }
    return -not [bool]($status | Where-Object { $_ })
}

function Resolve-InnoCompiler {
    $found = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($found) {
        return $found.Source
    }

    $paths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }

    throw 'ISCC.exe not found. Install Inno Setup 6.'
}

function Assert-Version([string]$Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') {
        throw 'Use a semantic version, e.g. 1.1.0'
    }
}
