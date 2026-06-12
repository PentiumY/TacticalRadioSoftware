param(
    [string]$Version = "0.1.1",
    [string]$Configuration = "Release",
    [string]$PluginReleaseDir = "",
    [switch]$SkipNpmBuild,
    [switch]$SkipNativeBuild
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:OS -ne "Windows_NT") {
    throw "This installer build script must be run on Windows."
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$PluginDir = Join-Path $Root "apps\mumble-plugin"
$PluginBuildDir = Join-Path $PluginDir "build"

$Dist = Join-Path $Root "dist"
$Stage = Join-Path $Dist "stage"
$StageApp = Join-Path $Stage "app"
$StageAppPlugin = Join-Path $StageApp "plugin"
$StageBin = Join-Path $Stage "bin"
$StagePlugin = Join-Path $Stage "plugin"
$InstallerOut = Join-Path $Dist "installer"
$GeneratedInstallerDir = Join-Path $Root "installer"
$GeneratedIss = Join-Path $GeneratedInstallerDir "TacticalRadio.generated.iss"

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    Write-Host "> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
    }
}

function Find-Command {
    param([string[]]$Names)

    foreach ($name in $Names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    return $null
}

function Find-Iscc {
    $fromPath = Find-Command @("ISCC.exe", "iscc.exe", "ISCC", "iscc")
    if ($fromPath) {
        return $fromPath
    }

    $candidateRoots = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6",
        "$env:ProgramFiles\Inno Setup 6",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
        "$env:ProgramFiles\WindowsApps"
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $candidateRoots) {
        $found = Get-ChildItem -Path $root -Filter "ISCC.exe" -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($found) {
            return $found.FullName
        }
    }

    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1"
    )

    foreach ($registryPath in $registryPaths) {
        if (Test-Path $registryPath) {
            $installLocation = (Get-ItemProperty $registryPath -ErrorAction SilentlyContinue).InstallLocation

            if ($installLocation) {
                $candidate = Join-Path $installLocation "ISCC.exe"

                if (Test-Path $candidate) {
                    return $candidate
                }
            }
        }
    }

    return $null
}

function New-CleanDirectory {
    param([string]$Path)

    if (Test-Path $Path) {
        Remove-Item $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-ReleaseDlls {
    $dirs = New-Object System.Collections.Generic.List[string]

    if ($PluginReleaseDir -and (Test-Path $PluginReleaseDir)) {
        $dirs.Add((Resolve-Path $PluginReleaseDir).Path)
    }

    $commonDirs = @(
        (Join-Path $PluginDir "build\$Configuration"),
        (Join-Path $PluginDir "build\src\$Configuration"),
        (Join-Path $PluginDir "build\bin\$Configuration"),
        (Join-Path $PluginDir $Configuration),
        (Join-Path $PluginDir "release"),
        (Join-Path $PluginDir "Release"),
        (Join-Path $PluginDir "bundle")
    )

    foreach ($dir in $commonDirs) {
        if (Test-Path $dir) {
            $dirs.Add((Resolve-Path $dir).Path)
        }
    }

    if (Test-Path $PluginDir) {
        Get-ChildItem -Path $PluginDir -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notmatch "\\external\\" -and
                ($_.Name -ieq $Configuration -or $_.Name -ieq "release")
            } |
            ForEach-Object {
                $dirs.Add($_.FullName)
            }
    }

    $uniqueDirs = $dirs | Select-Object -Unique

    foreach ($dir in $uniqueDirs) {
        $dlls = @(Get-ChildItem -Path $dir -Filter "*.dll" -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)

        if ($dlls.Count -gt 0) {
            return $dlls
        }
    }

    return @()
}

Write-Host ""
Write-Host "== Tactical Radio installer build =="
Write-Host "Root: $Root"
Write-Host "Version: $Version"
Write-Host "Configuration: $Configuration"
Write-Host ""

if (-not (Test-Path $PluginDir)) {
    throw "Could not find plugin directory: $PluginDir"
}

if (-not $SkipNpmBuild) {
    $npm = Find-Command @("npm.cmd", "npm")
    if ($npm) {
        Write-Host ""
        Write-Host "== Building npm workspace =="
        Push-Location $Root
        try {
            Invoke-Checked $npm @("run", "build", "--if-present")
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Warning "npm was not found. Skipping npm build."
    }
}

if (-not $SkipNativeBuild) {
    $cmake = Find-Command @("cmake.exe", "cmake")

    if ($cmake) {
        Write-Host ""
        Write-Host "== Building Mumble plugin with CMake =="

        if (Test-Path $PluginBuildDir) {
            try {
                Invoke-Checked $cmake @("--build", $PluginBuildDir, "--config", $Configuration)
            }
            catch {
                Write-Warning "Existing CMake build failed. Re-configuring build directory."
                Invoke-Checked $cmake @("-S", $PluginDir, "-B", $PluginBuildDir, "-A", "x64")
                Invoke-Checked $cmake @("--build", $PluginBuildDir, "--config", $Configuration)
            }
        }
        else {
            Invoke-Checked $cmake @("-S", $PluginDir, "-B", $PluginBuildDir, "-A", "x64")
            Invoke-Checked $cmake @("--build", $PluginBuildDir, "--config", $Configuration)
        }
    }
    else {
        Write-Warning "cmake was not found. Using existing Release DLLs."
    }
}

Write-Host ""
Write-Host "== Finding plugin release DLLs =="

$dlls = @(Get-ReleaseDlls)

if ($dlls.Count -eq 0) {
    throw "Could not find any DLLs under apps\mumble-plugin. Expected them in apps\mumble-plugin\build\Release."
}

$pluginCandidates = @(
    $dlls |
        Where-Object {
            $_.Name -notmatch "^libcrypto" -and
            $_.Name -notmatch "^libssl" -and
            $_.Name -match "(mumble|plugin|tactical|radio|bridge)"
        } |
        Sort-Object LastWriteTime -Descending
)

if ($pluginCandidates.Count -eq 0) {
    Write-Host "DLLs found:"
    $dlls | ForEach-Object { Write-Host " - $($_.FullName)" }
    throw "Could not identify the Mumble plugin DLL. Make sure its name contains mumble, plugin, tactical, radio, or bridge."
}

$PluginDll = $pluginCandidates[0]
$ReleaseFolder = $PluginDll.Directory.FullName

Write-Host "Plugin DLL: $($PluginDll.FullName)"
Write-Host "Release folder: $ReleaseFolder"

$releaseDlls = @(Get-ChildItem -Path $ReleaseFolder -Filter "*.dll" -File)

$CryptoDll = $releaseDlls | Where-Object { $_.Name -ieq "libcrypto-3-x64.dll" } | Select-Object -First 1
$SslDll = $releaseDlls | Where-Object { $_.Name -ieq "libssl-3-x64.dll" } | Select-Object -First 1

if (-not $CryptoDll) {
    throw "Missing libcrypto-3-x64.dll in: $ReleaseFolder"
}

if (-not $SslDll) {
    throw "Missing libssl-3-x64.dll in: $ReleaseFolder"
}

Write-Host "OpenSSL crypto: $($CryptoDll.FullName)"
Write-Host "OpenSSL ssl: $($SslDll.FullName)"

Write-Host ""
Write-Host "== Staging files =="

New-CleanDirectory $Stage
New-Item -ItemType Directory -Path $StageApp, $StageAppPlugin, $StageBin, $StagePlugin, $InstallerOut, $GeneratedInstallerDir -Force | Out-Null

Copy-Item $PluginDll.FullName $StagePlugin -Force
Copy-Item $PluginDll.FullName $StageAppPlugin -Force

foreach ($dll in $releaseDlls) {
    if ($dll.FullName -ne $PluginDll.FullName) {
        Copy-Item $dll.FullName $StageBin -Force
    }
}

$IconBase64 = @'
AAABAAYAEBAAAAAAIAAUAwAAZgAAACAgAAAAACAAzQcAAHoDAAAwMAAAAAAgAKAMAABHCwAAQEAAAAAAIADdEQAA5xcAAICA
AAAAACAApycAAMQpAAAAAAAAAAAgALsMAABrUQAAiVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC20lEQVR4
nG2TTWhcZRSGn3O+796ZyXQcpk2NSXSgabDaZlMLsUoXxa2GihAQ3LhyUxDUjSgYCt3UbUG3FheiRVz4s3FRsEhjQRd2oaVR
x1iTNiaZH+/MZObe+x0XaZoUfDdncc55X3g4BwBYUHYliACImYmZCSDbLZOdofn5z9z2MAsK58LU7Nxz3rs3h91uvTJRl6Mv
viJXL7xNoVrFRTGWB0PE1PsVxF28de2LrwEVgCNPnzmd5emVXtLBLDBIOpx49XVcHPPLV5+SrK0SFUpghjpPsTjC5FPPnP3+
0vkPFCBY/k4v6ZAOtwZ5lobKgbFw8/OPw6Hjp8L41EwYKZZzUcnMAumgn1IsWpYOz7/xc3bcA5Ln+aSF3LAQVWqP6GPHTjD2
7Ck2V39jeu75UKsf0vUbP11dunHtyOjUE2NxpUqeDdudpZt1fw9EQERCCFYsV/h3c414429cXED7Zs27f2mhVO5YyJfVR2Mi
AmY5Pso9gO1QNkNU6Tf/of3tN1T2j5KnGc2V2zw8PaPOR767sUaZg+hDtdGQZub5H6mLiGs1SgcOkucZUbOJ5QFxztJel1Yv
oVwbHRyeffz6gwYChuFcTPvOMneW/0RcRBQXEaeYGeIclqW0GkvJuxPSfsBAREiHQybqk8y89CGN7z6iQAeNyjSWfwcBMcNE
EBEdf+E17+8H34OhqvT7fVp//GCdjRUcW+airu1E2G6eufWm7UDU7WpEUUyn3eHKpfdE430Ew0dxgUenjwohZHv2FcADpurW
RPRJ0CxprUcTU8esVK21VLaPJy6Ws27SXEVkxkKeiTpVdRu3Fy8PPICqf3+kUj1tFuKkvUnj1x/FO18MZkMBDVi2lbRf9nFp
RETYV92PuugCEO4/0+HZuTMi8lbI0kkLmQYzDyJgiImI80GwoYviu5hdvHX9y09gQWX3nc8FgJMn50sAhcLIHl7QAMYHPVlc
vNzfu/MfoR9NMuC8nhYAAAAASUVORK5CYIKJUE5HDQoaCgAAAA1JSERSAAAAIAAAACAIBgAAAHN6evQAAAeUSURBVHicrZdZ
bFTXGcd/37n3zj4evMZmsc0aAkkIkA0onSBeEhIpbVSoUkXqSyNVrfJWpVEeYqh4SVX1rX1oRKW2ahKgbdo0ytZG2Go2FZo2
lBCHzRgDxngdY8947nK+PoxtHGPSSdW/dKWre8853//bzycsDCGfd/LAAw88YK9/3gt7Z1733rBpIXR2dpougK6uCNBq9hhE
qjr8y6PDzP8iNy7YZwGnee22R7O52l3GcZeLiES+T2bxMrY/8yPe+8l+Cr1nceMxsIqdf+o0jDEaheGl4mTh7Usnul4BJtm9
2+Hw4WghAgawXu2K21fctuFAPJm+158qEQY+IkIUBiTrGvn6C7/ixKFXOHbgp6TqG7BheKMes1AcN0Y8kSLwp7r7z3d/d+zi
ia58vsPt6toXziVgAJtpXn3bstUb3kOpHervDW10fY04DlNjI6x75HF2PLOfl554kMLlC3jJFGpvZoMKCzGGuqalrpdIhoOX
zz549dTRd2C3A4cjAYSODmHfPm/NfY9+4Hjexiu9pwIvnvBEZDZqBDCuS2l0hId//EtimRomBwcYPtfNR7/5GYncImwUgern
Im1GQ79cimpq6kzTmjsnN37/6ed/sXPp/t2H1DGQd9i3z7as2fJQIlOzcai/N/TiCQ9AVUEVAaIopDQxjhp4a+9TeNks6x7b
Aa7D1ESBcnGCcnFiZo8yvVdVUWtJZnKOW1uvo+dPZXqPvPHN51V3HN4jkcnnKwxTi+oe9ctFtVGIzMkCESEMfJKZHCs3bGP1
3TtoabuVS++8iRkPqMs1smpznpV3baP99vtApKiqMptJIli1lK8VaN2yQ+vWrNfP/vjiQOE893/vyEDGzOS543jtoe8LIHpd
OmHgU9PQzKad3yCdzpFK1lC/ZDmFs6d48wc/5MqxD6lf3E48ltKG5ja2P/Zkt43Kr0jF+KrWctuuPXjpDJ+98TtZdu9XxQZ+
5tpg6WK2peku93MhOw8iQhT4tK+/j4sn/0FRy2x5tgOrgohT2WQtxoPS1RF5d+/TeuvmHZu2PvKtnx85fKA1W9e8uTQ2bIvD
A2ZF/kH+9dIL+FNFFrWudCav9vWmsmtWufOF3gARxBhCv0y6qZHatuVYa4CKjqpgPIjHcyTSWQ38KcnGcglbnuoFNhvX1eGe
U6zM7wIUf2IcL5kypcLwlEDivxMA1EZ4yRSDJz/mxV35Beqp4uDgOh7G8dDIWkRcEcFGIUs3bmHswlnEcUnVNlAqjEaZptYa
hfGqCFQsYSheG2XF2vXUNrYQhT6IgCquF+fCmZMMXunHmNlqq2otsXSW0tgIPe/+hZYN92CDkLG+c1G6rn4Vhg+qJzCNWCpN
IpOdrZCqSiyWwIsnKik4H9bS87e3ceMJWu/Ny6evH9La1pWrEbN08xpO3NAcvgiqCtYyN8dnc10tC8kHcJMpjBfj5J9fZmKw
n3VfeyKVWRw7uEck+lIEXC9OFEWEgU8Q+IS+T+D7BP4UILheDF2o46piw4DytTGtWdImQ+e6z+9vln+LMVTtArUR2dpG+nr7
OPvZGeJxr9IDpgMtFk+RyixCo5v1BcGJxSkND3Lx/SOOqooxRqsmICKUfZ9cTZqGZbfQNzCK68VBLfFkEhtZxkeGuHlnrFhC
jMFLphARFZHqLCAihGFEbTbJY08+i1O/mv6jh3j19we58+4tLG1fBQIfvX+EMPQxzhd7dm73rCoGjDEUi5Ns2bad/tw9HDy+
iCVbvsOyljpq6poojBbwyyGNzS2EUQjGqebY6gmoKl4sTs/Z0yz1Jtl6K4QDHzE0eo3yVJG6hnrSmTQThcLcOlAVqnKBtZZk
Is4n3adxf/ssbW2t/OnDD/Ejh+7jxxi41IuNLFf6ztN+x/3YIPjyBObcPRaEqpJIpDjx6Rn++fFJkqkU8XiMwA+43NeLkblm
j+ALo3EBAqp6U8eJGKIwRFGSyYSmkgmstagqxhhisThiHKYC39ooMiKea1XDmyozh5zp7Ow0ANZGl13PU0DnUy9eG6WupZUo
8InCUMIwFGutqKpYa8VaK1EYiBuLudmGJoYvneqNxZMN06W5cpyAqqrrxVRteBXgueeeM27XtJCJ8bHXmxa3Py7GzPpCrSUW
T9Jz/APWb3uI27c/rMZxL7ueN6mqc6JNFFGNJdPloDxx8Ojbf9hUc0vbVhsFFhFznQWaTOekMHrlLYDXXnvNqVxKVUGa0mu3
fuW4tXb54KWeMJZIXnePtYShTypbq6B9qjqkyqzLRFRFjAR+OShNFEwyk9s02yukcm8IylPRosYWSaQyEz2ffLyuNHL6Msxe
3CoDSW3rhm2L29d2+uWiOzJwMQCMiAhI5XYUhYiY6clJ+XycKSIGYxxsFEQzP7XiB1tTf4uXzdVz9cLpPVfO/P3wzIAy54QK
iVzrHTuXtK494MbjbaWJ8elGM6srVY53s2tdL0YyncNGwdDAxXNPDZ079vLMTDDHNdO4PjbVLduw89upVPYh4zitMwpWKXlG
vgKotf3l0uRfez49+mumRvvmj2YL4IYB8v83qe7eXXWNlnw+73Z0dBiRiv//16ejo8Pk83mXm5T9/wBgVnv8FKjEnwAAAABJ
RU5ErkJggolQTkcNChoKAAAADUlIRFIAAAAwAAAAMAgGAAAAVwL5hwAADGdJREFUeJzVmntwXNV9xz/n3NfuarUrWQ/LemD5
jR81dgrETgyCDgM0DVNeok2nYaBlkpaZtkmHNtNJqXDT5tVO2gzTGSYhDGnaMLHbUiYMNCUJVjAQwGA7trGxLSNbtt6v1a72
cffe8+sfuxaWLBnZUqbtd+bO3t17zzm/7/k9zzkL/8+h5v9eu6ZtcNb324CbHtvDHvbQ+dhjC5eqs15gtwFk4Z3Rbi1CJ1c4
dLvFh0zypR6efyaAE6lasS2WTO5wvehaNGDgws87H/8BvQfe4NVvfgm3MoGE4WXLq7QWv5DvyaUn3sgOn/gZkCk/Oj/SRbDn
6GuqQaJx48NVdcv+KLGk7upINI7Seoqb0priZJqm7TfRfG0LlfUtDP58L2EuB5a+AgMQxAhFP8fE2Oqe8aG+fx47c+Bvgdxc
JGYjUHoxvqy2vqHle02rNt7uOC6pkQFJDfeHxUIOESmRUCDGMDR0jqUf/TiNW9ZR9FxOvf4SkWQ1iCACYkLm526C7XrEKhJ6
SX1jS23DVV88F0/cMdT3/u8Ux3qOtHV02J07dwYXtpjZa+l7IlHd1HzN6y1rNq8dH+4Lhnu7tYhopTVa6ekNLItCOsXSDVu5
+4nvMtE7yLMPf4pCJk3oF1Ba40RjIPNTh4hgTAggVTXLwrqWlXZf93sTQ+e627JDJw4wQxPTpaFDAVJft+6ZljWb1/afPl4c
6OmyteVo23HR2gKlpl1iDJFkNf2H3+atp55i2eZGrnvw8yhg3W130PSR7SUNaH1R29kupTW242I7rhob6bPPHNsfNLZenaiq
Xbr7/v88cqPS2oiImoVAuwU7TaJx/R80rd506/hQX5AaHXTcSBSQstnMDhOEeJVJDjzzBCd+fJBfuedOtn76YW559Ktc//t/
WtKEmm/ELmlBRHBcj3wuYw/0nJC6hqtWjx470tlxNuxQSknHy2LPILDbAHayZtmfO44rw33d2vUiiJnV+aeglEZphWU7IPDq
43+DP1lky30PEBRCipNptLZRWqO0hdZWORB8OEwYEoknGenvQTuOHPzu40M9+7tuffSM3LXzZhW07xKr3FO7BUikumVbVe3S
1tTIgBhjLj1KWeWFXIZcepzJ1AiBKdLzzmt0/uOX0RGN9ixCCcmmx8ilU+TS42TTY+QnJwCFUkpmdQ6l0JZNkMvSsOlX+dhn
v6AGuo9LTdOKmj1f+8JPlcXvPfzy4fiudkwpCrUNKjohlljS5kXjany4P9SWpec0G6WQMMSYkFVbd5CsaUAQFKoUOYuG4PQw
yeY6airrue4Tv4vluYgxKBTZiTG6DuxNG6i0bBcxgZRmpNS3CQKK/iRuZYL3X/kRK9tuo/Xm3zC5k8ftgUNvV6PYF6lcc69S
6ulps+x4sTVKW/j53EXR5gLpEWOwbJtb7n+E1dd8nEg0jqc9HGXjKgdXu7zz7W/w00f/giPPfIeIF8MRC1e7eJEKaV67hbs/
//eDEc/7auDnR5S2FSBKaYJ8jto1G9jyqc/gZyaw3AhvPvkNVuy4RdnRKPHquo1Bgecsx70RZkQhNY/Uo7XGz2XY3Pab5CfG
2bv7Cd599b8Yyo8wrrOMMcmYypFLuOSrXCYrLMZkknGVZTSc4NibP1Gv/fu3wtOH962663N/1zjSffBzCjIohYgR24sweuo9
GjZupfnaG5AwZKL3DJnhQZq2bicMitEtrbyLpqpjn8TmysRzQsRgOx61zSt5d++L2LbH8ptuZdtf/RlhnjnzlRhw4nDg8ad5
b9e/6DPvviWNazbdbkf144XJ1EtevOouExRDZdtWfmyEI899n3W33cXZt15BKc3gsQOs3noDCuXep5T/yC8kn4nQOr9wMBNK
ISJoy0bCEMvz0G5JeKXnuBRoB6xIBBOGaMtWoEIE1xi/9wOiBqciTqr3NJbr4USiCJBPjaE9D6XLrgJiC85la2D6rBrsWIz+
N1/nwDcT2LEoMlfUVSBhwJmfvIQTi10YnoULShqlFEE+R7y2AQkDgkIeBbgVlUixOM3GfXM+Cl05BbRlkR0bovNrX6To+3Mm
LBHBsmzqWtcQTSxBpjFVMu0922X9J3+LUz/7UVnbhrp1m5kcOIcYU3xZxH7hMFHboXuBBBSIMDE6wNXbbqC+uZVgFhKCYNkO
qZFBju9/E6+iEqWiF3enNUEuy9JNHyE7OkTXnhexI1EiySqSy5rpevb72I6b++9eVish8/X1Kr1AAmUBxRCLVVJdU49fyF9M
QMBxHEK/UC4T5ujIGOxIlJGTRxk4sh83XkludJjtn/0KPfv2kh0ZIvT9TDDOvWJ4HeZeD1wWlFLkc5Okx0cp+gXUjBwiCLbt
kM2k510TubEKCpk0K2+8HSdWwS92P6VXbLpeEs3L1yuIB9nU3SKiFoXADDpX+Gw6jDHYnsdI11H6Dr2F7UVUITUaXvvgn6yM
VPPY1zdWjW4XsRaFgDEGL1pBZdWSOUxIcByXfHZyhvNeAiIoyyaXGsOyHcJCIbz63gesSE3dwb9uVN/rENH3KRUuOAoppYnG
k2TTKUYH+wiK/lRZc6Ewlu2QHh/BiyWwLPuS5fmF7bRlgwLtOEyc7eadXd/2QdTOctWwYA0YY0jUNDI0OETf2bMopS8WTn1A
IlnbiLmsBX/J6ZXWDB96BykUFChBlRY1ixaFElW1+EFJMM+xMcYglByc8gJFmL16ni/sSBTU9F2eKyslZsHExAT1SYfaSptU
KkUYBpgwwM/nCIJiqZRQiiAozs98ZkGp3XQfWrAGlFb4+RwPPfDbrLj+TpQyHO3cxb/ueg7P80guqeGjN/4almVj2RYDvWfZ
t7fzMuLRpbEgDWitSacn+eSv30zDDQ/y5L5qnnq7htW3/iG33ryN0dEx1m/eAmIx3D9If08vTVetpHbpUorF4mWtk38pBFAK
TMC6jVvpPBYSt4s4FNnbZdiwaQth2VyKRR8pbwz4vn856eBDsXAf0Banjh/mY2ssUr5DLnTYtlJz4r0jpXLbGCKRKLbt4Lgu
rudhwnnmgnlgQT5gwpDKeJznnv8xn2lo5KFtd6CVcHrvv/HCS69QW1PD4f1vc92OOPFkHMuy6Dp6iOGBAaLxxBU786IRgHL5
63j80xNPs7b1BUIjdJ0ZJBqNopQil51kz4s/RGtdMiMjWJa1KMLDohVzUFER42TPKEopKioqSnlASusFy5oeuy8vkV0aMwio
y5yWD7zRGEPEc6bupyAyx06BQqkrOcCYLuM0AgLzO8yY2hcNp5XO8zWLUrkRYoxYgAZzOUSmyTgtCgV+7qyIwXbdOYVRShH6
BYr5HNHKagrZCcQYTBiKCUNz6SswYozJZ9NBJFaJ7TqjQRhMatuNXFLkUlEnWlv4fq60AdB+n4bzGuisF4BcJrW3WMgRiyd0
fjKNPYuziYC2bI68+iI77noIExaZTI2gLUd9eGZSiIQk65r0llvuYeDUoScpErXdeJsYA2r2DGFMSLQiiSDkM+lXARgsndep
qZ5L5Wmsdett79c0NNd1H31HbMeddXtRKU2xkGXZyo1suuETOF7MRGKV77vR2PiFW98Xi48opbC9yMiZQ6/9x7P/8MfHalu3
fMVyo9vFBKa0ATPLWH6OppUbTNEvqFMHX9/gZ/qOUT4n+GCw9naL3bvD6pbNX1p9zfa/HO3rCcaHe23bjcy6CFFK4xeyICJu
JEYY+KeMCY4hXNI1S8vPTBERFUvWbteWXTdtb3TGu2EY4EUqgpa1m+1TR956fvDEG3dAh4ad5kINlO87FOz0GtfveHv5ui3r
u4/tD/x81rYdr2xKMmOA0oSJmNK90h96pCgipYMSwIQBIuGcMx+GRYBw1cbr1MDZ9zPdRw9uJt9/piy3gelRqHzwRW544OQ9
jhd9Y/nVWyv7Tx8PJkYHLa0tpS0N6Cna5wOkKu9rImZe4SQ0U3lAX3RYUD5iMqFPtCIRNK3aYI8N9zNw7uSnyfefLh0F7J7q
YLYJ04CJ1S7fuqRhxQ8aV6xf4+ezjA/1BrlsmrDoL2IpNsvglo0XjUtV7VK7IlHDwNmT40M9px7IDB5/bqbwcxGAUqwNIVld
u2LVl6vrm+9PLKmPacta1Cx6MUrmJUBmfDgcG+z94cBA1yNMDHXNJvylCMCFp4FesjVR33J7LJa8yfOiK8+vRxcfWorF/Llc
JvPzsZHe55kcOFL6fXbh5wP1v/pXAzrKTrdwaNra7NJ/F0T9Uq/2dou2NnuxBP8/j/8BEinfRCYGi2MAAAAASUVORK5CYIKJ
UE5HDQoaCgAAAA1JSERSAAAAQAAAAEAIBgAAAKppcd4AABGkSURBVHic7VtpdBzVlf7ue1Vd3a3uVmuXJVveN8mysXG8jAEZ
EsAkzBCSiBMgM2QSsBNmYjhJJjOZgcgKZGPCMCFhkpCELJyYCc4GJCQmA1gkLMbYxg7ehGxZtrBs7eq1upZ350e3ZMmyNktN
Zsl3Tp3TS9V7935133333roF/Bn/v0GTuFagtpbQ3j7qGHVbtgBYjx1b1qNhEpONioZiBrYpAJytKfpBqKnRMDnisoe0bGIi
l0xAkVoJbHP7vwVKqxaD3EWCxFIAYOYhYwkhYHZ34q/+bStKly7Fj25YD8dxIMSE5BtZcCIWQsBVqoUUHYgsLNyLhgZnkKzj
sojxEECZQ5XMWVtsWpG/0XTjel9OcLU/EJb+YBhENGQmIgHHTKB4xRqs/sQdMPzAvq1P4s0nHoPm9YNZXYDK54ABIkIyHkEy
3odEtO+gbZlPE9MPe1r3v5E5SwAYdTJtjGkoPRU4b/rSDzK595fNriwLF5ZCCgnLSrmpZIyVGkq0kAJOykSguBQkgXiPQtGi
pTj80x9CGAbYdc872YRAABQjGC6g/JJyQSQqo72dlR1vHd+cW179pXnvWfuF3Q8/bGMMEkazAALq6OKNbbLp6Ze/nlc4bdP0
uZVwXNvpOtUion1dZFspYjXC2ERQtoWr6h7EgiuvQLwriqc+fSvaD+2D7s/BiNdNEEQEqenICYZVwbQK5Q+GtfbWZpw+8eaL
Wk5ubefh37dhFBJGIoCAOqqrAx78/i+fL5254LKS8lnOqeONsuv0CQIAITWQECMzSAKuZcKbW4Dr/+MnyC3PR9v+Rjx5580Q
UgIkQBn7muySYGYo14FSCsFwIc+YX+0mYn1aS+P+Ns0R686c3NW88Vu79Ic3rbTHSUDa4eVOr/p22ezKjYUl0+1jB3fryUQE
um4MTDoWhNRg9vVgwdXvwzvvuhdCAq9+73t49Tv3wQjlwk6aIEHQDGNkUcYLIhAA17FBUmLWouWOcpXWfOi117qPv34ZgCSY
CURDBD+PS04rHypbckO4qHxjSfks59ih3bqZiEL3eMHM41IeAJTrwMgNo/GZn6Pp2WdBArjoxltQvHgZKlZfjvd/+/u4su5r
0LyZJUGTICEjl9R0gIHmA7s1byDoFhRNX7n8g5968ot9fA+IuPZxlqMRQMA2VTJnabHh8319xtxKdaqlUSRjEWge48LWrVLQ
fX68+PV70NXUCm9IwyV3bEHpkhWYueZilK/4CwhNGzepY4GZIYQASYmWw6/L0pnzVKy1+V2nD3Tf9bkT/KltN5Bby2dJGEpA
TY0EwAnTvqWwbHax49iqq+2EuGDlMwJJ3YNEdztefOjLcExG4fzFmHfFtYieVnDMJDBFyg+e00nEEOvuQDTSDb/ud7f+9Ybn
lIvb79xlXreNyO23hKEENKxXAITH8L4/XFjCnadaCKAJr04ighBy4GAGfHkFOLnzeRx86gl4QwTN8IGIQEIMOXfwQRcYNDEr
rProJxGaNh1tRw9RXtl06Sbjc5tf2nOfETAe+MTTjUblATBoCAF1AqhXwbJF83w5ucullIj1dkkhJ2aeJARsK4V4pAfxSDfi
kW4kIt2I93TCdm3seOAutO47BOEjuERQYCSiZ88dfJixyMCYY20VJET6IIKTMsEANtzzTVgpkxJ9Pe60+dUzf3zzxaeNIJq1
4oq/r68nVfcca4MCoYMEAKx4mS8Q9tiplOvYphTSg/HmGEQEMxZByayFmLtsHXSvb4hzIyFgJ+NQx1rhL58D1wI8NuGS62+D
kzLP3nFmkJDofOsY3tz1fNSxUzkeX0Ao21IgGm4WREjFIpCaDs3rg8eXg5ce+gJKK5dj9abP4NgvH+PQtArWjbyVJeW4O94h
H6ljfgCAOmvdNTUaGhqc4LSqz89ZsvJusHJOvvlHTfcY47MAIjipJFZfewsWrFyP9pZGuLYFknIQfwwS6SjRTiZBRAARjJzg
0B2AAGXbHC6dgVBhactvvlP/41NNB1b5gvlXuk5KAWdJICFgJeJY+v5b0NPShBOvvgBvMAwnlYS/oATX3v9D/OErn3W9QpdN
B17d0dv6xuWf3G02gsQHvrqU9g8LhYnYJSKcG96OqrsQMONRVK3bgEWrrsD2734JsZ4OsFJwLQskBinHPGCunOYErAaFxpwm
QPP6yHVstfKam2f95cfvfe/XPrxso5DS1r2Bd7NyhpAAVnAdG5d98l78bNN74aSS0Lx+9J5oQvvh/Vj87g+g8RdboRmGUI5N
rPiIFLgCwHACzs3qxgNWDN1joPrSa/HKUz9CPNINXzAXRm4YSz6yCXooCB5P+M8M6SWcfO4FtDzza8hQWLz2mx+7xbMWVL1n
84NX/+y+jXcVzVs5Uwi9qp8EVgpGIIQ9jz6EksrlWPnhzdjxr/+MQJEPJHWc2NmAtR++A01PPo602wOz4j1KYgUwdjI0Noig
HAc5ufnQDR+iXWdg+AOwohHMvf4GzNqwBqk+gOTYQ4EB0oFA2TycevkFOMkkpKah70wrF0yfswiA7aYSv5H+3CrmjDpIb3tG
MIzG7T/HpXfWw59XANe2oBtedBzeDwgBI5wHt8lKmzW7e4m0q6aGgH7ZM36CiNKfmSE9BlwbcEwXpI2DAQbIAUjKdL6Qie5I
SIJSNgDJltXBPh6yO3Nmrp6WJrBS8ObmId7ZnnG6CYAIQvcAmVhGECRzOjmaMgKGKsKQXi9O7/wDpl92aboGkKKxw33F0HwC
rQ0vwOztzeQIGVA6dWJB55dZKXj8AQipQTnO2Z0nI8/gjcxRcLSM7lkhgJWCNLzoaTyC391+K6RHA/PY+mf8H5x4AlLP7D7D
ffGwX4QQSER7sXjlB5Ho6UT0zFvw5uYhFYsiWFYBAmBF+yAyu76UVEhAL5AtCwAAZphmBLFT7XBdd0LRpOEPIFRYBl3zYcwY
hAiubSFUNgNLrvsQXnn4PgAEIgFlpVC+Yg3Mni7YiRiEphMAIhJrGdgHZIMAHhQN9nXCFwzB8PrHHU0yA7G+LsT7uhAurhjz
fCJCKhHHJZvr0H54P47ueBr+vEIo14HQdMx4x2U48swv0ktDuek6oRDVBHwJyKIFEAFmIoHLr7sZG268FbFIL4QY2REyGFJq
SMQiePCfNsG2nXFlx6wYHn8Aux99CGakF0YwFwAh2dOBJe+7BSQlmn//O5TNrYIViyV+xZy3Y78qcQReALJIgFIKvpwAdjz5
n3j+icfGtQT6fQAI8Hhzxmk1DJISia4OCE1CSA22mUDerPlYs/Ef8PRnb4NybAhNR7y7vWdnKz7FjH0PLKHumueH5AJTCyEE
rJSJZWsvR/XqGqSSiaER4TA1MteYJp55/BEopTKOfxxghtD1zMf0FnzpnfXYu/XbaN39IqbNX0J2MoaieVXVTgqXKzN5DQCs
Xw+VPSf4dmOQtUiPgT98rR6xM2/BCOUBzCLZ0+1esrmuWjPwzQfWBPbVPs6ynsjN6hLwGF4c2vMKDu5+OYtL4PyItZ+CZnjh
uA7MSJ9adfvtonjVpY3Cg8/UMYstmUwwawRomoZkLIprbtqIDTfehnikFyRHLnAw9zvBKB78x1vhuBNYAueB0D1gAG4yicKL
1/H0d75L/PTjNx0/2rAtVscsKFMcnXoCKJ3dSd2DvJIZeGn7L/Baw3ZgXKVvArOCbdsI5ZdNrk7YH5prOhJtp/Dyl+vR0fiG
B8xUT1sGTsuSBaTzgWBeMVJmPB2ajuIAz7kSuUUFkFLPFIEmVy4nIWDHo7B6u+Dx5nC6LF43MGhWnSAzw/AF0rU/EBjnDW2H
QbEC8/mLPxcCEgKk6VDnycmzvgsQGMpVsGwXmhTQNAl1ToV5IIMc9H1SzwjOhxGW09RQPAKkFIgnTCjXwcxpufB5BPqi8WGP
yC0rBaUUlFIZH2DBcZxJOcHxImsWIIVAT28El65eio/dfhuSsgw5og/PPPVzPLL1KeSFQ2BmWJaFFWvWYX5lNSzLghACjm2h
YfuvEYtEst6KkRUChBCIJ5JYvWIxPv25enzn1QCOnQFCvhA2f+gOAIwfPf5bGLrE3EWLsHDJcjQ3NkH36HBdF4FAEDVXvwe/
+snWrBOQlSVARLBtGzfdWIttBwM41GIj5AFicRcPPsu4+rqbURDOgWXZ8PtzkDJTsKwUHNuG6ziIx6LQdQ+EJsflNCeDrBCg
mOHz6MgJFaK1UyE3R8JRQMArEIkDCQ6gMD8Ix1VwMwGPEGLgkFJCKXfKH5mdD1khQAhC3LRw+mQT3jFPoL3XhWKF9oiDOdMI
htWGk21d8OgSmibTD1RME1YqhZRpwrYs6B5j7ImmAFnxAcpVyMnx41vf24qv3rcYqJmHXUeBypkCtVVxfPXz34CZcuHzetFy
7CjmLlyCRdXVYKXSsYPXiyNv7IHruFnfCbJTE2SGx6PjTGcvPv2Zz+FjH70BN1bMhhnrxBfvehI79x5EXm4Qihl9Pd147ukn
UDF3LhzHgRQSyWQCRw8fgscwYJvZXQZZzAYZOX4fuvui+Jd7vgG/V4NpudA0HXnhIFw3HQx5PAZikT68/srL6O+ZEULA8Pqy
JdoQZDUSVEpB1zTk5+VCKYbXm3bq/coDmSxQ0+DPFDT6f2Pm/92BUD+YGW6mLc4dwZon0nYz1Ri2C9A5TUQTR3buGk8NQ8Of
KQw7g6Cf7Y8cP/ozt3QWN3UkEBFYuSyknIS1Duiin/vPcAIUN5vxCAwjh9JZ2tjDCyFhJqJQrguPzw/XsdMtLiQmdQgh4To2
fME8ivV0nMnIOyF2mRmGP8SWmYTrOMcBALUHz1MPaFivgAZIsvckY32qoKRcSE3HmJbADCElEtEeHH9jJ1ZcWYtnHvkylOuk
ewAusAuSiJBKxtXs6rVaQdnMyM/u/7sXAUDo3ouIBJhdHg8VRIA/EEQyHoNynd0AMLjFf5BZ1SsAVHQKB/t8fW+SEAv9wbCK
9nYJbYw2NsUujJwgXvvtY3j3pjpcs/FuNO35PVzbgpCamLBfIIBdF/nls8Xci9aljuza/u/H971wOKeookbz+K5RyuHxVEuU
YmgeA15/UJ45eSzFcLcDGLjZ5xAAoKZGNjU0pEJm1a8iPV0LC6ZVqEh3u0gvnVEsgdM+gFnhqYfuRtW6DZi9bC00j1cFcgsO
+QKhrok0XhDApEnYZrLpuR/c++vXtj96NFg48wpfbsk9RCLA7PJYFRMigmOnUFA6x3VsS8QiXftjbY1H+pvBBs01BAKAyq+o
rDT8+a8vuGitOH5or4hFuknT9LG3qoxMqXgERIJJSla2ddQy4ztZuXEwJMbrXQWQSiRcf26e9AXC1ULqq4hIMKsxlQeQ6SsQ
WLj8EqfteKPW0Xr8b/tO/fEH5773cJ6BMn3C5VVbSmctqisqq3CO7H1RQ6YDczy70bndXhda2+svlSnl9vcRDTw6GOs620ph
TuVKVzHL5gO7nu35yPVXoR4YfPcxwmDpNvmL2+TR9lca5lStXCs1zTl2YLdGRJBSTjRoYYDVpPJ6Qn+RcEyz7y+plc1aqMIF
pWjc91IPiFd3NO0+eq75Y5QBBTJviDjK2j9r8fISrz9gtxzeqydivZCaPuqT3rcLg82BWcFxbOi6gRnzql2Pzy+bD+5GKhG/
svvE6/91run3YzRGBQBVOPsdC1zlPDpt5oJVRWUVbk97GzpPt4hUMk6spq50fUEgDDRiejwGh4vKVFH5bE5EerUTb+7rdlzr
pp7j+7ePpHxmiNGQNpn8eRtCnGq7NxDO/0RpxXx4/QGkkgk3mYhwMtpHf5I4Pt0xBK8/xN5AED5/UHNsC51tJ9B9+uR2IfXN
nc27GjGJV2b6MTBAQUX1OxVosy8nd30ovzjkC4Rg+HLelqxtGDL2b5lJmIkoIt0dTiLavctxnO/2tb7xSPqkke98P8YrOQG1
on+w/PLq6Ta775JCLBOavjQjzdvMArMgguO4La5y97HLv4udPnjwrLzp16qmeNJamV4W/2NBaRkndMEFQaCmJk1E+h2DPyEO
EmraCQ0NClN/x/+M//P4b4h7ORo3rtFvAAAAAElFTkSuQmCCiVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAn
bklEQVR4nO2deZxdRZn3v1Vnufu9vaS7s5GE7EBIgAZC2JrViIDjQhRldFxm8BXfcUSdGeBFMSJu4zLqiIrjuI24RJ0RRFaR
SEgCpFkStuz71vty13NOVb1/nNvZOksndHe6Q/8+n/pkufeeU+fUr57nqed56ikYwQhGMIIRjGAEIxjBCEbwxoI43h2gP/pg
zD5XGgqPdNQwx7sDgwlBQ4NNfb3TLxcTw3LA98ee97HAYpAZPFg3EzQ0WCxeHBz4wdRz35xu7+wyRgVH3ZeqqdNY99AvuOFb
azj349P4J1ENtDH1zTfQtm5tv3R8oGG5Md38yuLsfv/Z0GCzuNbAIs0AS4cBJsACCxapff9nzPSGUcoUPyItyzZKzTMwz2it
MUYezZWFZVNob2baFW/n8tu/gOU4bH+ukT/d8hEEIG0bY4a4ZBUA0pOW/IElbd/3S8uJxJ/ajxANDTaLFysGiAgDRYCe6xqA
utnzaimoDxtEA8ZcACS1NoDBdhwE4qieTkhJUCgwfu7FzF/4NRAS5UE0A+ufWMbjX/xnhDEgxJAmgRACFfhorRFChm/NmCbL
dn6kVPAEbmzpXjL0nkz90of+vuC+HR0zY958bcTNGDVPa5OWMnzIeLIiSKQzxhghq+vGSSktzNFQQBuk43Dmpz6HE3NRnkZI
iQ58YqMc1v/vQ2x59H6cZBqj+/2d9Q8MSMsi29lKtrNdCYFpb97pGK1RSoEAAS1CiLsLBfGtrm3L2zhgYvUH7P66UBkCFqnU
zHOqY0r+WGlzrVEB0pLEUxVB3fiTRTyZkZbj2m4kitaaUiF7lLNUYIzGclxs10X54eBDWTKU9v57KK8IhBBoFZCpqmPUmIm2
1pra8VPQKjAtO7eo9uYdVuB7owx8NhYTH4vNOO+Du1cvvz/8df9Jg/4iQM8b13VT512D4idaB9WW7ZjqMRN1Vd04GY0lbGnZ
eKUCXW1NZDvbEELQ3rwDo/VRjJVAAFopai65kqmXXUChPRx0Ywy2bdHWvJNXViwmVlGNVn4/PWL/QiBQWpFIVZJIZTBAdd14
HDcqJkw73a47aQq5zjbTtGNTkO1sq5ZY99VOm3t/Iac/2L1jUWt/kaAfpki5Iw0Ndu2O4u+FkNeqwCNdVatOmjLLisQTGKXo
aN1Fd0crXW1N+F4RFQQIIZDW0XMwnD0KYzTzF36bCfMuICgYhBAIW1Dq7OA3H7oWv5BDOm5IsCEIAWit0VohhMRyHBKpSpKZ
KiprxhBNpNEqoL1pu9m2/hW00UJKu00FwftbNjzzQH+Q4PUSQAAmPf7Uqmg09TPgaq0DNXHGGbKyZqwwxtDV1kTzzk1kO1ox
WiMtOxyo8vr9WI00IS1UqYgdS/Deex/FjrqYIDT63IRkw+InefizN+HGk6F9MVSNQSH2Knaj0SokhBuNU103nuoxE4hE4/il
IlvWrgo6WnbajhsNkLxjr0oIx+GYbn/MHV+wwGLRIj1q8rlvsWz7ZyrwqhKpClU3YapVUV1HqZBn2/qX6WjdhQAs2yk/ZP8N
hLAs/HyOky98E/O/8G94OV1eUYQkePj2f2bjkkdwYomhawwegJ6JobVGqwDbjTJ+yqlU1o5D+R5N29br5p1bEAhpMPcbJ/re
5li2RGNjwDGQ4FgJIAHNmPp4bdJp1oEfT1XWBJNPPct2IjFadmxm6/qXUIGPlBZiAJdjQgi8XJb5d36Pky+6EL8QLqmEbQiK
Hr+84UqCYgFhO2CGpio4FIQQZRWhyVTXMmnGmbjRGC07N7PptRd923UdHfifa1r3zEKmTo2wbl3paO9xVM6Xnn7R0CChwR6d
sn+tlR9NVdYEk0+rt7XWbF27ii1rV6GCAKus3wdyLW4Q2JEoi792G6VsCemUZ5BviCQjNHz6iwSl4n6eBmnZvdpQhDGhXWPb
Np0tu1j/8rO07d7GqNEnMWnmGbbyPB8h/nnUtHOvZt26Eg0N9h3G2BhzFCb10cMCVO20c+/DiGtjiZSacvq5ltGazatfpL15
B44b4XWopaOGkBZ+oQ+qIJ5EBz5ed2doEpS7KAREUpnwL0MUPU4jhGTSzDOoqh1P6+6tZvPqF4RlO4HEunTnmqeW7PmBMQIh
jjgAR/nECyxYpGunzL1WWOIPOgj8yaed7VTWjmPr2lXs2LSaSDSGPg5Wdy9VkA+Xhj2q4N4brsTLdhFJZTj12uuxXAejQUhQ
ns/Lf7gX5ZX28SEMPYQqQSEtm5lnXYQbibL+pRVBV0eLbbRaXFU35Ya3/fgX7920as23Fr1rltcXEhwNASTAmDH1UZWwm7UK
ohNnnkFV3XjZvnsbW9a9dHwtbSExgY8djfHeex/FiUdRRYPBYMcEW5Yt5dHPf4JIMsMNv36MSAq0D9KBUjf897sux+vuRNj2
0F0xUJYESpGuqmHitNlIy2L9S8+artbd4uqv/jh76rVnJVvXqQfytnV9UKR0Tz3B4UhwFHRfEC5bE9YvjdGxTHWtqawZI71i
nq3rX0ar42xlG410XLxsN49/6TaCUgEjNUIK/Jxi+vwLmPOuvyfXshuvu0C+NSDf7pNvCyi0dw7pQd8Xxhgsy6KtaQdN2zfi
RKLUnjRVCCn1aw/+Ntm+WZcqJlhXRzw+ec/Zwr/jZQ4bdu8bARaEDodR08652Aj5Vtu29fipsyxjDNvWv4wKfCzL6pcHfD0w
WuHEk6x55Pe8+Ot7SVRZqEAhbZtcU8Cc6/+WSRdcQSnbje0OfSPwUDDG4LoRmndspm33diprxjBm8iny5fvuNY8t/JQodJCP
pYPbPv6secvCWcJbYMwhB6fvEqC+3rGMvFOrwFTVTSASS9DV1kxHyy6ktIZM1E3rgGTNGF789T1sWvoCsYyNUQpjJJFEgvr3
3YQdiQy3FeFeCBHaNmWjsGnHRgLfo7JmDFXjTzZr//KnwtM/+vEP3JTdka7h9598wVy4SAh1KBL0hQCCRYtUbZtdpY0+z7Is
UVU3TmqlaNm5CRBDKyvHGJChQdj40+/i5QogDUJKvJxh1LRpRDMZdDCUQ0UHhxACoxR+PgdCYtk22bJ7PZ6sIJmpUvHqusxj
d924DbgzWUNECn3nTX8xSRbBwZaHRyZAfX0oHy2uRwgrmkj7kVhCdJZ9+5Y19BIvjFLEMpVsWvo4L/zqXhLVdhh7kILA0xht
huPoo7wSbiLJuPoLKHW1Y9k2xkDzjo2owCdVUW0rr0DttPpbzq3lP1s38ljVZHlJvIabF71LqBsbewf/jkyAyZM19fWOMfpq
KaRVN36KlJZFd0drOZFhQB73dUMFAYnqml6qQAjJ8Bt9ECb0qlzyL1/mbd/+HhPPv5JcWwu241LIdlHMZ8lU14l0ZY0CUf3u
umlnZuq4Nd8KQvNPN79kqu45W/gHSoEjEUCwaJEa3akqwFwKEE+lpV8O6R632S8E4SAerpnQQZTP0vjTu/HzoSo4tLUv+njd
nu8NMoRAIFj98P/gF3yu+uLXmdxwFUGxgFKKrtbdOG6UaCKltQpkoqr2PbfXiBW55uCvmZOotg03ARwoBQ5PgLL41yJyI0KK
eLrCt2xHZDvb8L3SIOt+gSyvNLQKMFphdHCYpgj8Em4yw8anHqXxFz8nUW2HTqo9Yyn2CAOjVfm6R2rh94ByfwQMgsvTGI0V
ibD6wd/yyB23YMccLrvly7jJJFoFdHe145WKJFIZW0qJ0eZvGT8+Fq+xby11gdHcfOsaU3PP2QT7SoE+rQKEkIExxoonK3Aj
MXKd7ajAHzQCCCExWpHrbENrRTSewo3GcWOJw7ZILIHtuFSOncjq+3/JxsUrcKNgfB8CDYEK/9QaNxonEkse8ZpuNE40nkKX
+2O0QkqrJ7bdL8mbQsqDShmjNYnqWjYueYQ1Dy8mURPhopvvQvs++e52Ar9EMlOFtGx04DunzvuwumuSWJpr049XnUyV73E9
CLOvFDj8ArixUTF1agSjL8UYMMhwBg2WGAxnqFfMkays4bQL3sxJp9Qzbuos/FIJIfvQB7PXjy4CiXhtG84BS8CYMVz3ya+H
6uEIlzTa4EQibF/7Eltfa2T9C0+Z7ramVjeWHCVtxwqlgy47mY/hictqy3IjSMvGHLBe1cZguxGe/ObtjDvrEaZfcTHrHp/P
1mVPAKLHLlMI6Xa+9uTlGPOQeqZ7oZdNXSw019y4wny/fQN7Lnq4TgpAV+pMVCt9mW07VI8ZJ4uFLO3NOwZB/4eD7xcLTJlz
Ae/+1/9g/odu4+RZcwm8EpZlh2HfI7XybLLdCNK2KXVn8XMHtHwuTFKRR76eZdkEXomTT5/Lmz90m3nPbd/X866+4e7utm2f
UEHhV2jVLaQljyX2LKRFsaONcWedj5tMEZQKZaN1H5Q9nqXuLv769c9ggIs/cRdGSlp2bCYaT4uKmrHaCCLKy12CEOaV3/yg
MbubLmnxpmSSzKJ3CdWjBo7oAhPSMhiTQ4gKISQY04uVAwEhwCsWeNMH/pWZc6+glO/mmT/+nKbNa2jZvgHbcY+RgIea4n27
lhCCwPcYNW4ytROnixnnXSnmvu0fPjv1nMse+84/nPdpN1V9b7p6wmfsSOwcHfgKIfrkIhXSwst1MfXya7jma19jzaNLefyu
T7Jf2LKnp1rhxOKsX/wgG/96HZMvOYdR00/Da25CWhY944SxsgiomPvpIhHurpjArS0b+Dvg6zc2Yt8Dft/E1FFu2ni9EELi
FfNMOeN8Zs69HL+YZ8nv7uHZP/2CXRteRSuFV8jjFwsEXokg8Aj8vrbSIdphfhN4BF4Jv1jAK+TRSrFrw6s8+6dfsGTR96WX
z5pR46Ze8eZ/+Px1Xndrc/vWlbcGpcKz0nassl3QBxikZePls2x//iVOe+v5nP7OD5Frb8aye89TISVaKbY3LsGNC858z41Y
biTUPnuvKQEWvUsoo+kALCGpOGojcHAh0MonWVnDJdf/I6V8licXfY+trzaSqqzFdiN7xLV0HFSpiNfRidc1gK2jE1UqIh1n
jxvWdiOkKmvZ+lojf130PVPMdZo5V1z/6ZNOOWeCUkq3b115S1AqPCts2+qLyDRa48QTbHzyUZZ+95tkm0qc9b4bmDTvMord
nQi5vyDRWhGJJdi07HG6d0lGz6onUTO6bJzve+HwpTqSn7RvJivgY3esJdXjExhyURBpSXLZLKdecBWjxp7M03/8ORtXLSdV
UYvaJ8VbSEmpo4Ox8y5k1OxTUEUzMIapMVhRQcvKV9mxbAmRTAajNcZolNLEk5VsWrVc1oyfrOb9zYcj897x0Uu33vXsTyOJ
REXLppX/MurkOd+xnMgsowLdW6HvDx34JGvHsOP5ZTx0+79y7Tf+nTNvuIntzy3r7b8wBmk75Jp3s23FU0y5fB5TL7uGpqV/
QfQObplINaV8E0mjKHAa+Z4PhhwBjFZE4kkmnFJPvruDpi1riEQT6H2TOstbw8Zd1MDc/3c7TlyGJtdALExMaM/7b9c8fdcX
2PX0MqxYbI+o1VoRiSZo2rxW5LraRO3EU85NZKp/6xcKElRQ6G7+cbJy7FeONPghws0ibiLFzheX07qhlQlzz2TSBZezaemf
cRP773QStk2po4WWNS9x6tsuCH0UB0l+rb/xB05bJ35U8HB8FJflVnEJ8NiCRQy19Jcw3z+aSDFu6ixyXW20bNuAZTt7DT4h
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
'@

[System.IO.File]::WriteAllBytes(
    (Join-Path $StageApp "TacticalRadio.ico"),
    [Convert]::FromBase64String(($IconBase64 -replace "\s", ""))
)

$config = [ordered]@{
    baseUrl = ""
    placeId = "16489784096"
    jobId = "studio-local"
    mumblePath = "C:\Program Files\Mumble\Client\mumble.exe"
} | ConvertTo-Json -Depth 10

$config | Set-Content -Path (Join-Path $StageApp "config.json") -Encoding UTF8

$launcherPs1 = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $AppDir "config.json"
$AppIconPath = Join-Path $AppDir "TacticalRadio.ico"
$PluginSourceDir = Join-Path $AppDir "plugin"
$PluginDestDir = Join-Path $env:APPDATA "Mumble\Mumble\Plugins"
function Get-DefaultMumblePath {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Mumble\Client\mumble.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Mumble\Client\mumble.exe")
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return "C:\Program Files\Mumble\Client\mumble.exe"
}

function Get-Config {
    $default = [ordered]@{
        baseUrl = ""
        placeId = "16489784096"
        jobId = "studio-local"
        mumblePath = Get-DefaultMumblePath
    }

    if (Test-Path $ConfigPath) {
        try {
            $loaded = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

            foreach ($key in @("baseUrl", "placeId", "jobId", "mumblePath")) {
                if ($loaded.PSObject.Properties.Name -contains $key) {
                    $default[$key] = [string]$loaded.$key
                }
            }
        }
        catch {
        }
    }

    return $default
}

function Save-Config {
    $baseUrl = $BaseUrlText.Text.Trim()

    if ($baseUrl -and $baseUrl -notmatch "^https?://") {
        throw "Base URL must start with http:// or https://, or be left empty."
    }

    $obj = [ordered]@{
        baseUrl = $baseUrl
        placeId = $PlaceIdText.Text.Trim()
        jobId = $JobIdText.Text.Trim()
        mumblePath = $MumblePathText.Text.Trim()
    }

    $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Install-Plugin {
    New-Item -ItemType Directory -Path $PluginDestDir -Force | Out-Null

    $plugins = @(Get-ChildItem -Path $PluginSourceDir -Filter "*.dll" -File -ErrorAction SilentlyContinue)

    if ($plugins.Count -eq 0) {
        throw "No plugin DLL was found in: $PluginSourceDir"
    }

    $oldPluginNames = @(
        "tactical_radio_mumble_plugin.dll",
        "tactical-radio-bridge_mumble_plugin.dll",
        "tactical-radio-bridge.mumble_plugin.dll"
    )

    foreach ($oldName in $oldPluginNames) {
        $oldPath = Join-Path $PluginDestDir $oldName
        if (Test-Path $oldPath) {
            Remove-Item $oldPath -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($plugin in $plugins) {
        Copy-Item $plugin.FullName $PluginDestDir -Force
        Unblock-File -LiteralPath (Join-Path $PluginDestDir $plugin.Name) -ErrorAction SilentlyContinue
    }

    Get-ChildItem -Path $AppDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    $StatusLabel.Text = "Plugin installed/repaired in Mumble plugin folder."
}

function Launch-Mumble {
    Save-Config
    Install-Plugin

    $mumblePath = $MumblePathText.Text.Trim()

    if (-not (Test-Path $mumblePath)) {
        throw "Mumble was not found at: $mumblePath"
    }

    $binDir = Join-Path $AppDir "bin"
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "Process")
    [Environment]::SetEnvironmentVariable("PATH", "$binDir;$currentPath", "Process")

    [Environment]::SetEnvironmentVariable("TRADIO_BASE_URL", $BaseUrlText.Text.Trim(), "Process")
    [Environment]::SetEnvironmentVariable("TRADIO_PLACE_ID", $PlaceIdText.Text.Trim(), "Process")
    [Environment]::SetEnvironmentVariable("TRADIO_JOB_ID", $JobIdText.Text.Trim(), "Process")

    Start-Process -FilePath $mumblePath -WorkingDirectory (Split-Path -Parent $mumblePath)

    $StatusLabel.Text = "Mumble launched with Tactical Radio environment."
}

function Show-Error {
    param([string]$Message)

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        "Tactical Radio Launcher",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Add-Label {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 130
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, 24)
    $label.Font = $DefaultFont
    $label.ForeColor = [System.Drawing.Color]::FromArgb(38, 48, 61)
    $Parent.Controls.Add($label)
    return $label
}

function Add-HelpText {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 520
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, 20)
    $label.Font = $SmallFont
    $label.ForeColor = [System.Drawing.Color]::FromArgb(105, 117, 130)
    $Parent.Controls.Add($label)
    return $label
}

function Add-TextBox {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 520
    )

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Text = $Text
    $textBox.Location = New-Object System.Drawing.Point($X, $Y)
    $textBox.Size = New-Object System.Drawing.Size($Width, 24)
    $textBox.Font = $DefaultFont
    $Parent.Controls.Add($textBox)
    return $textBox
}

function New-ActionButton {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, 38)
    $button.Font = $ButtonFont
    $button.BackColor = $BackColor
    $button.ForeColor = $ForeColor
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.UseVisualStyleBackColor = $false
    return $button
}

$config = Get-Config

[System.Windows.Forms.Application]::EnableVisualStyles()

$DefaultFont = New-Object System.Drawing.Font("Segoe UI", 9)
$SmallFont = New-Object System.Drawing.Font("Segoe UI", 8)
$TitleFont = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$SubtitleFont = New-Object System.Drawing.Font("Segoe UI", 9.5)
$ButtonFont = New-Object System.Drawing.Font("Segoe UI Semibold", 9)

$DarkColor = [System.Drawing.Color]::FromArgb(21, 32, 48)
$AccentColor = [System.Drawing.Color]::FromArgb(40, 119, 219)
$SurfaceColor = [System.Drawing.Color]::FromArgb(246, 248, 251)
$BorderColor = [System.Drawing.Color]::FromArgb(218, 225, 233)

$AppIcon = $null
if (Test-Path $AppIconPath) {
    try {
        $AppIcon = New-Object System.Drawing.Icon($AppIconPath)
    }
    catch {
        $AppIcon = $null
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Tactical Radio"
$form.Size = New-Object System.Drawing.Size(760, 505)
$form.MinimumSize = New-Object System.Drawing.Size(760, 505)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = $SurfaceColor
$form.Font = $DefaultFont

if ($AppIcon) {
    $form.Icon = $AppIcon
}

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$headerPanel.Height = 96
$headerPanel.BackColor = $DarkColor
$form.Controls.Add($headerPanel)

if ($AppIcon) {
    $logoBox = New-Object System.Windows.Forms.PictureBox
    $logoBox.Image = $AppIcon.ToBitmap()
    $logoBox.Location = New-Object System.Drawing.Point(24, 22)
    $logoBox.Size = New-Object System.Drawing.Size(52, 52)
    $logoBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
    $headerPanel.Controls.Add($logoBox)
}

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Tactical Radio"
$titleLabel.Location = New-Object System.Drawing.Point(92, 20)
$titleLabel.Size = New-Object System.Drawing.Size(620, 34)
$titleLabel.Font = $TitleFont
$titleLabel.ForeColor = [System.Drawing.Color]::White
$headerPanel.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Configure your bridge connection, repair the Mumble plugin, then launch Mumble."
$subtitleLabel.Location = New-Object System.Drawing.Point(95, 58)
$subtitleLabel.Size = New-Object System.Drawing.Size(620, 24)
$subtitleLabel.Font = $SubtitleFont
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(198, 214, 235)
$headerPanel.Controls.Add($subtitleLabel)

$connectionGroup = New-Object System.Windows.Forms.GroupBox
$connectionGroup.Text = "Bridge settings"
$connectionGroup.Location = New-Object System.Drawing.Point(20, 112)
$connectionGroup.Size = New-Object System.Drawing.Size(704, 170)
$connectionGroup.Font = $ButtonFont
$connectionGroup.ForeColor = [System.Drawing.Color]::FromArgb(34, 46, 60)
$form.Controls.Add($connectionGroup)

Add-Label $connectionGroup "Base URL:" 18 34 120 | Out-Null
$BaseUrlText = Add-TextBox $connectionGroup $config.baseUrl 150 30 520
Add-HelpText $connectionGroup "Optional. Leave empty to avoid shipping a default server address." 150 56 520 | Out-Null

Add-Label $connectionGroup "Place ID:" 18 86 120 | Out-Null
$PlaceIdText = Add-TextBox $connectionGroup $config.placeId 150 82 220

Add-Label $connectionGroup "Job ID:" 390 86 80 | Out-Null
$JobIdText = Add-TextBox $connectionGroup $config.jobId 470 82 200
Add-HelpText $connectionGroup "These values are passed to Mumble as TRADIO_PLACE_ID and TRADIO_JOB_ID." 150 110 520 | Out-Null

$mumbleGroup = New-Object System.Windows.Forms.GroupBox
$mumbleGroup.Text = "Mumble"
$mumbleGroup.Location = New-Object System.Drawing.Point(20, 294)
$mumbleGroup.Size = New-Object System.Drawing.Size(704, 90)
$mumbleGroup.Font = $ButtonFont
$mumbleGroup.ForeColor = [System.Drawing.Color]::FromArgb(34, 46, 60)
$form.Controls.Add($mumbleGroup)

Add-Label $mumbleGroup "Mumble path:" 18 36 120 | Out-Null
$MumblePathText = Add-TextBox $mumbleGroup $config.mumblePath 150 32 420

$BrowseButton = New-ActionButton "Browse" 584 29 90 ([System.Drawing.Color]::FromArgb(226, 232, 240)) ([System.Drawing.Color]::FromArgb(28, 38, 52))
$BrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Mumble executable|mumble.exe|Executable files|*.exe|All files|*.*"
    $dialog.Title = "Select mumble.exe"

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $MumblePathText.Text = $dialog.FileName
    }
})
$mumbleGroup.Controls.Add($BrowseButton)

$buttonPanel = New-Object System.Windows.Forms.Panel
$buttonPanel.Location = New-Object System.Drawing.Point(20, 398)
$buttonPanel.Size = New-Object System.Drawing.Size(704, 48)
$buttonPanel.BackColor = $SurfaceColor
$form.Controls.Add($buttonPanel)

$SaveButton = New-ActionButton "Save Settings" 0 4 150 ([System.Drawing.Color]::FromArgb(226, 232, 240)) ([System.Drawing.Color]::FromArgb(28, 38, 52))
$SaveButton.Add_Click({
    try {
        Save-Config
        $StatusLabel.Text = "Settings saved."
    }
    catch {
        Show-Error $_.Exception.Message
    }
})
$buttonPanel.Controls.Add($SaveButton)

$RepairButton = New-ActionButton "Install / Repair Plugin" 164 4 180 ([System.Drawing.Color]::FromArgb(226, 232, 240)) ([System.Drawing.Color]::FromArgb(28, 38, 52))
$RepairButton.Add_Click({
    try {
        Save-Config
        Install-Plugin
    }
    catch {
        Show-Error $_.Exception.Message
    }
})
$buttonPanel.Controls.Add($RepairButton)

$LaunchButton = New-ActionButton "Launch Mumble" 524 4 180 $AccentColor ([System.Drawing.Color]::White)
$LaunchButton.Add_Click({
    try {
        Launch-Mumble
    }
    catch {
        Show-Error $_.Exception.Message
    }
})
$buttonPanel.Controls.Add($LaunchButton)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(20, 452)
$statusPanel.Size = New-Object System.Drawing.Size(704, 30)
$statusPanel.BackColor = [System.Drawing.Color]::White
$statusPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($statusPanel)

$StatusLabel = New-Object System.Windows.Forms.Label
$StatusLabel.Text = "Ready. Base URL is empty by default."
$StatusLabel.Location = New-Object System.Drawing.Point(10, 6)
$StatusLabel.Size = New-Object System.Drawing.Size(680, 18)
$StatusLabel.Font = $SmallFont
$StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(77, 89, 103)
$statusPanel.Controls.Add($StatusLabel)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.SetToolTip($BaseUrlText, "Leave empty unless you want the launcher to set TRADIO_BASE_URL automatically.")
$toolTip.SetToolTip($PlaceIdText, "Roblox placeId passed to the plugin process.")
$toolTip.SetToolTip($JobIdText, "Roblox jobId passed to the plugin process.")
$toolTip.SetToolTip($MumblePathText, "Path to the local Mumble client executable.")

[System.Windows.Forms.Application]::Run($form)
'@

$launcherPs1 | Set-Content -Path (Join-Path $StageApp "TacticalRadioLauncher.ps1") -Encoding UTF8

$launcherCmd = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0TacticalRadioLauncher.ps1"
'@

$launcherCmd | Set-Content -Path (Join-Path $StageApp "TacticalRadioLauncher.cmd") -Encoding ASCII

$iss = @'
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
'@

$iss | Set-Content -Path $GeneratedIss -Encoding UTF8

Write-Host ""
Write-Host "== Compiling installer =="

$iscc = Find-Iscc

if (-not $iscc) {
    throw "Inno Setup compiler was not found. Install it once with: winget install -e --id JRSoftware.InnoSetup"
}

Invoke-Checked $iscc @(
    "/DAppVersion=$Version",
    "/DSourceDir=$Stage",
    "/DPluginFileName=$($PluginDll.Name)",
    "/O$InstallerOut",
    "/FTacticalRadioSetup-$Version",
    $GeneratedIss
)

$InstallerPath = Join-Path $InstallerOut "TacticalRadioSetup-$Version.exe"

if (-not (Test-Path $InstallerPath)) {
    throw "Installer was not produced: $InstallerPath"
}

Write-Host ""
Write-Host "DONE"
Write-Host "Installer:"
Write-Host $InstallerPath
Write-Host ""