<#
.SYNOPSIS
    Builds the Windows 11 context-menu extension: DLL, stub exe, test harness and a signed sparse package.

.DESCRIPTION
    Needs Visual Studio (C++ workload) and the Windows 10/11 SDK. Output goes to win11\dist:
      ForensicAidShell.dll, ForensicAidStub.exe, Harness.exe, ForensicAid-Shell.msix, ForensicAid-Shell.cer
    The package is signed with a self-signed certificate (CN=ForensicAid) kept in Cert:\CurrentUser\My
    and reused on later builds. Installing it is a separate step.
#>
[CmdletBinding()]
param([switch]$SkipPackage)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'
$obj  = Join-Path $root 'obj'
$publisher = 'CN=ForensicAid'

function Write-Step([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }

# --- toolchain
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'vswhere.exe not found - install Visual Studio with the C++ workload.' }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'No Visual Studio with C++ tools found.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'

$kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$sdkBin = Get-ChildItem -LiteralPath $kits -Directory -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -match '^10\.' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'x64\makeappx.exe')) } |
          Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $sdkBin -and -not $SkipPackage) { throw 'Windows SDK (makeappx.exe) not found.' }

foreach ($d in $dist, $obj) { [void][IO.Directory]::CreateDirectory($d) }

# --- compile (cl via vcvars; static CRT so no VC++ redistributable is needed)
function Invoke-Cl([string]$CommandLine) {
    $bat = Join-Path $obj 'cl.cmd'
    # vcvars calls vswhere by name, so put it on PATH.
    Set-Content -LiteralPath $bat -Encoding ASCII -Value ("@echo off`r`nset `"PATH=%PATH%;$(Split-Path $vswhere)`"`r`n" +
        "call `"$vcvars`" >nul || exit /b 1`r`ncd /d `"$obj`"`r`n$CommandLine`r`n")
    & cmd.exe /c "`"$bat`""
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $CommandLine" }
}

$common = '/nologo /O2 /MT /EHsc /W4 /WX /std:c++17 /DUNICODE /D_UNICODE /DNOMINMAX'
Write-Step 'Compiling ForensicAidShell.dll'
Invoke-Cl "cl $common /LD `"$root\src\ForensicAidShell.cpp`" /Fe:`"$dist\ForensicAidShell.dll`" /link /DEF:`"$root\src\ForensicAidShell.def`" shlwapi.lib shell32.lib ole32.lib uuid.lib"
Write-Step 'Compiling ForensicAidStub.exe'
Invoke-Cl "cl $common `"$root\src\ForensicAidStub.cpp`" /Fe:`"$dist\ForensicAidStub.exe`" /link /SUBSYSTEM:WINDOWS"
Write-Step 'Compiling Harness.exe'
Invoke-Cl "cl $common `"$root\test\Harness.cpp`" /Fe:`"$dist\Harness.exe`" /link ole32.lib shell32.lib"
Remove-Item -LiteralPath (Join-Path $dist 'ForensicAidShell.exp'), (Join-Path $dist 'ForensicAidShell.lib') -ErrorAction SilentlyContinue

if ($SkipPackage) { Write-Host '[+] Binaries built (package skipped).' -ForegroundColor Green; return }

# --- package content: manifest + logos only (binaries live in the external location)
$pkg = Join-Path $obj 'package'
if (Test-Path -LiteralPath $pkg) { Remove-Item -LiteralPath $pkg -Recurse -Force }
[void][IO.Directory]::CreateDirectory((Join-Path $pkg 'Assets'))
# Every build gets a new version, so install can update the registered package in place
# (removing a package whose menu handler Explorer is using can hang).
$now = Get-Date
$version = '1.0.{0}.{1}' -f ($now.Date - [datetime]'2025-01-01').Days, [int]$now.TimeOfDay.TotalMinutes
$manifest = (Get-Content -LiteralPath (Join-Path $root 'package\AppxManifest.xml') -Raw) -replace '(<Identity [^>]*Version=")[^"]+', "`${1}$version"
[IO.File]::WriteAllText((Join-Path $pkg 'AppxManifest.xml'), $manifest, (New-Object Text.UTF8Encoding($false)))
Write-Step "Package version $version"

Add-Type -AssemblyName System.Drawing
# Logos from the largest icon frame. A PNG-compressed frame is decoded directly: System.Drawing.Icon
# turns those into noise.
$ico = Join-Path (Split-Path $root -Parent) 'icon.ico'
$icoBytes = [IO.File]::ReadAllBytes($ico)
$best = $null
for ($i = 0; $i -lt [BitConverter]::ToUInt16($icoBytes, 4); $i++) {
    $o = 6 + 16 * $i
    $w = if ($icoBytes[$o] -eq 0) { 256 } else { $icoBytes[$o] }
    if (-not $best -or $w -gt $best.W) { $best = @{ W = $w; Size = [BitConverter]::ToUInt32($icoBytes, $o + 8); Offset = [BitConverter]::ToUInt32($icoBytes, $o + 12) } }
}
$isPng = [Text.Encoding]::ASCII.GetString($icoBytes, $best.Offset + 1, 3) -eq 'PNG'
$master = if ($isPng) {
    [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream($icoBytes, $best.Offset, $best.Size)))
} else {
    (New-Object System.Drawing.Icon($ico, $best.W, $best.W)).ToBitmap()
}
foreach ($a in @(@('StoreLogo.png', 50), @('Square44x44Logo.png', 44), @('Square150x150Logo.png', 150))) {
    $size = $a[1]
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($master, 0, 0, $size, $size)
    $bmp.Save((Join-Path $pkg "Assets\$($a[0])"), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}
$master.Dispose()

# --- signing certificate (CurrentUser, reused)
$cert = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $publisher -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) -and
                       ($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' }) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
    Write-Step "Creating self-signed code signing certificate $publisher"
    $cert = New-SelfSignedCertificate -Type Custom -Subject $publisher -KeyUsage DigitalSignature -FriendlyName 'ForensicAid shell extension' `
            -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddYears(5) `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
}
$cer = Join-Path $dist 'ForensicAid-Shell.cer'
[void](Export-Certificate -Cert $cert -FilePath $cer -Force)

# --- pack + sign
$msix = Join-Path $dist 'ForensicAid-Shell.msix'
$makeappx = Join-Path $sdkBin.FullName 'x64\makeappx.exe'
$signtool = Join-Path $sdkBin.FullName 'x64\signtool.exe'
Write-Step 'Packing sparse package'
& $makeappx pack /d $pkg /p $msix /nv /o | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'makeappx failed.' }
Write-Step "Signing with $($cert.Thumbprint)"
& $signtool sign /q /fd SHA256 /sha1 $cert.Thumbprint /s My $msix | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'signtool failed.' }

Copy-Item -LiteralPath (Join-Path $pkg 'AppxManifest.xml') -Destination $dist -Force   # install reads the version from it
Write-Host "[+] Built: $dist" -ForegroundColor Green
Get-ChildItem -LiteralPath $dist -File | ForEach-Object { Write-Host ('      {0,-28} {1,10:n0} bytes' -f $_.Name, $_.Length) }
