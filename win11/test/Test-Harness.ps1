# Runs Harness.exe against a throw-away copy of the DLL with a test menu.json (no install needed).
$ErrorActionPreference = 'Stop'
$dist = Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'
$t = Join-Path $env:TEMP 'fa_shell_test'
if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force }
$ev = Join-Path $t 'evidence'
$pl = Join-Path $ev ([string][char]0x7A + [char]0x61 + [char]0x17C + [char]0xF3 + [char]0x142 + [char]0x107 + ' dir')   # "zażółć dir"
New-Item -ItemType Directory -Path "$t\bin", $pl | Out-Null
Copy-Item -LiteralPath "$dist\ForensicAidShell.dll" -Destination "$t\bin"
foreach ($f in 'Amcache.hve', 'notes.txt', '$I30', '$IABC123.exe') { Set-Content -LiteralPath (Join-Path $ev $f) -Value x }
Set-Content -LiteralPath (Join-Path $pl 'Security.evtx') -Value x

$cmd = '"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -File "C:\FA\ForensicAid.ps1" -Action {0} -Path "%1"'
$menu = [ordered]@{
    version = 1; title = 'ForensicAid'; icon = 'C:\FA\icon.ico'
    items = @(
        [ordered]@{ id = 'hash'; title = 'Hash'; scopes = @('File', 'Dir'); ext = @(); names = @(); prefixes = @(); separatorBefore = $false; hidden = $false; command = ($cmd -f 'hash') }
        [ordered]@{ id = 'amcache'; title = 'Amcache - AmcacheParser'; scopes = @('File'); ext = @(); names = @('Amcache.hve'); prefixes = @(); separatorBefore = $true; hidden = $false; command = ($cmd -f 'amcache') }
        [ordered]@{ id = 'evtx'; title = 'Event logs - EvtxECmd'; scopes = @('File', 'Dir'); ext = @('.EVTX'); names = @(); prefixes = @(); separatorBefore = $false; hidden = $false; command = ($cmd -f 'evtx') }
        [ordered]@{ id = 'recyclebin'; title = 'Recycle Bin'; scopes = @('File'); ext = @(); names = @(); prefixes = @('$I'); excludeNames = @('$I30'); separatorBefore = $false; hidden = $false; command = ($cmd -f 'recyclebin') }
        [ordered]@{ id = 'triage'; title = 'Full triage'; scopes = @('Dir', 'Background'); ext = @(); names = @(); prefixes = @(); separatorBefore = $true; hidden = $false; command = ($cmd -f 'triage') }
    )
}
$menu | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$t\bin\menu.json" -Encoding UTF8   # UTF-8 with BOM, like PS 5.1 writes it

$env:FORENSICAID_SHELL_DRYRUN = '1'
$h = Join-Path $dist 'Harness.exe'
$dll = "$t\bin\ForensicAidShell.dll"
$cases = @(
    ,@('Amcache.hve (match by name)', 'item', (Join-Path $ev 'Amcache.hve'))
    ,@('notes.txt (only Hash)', 'item', (Join-Path $ev 'notes.txt'))
    ,@('$I30 excluded from Recycle Bin', 'item', (Join-Path $ev '$I30'))
    ,@('$IABC123.exe prefix match', 'item', (Join-Path $ev '$IABC123.exe'))
    ,@('Polish folder', 'item', $pl)
    ,@('evtx in Polish folder (ext case-insensitive)', 'item', (Join-Path $pl 'Security.evtx'))
    ,@('drive root', 'item', 'C:\')
    ,@('folder background', 'bg', $ev)
    ,@('multi-select (hidden)', 'item', (Join-Path $ev 'notes.txt'), (Join-Path $ev 'Amcache.hve'))
)
foreach ($c in $cases) {
    Write-Host "### $($c[0])" -ForegroundColor White
    & $h $dll @($c[1..($c.Count - 1)])
}
Write-Host '### malformed menu.json (root must hide, no crash)' -ForegroundColor White
Set-Content -LiteralPath "$t\bin\menu.json" -Value '{ "items": [ { "title": "x", "command": "\ud800' -Encoding UTF8
& $h $dll item (Join-Path $ev 'notes.txt')

Write-Host '### dryrun.log' -ForegroundColor White
Get-Content -LiteralPath "$t\bin\dryrun.log" -Encoding UTF8
Remove-Item -LiteralPath $t -Recurse -Force
