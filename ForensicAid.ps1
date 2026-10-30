<#
.SYNOPSIS
    ForensicAid - Explorer context menu for parsing DFIR evidence.

.DESCRIPTION
    A single script handles installing the menu, removing it, and running every action:

      ForensicAid.ps1 -Install [-ResetConfig]   register the right-click menu for the current user (no admin)
      ForensicAid.ps1 -Uninstall                remove the menu
      ForensicAid.ps1 -Action <id> -Path <p>    run one action (the menu calls this)
      ForensicAid.ps1 -Action doctor            show which tools were found
      ForensicAid.ps1 -ListActions              action list as JSON (used by the tray icon)
      ForensicAid.ps1 -RegisterMenu             re-register the menu without pausing (used by the tray icon)

    The tray icon (ForensicAidTray.ps1) is installed next to this script and started at logon.

    The script targets Windows PowerShell 5.1, which ships with every supported Windows,
    so the toolbox has no runtime dependencies besides the parsers themselves.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run', Mandatory)] [string] $Action,
    [Parameter(ParameterSetName = 'Run')] [string] $Path,
    [Parameter(ParameterSetName = 'Install', Mandatory)] [switch] $Install,
    [Parameter(ParameterSetName = 'Install')] [switch] $ResetConfig,
    [Parameter(ParameterSetName = 'Install')] [switch] $Yes,
    [Parameter(ParameterSetName = 'RemoveLegacy', Mandatory)] [switch] $RemoveLegacy,
    [Parameter(ParameterSetName = 'RemoveLegacy', Mandatory)] [string] $BackupDir,
    [Parameter(ParameterSetName = 'Uninstall', Mandatory)] [switch] $Uninstall,
    [Parameter(ParameterSetName = 'ListActions', Mandatory)] [switch] $ListActions,
    [Parameter(ParameterSetName = 'RegisterMenu', Mandatory)] [switch] $RegisterMenu
)

$ErrorActionPreference = 'Stop'

$Version    = '1.0.0'
$AppName    = 'ForensicAid'
$InstallDir = if ($env:FORENSICAID_HOME) { $env:FORENSICAID_HOME } else { Join-Path $env:LOCALAPPDATA $AppName }
$ConfigFile = Join-Path $InstallDir 'ForensicAid.config.psd1'
$CacheFile  = Join-Path $InstallDir 'tools.cache.json'
$HistoryLog = Join-Path $InstallDir 'history.log'
$StateFile  = Join-Path $InstallDir 'menu.state.json'   # items switched off from the tray icon
$LastOutput = Join-Path $InstallDir 'last_output.txt'
$TrayScript = Join-Path $InstallDir 'ForensicAidTray.ps1'
$RunKey     = 'Software\Microsoft\Windows\CurrentVersion\Run'
$Esentutl   = Join-Path $env:windir 'System32\esentutl.exe'

# Per-user classes (HKCU\Software\Classes) - merged into HKCR by Windows, no admin rights needed.
$RegClasses = if ($env:FORENSICAID_REGROOT) { $env:FORENSICAID_REGROOT } else { 'Software\Classes' }
$MenuStore  = 'ForensicAid.Menus'
$MenuRoots  = @(
    @{ Key = '*\shell\ForensicAid';                    Menu = 'File' }
    @{ Key = 'Directory\shell\ForensicAid';            Menu = 'Dir' }
    @{ Key = 'Drive\shell\ForensicAid';                Menu = 'Dir' }
    @{ Key = 'Directory\Background\shell\ForensicAid'; Menu = 'Background' }
    # '*' verbs get the shortcut's TARGET as %1; a verb under lnkfile gets the .lnk itself.
    @{ Key = 'lnkfile\shell\ForensicAid';              Menu = 'File' }
)

# Executable names searched for under ToolRoots when no explicit path is configured.
$ToolFiles = [ordered]@{
    AmcacheParser        = @('AmcacheParser.exe')
    AppCompatCacheParser = @('AppCompatCacheParser.exe')
    EvtxECmd             = @('EvtxECmd.exe')
    JLECmd               = @('JLECmd.exe')
    LECmd                = @('LECmd.exe')
    MFTECmd              = @('MFTECmd.exe')
    PECmd                = @('PECmd.exe')
    RBCmd                = @('RBCmd.exe')
    RECmd                = @('RECmd.exe')
    SBECmd               = @('SBECmd.exe')
    SrumECmd             = @('SrumECmd.exe')
    SumECmd              = @('SumECmd.exe')
    WxTCmd               = @('WxTCmd.exe')
    TimelineExplorer     = @('TimelineExplorer.exe')
    Chainsaw             = @('chainsaw.exe', 'chainsaw_x86_64-pc-windows-msvc.exe')
    QemuImg              = @('qemu-img.exe')
}

$Defaults = @{
    ToolRoots        = @('C:\Tools', '%USERPROFILE%\Desktop')
    Tools            = @{}
    Chainsaw         = @{ SigmaRules = ''; Mapping = ''; Rules = ''; ExtraArgs = @('--skip-errors') }
    RECmdBatch       = ''
    OutputMode       = 'NextToEvidence'
    OutputRoot       = '%USERPROFILE%\ForensicAid_Output'
    OpenOutputFolder = $true
    PauseOnExit      = 'Always'
    FilterByFileType = $true
    HideUnavailable  = $true
    Disabled         = @()
    EnableLogging    = $true
}

$script:Config       = $null
$script:ToolCache    = $null
$script:Rescanned    = $false
$script:RunLog       = $null
$script:ToolFailures = 0

#region Console and logging

function Write-Info([string]$Message) { Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Err([string]$Message)  { Write-Host "[x] $Message" -ForegroundColor Red }

function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    if ($script:RunLog) {
        try { Add-Content -LiteralPath $script:RunLog -Value $line -Encoding UTF8 } catch { }
    }
    if ($script:Config -and $script:Config.EnableLogging) {
        try { Add-Content -LiteralPath $HistoryLog -Value $line -Encoding UTF8 } catch { }
    }
}

function Wait-AnyKey {
    Write-Host ''
    Write-Host 'Press any key to close...' -ForegroundColor DarkGray
    try { [void][Console]::ReadKey($true) } catch { [void](Read-Host) }
}

#endregion

#region Configuration

function Expand-PathValue($Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return [Environment]::ExpandEnvironmentVariables(([string]$Value).Trim().Trim('"'))
}

function Import-Config([switch]$DefaultsOnly) {
    $cfg = @{}
    foreach ($k in $Defaults.Keys) {
        $v = $Defaults[$k]
        if ($v -is [hashtable]) { $v = $v.Clone() }
        $cfg[$k] = $v
    }
    if ($DefaultsOnly) { return $cfg }

    $file = $ConfigFile
    if (-not [IO.File]::Exists($file)) { $file = Join-Path $PSScriptRoot 'ForensicAid.config.psd1' }
    if ([IO.File]::Exists($file)) {
        try {
            $user = Import-PowerShellDataFile -LiteralPath $file
        } catch {
            throw "Config file is not valid: $file`n$($_.Exception.Message)"
        }
        foreach ($k in $user.Keys) {
            if ($cfg[$k] -is [hashtable] -and $user[$k] -is [hashtable]) {
                foreach ($sub in $user[$k].Keys) { $cfg[$k][$sub] = $user[$k][$sub] }
            } else {
                $cfg[$k] = $user[$k]
            }
        }
    }

    # Items switched off from the tray icon add to the config's Disabled list (the psd1 is never rewritten).
    $tray = @(Get-MenuState)
    if ($tray.Count) { $cfg.Disabled = @(@($cfg.Disabled) + $tray | Select-Object -Unique) }
    return $cfg
}

function Open-Config {
    if (-not [IO.File]::Exists($ConfigFile)) {
        [void][IO.Directory]::CreateDirectory($InstallDir)
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ForensicAid.config.psd1') -Destination $ConfigFile
    }
    Start-Process notepad.exe -ArgumentList (ConvertTo-ArgumentString @($ConfigFile))
}

function Get-MenuState {
    if (-not [IO.File]::Exists($StateFile)) { return @() }
    try {
        return @((Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).Disabled | Where-Object { $_ })
    } catch { return @() }
}

#endregion

#region Tool discovery

function Get-FileVersionSafe([IO.FileInfo]$File) {
    try { return [version](($File.VersionInfo.FileVersion -replace '[^\d\.].*$', '').Trim('.')) } catch { return [version]'0.0' }
}

# Chainsaw carries no file version; v1 and v2 differ in CLI and rule layout, so ask the exe.
function Get-ChainsawVersion([string]$Exe) {
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $Exe --version 2>$null | Out-String
        if ($out -match '(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    } catch { }
    return [version]'0.0'
}

function Get-ToolCache {
    if ($null -ne $script:ToolCache) { return $script:ToolCache }
    $h = @{}
    if ([IO.File]::Exists($CacheFile)) {
        try {
            $json = Get-Content -LiteralPath $CacheFile -Raw | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
        } catch { }
    }
    $script:ToolCache = $h
    return $h
}

function Update-ToolCache {
    $script:Rescanned = $true
    $wanted = @{}
    foreach ($tool in $ToolFiles.Keys) {
        foreach ($f in $ToolFiles[$tool]) { $wanted[$f.ToLowerInvariant()] = $tool }
    }

    $found = @{}
    foreach ($root in @($script:Config.ToolRoots)) {
        $r = Expand-PathValue $root
        if (-not $r -or -not [IO.Directory]::Exists($r)) { continue }
        Get-ChildItem -LiteralPath $r -Recurse -File -Filter '*.exe' -ErrorAction SilentlyContinue |
            Where-Object { $wanted.ContainsKey($_.Name.ToLowerInvariant()) } |
            ForEach-Object {
                $tool = $wanted[$_.Name.ToLowerInvariant()]
                if (-not $found.ContainsKey($tool)) { $found[$tool] = [System.Collections.Generic.List[object]]::new() }
                $found[$tool].Add($_)
            }
    }

    $cache = @{}
    foreach ($tool in $ToolFiles.Keys) {
        if ($found.ContainsKey($tool)) {
            # Several copies (e.g. net6 and net9 builds, Chainsaw v1 and v2): prefer the highest version, then the newest file.
            $ver = if ($tool -eq 'Chainsaw') { { Get-ChainsawVersion $_.FullName } } else { { Get-FileVersionSafe $_ } }
            $best = $found[$tool] |
                Sort-Object @{ Expression = $ver; Descending = $true }, @{ Expression = { $_.LastWriteTime }; Descending = $true } |
                Select-Object -First 1
            $cache[$tool] = $best.FullName
            continue
        }
        foreach ($f in $ToolFiles[$tool]) {
            $cmd = Get-Command $f -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cmd) { $cache[$tool] = $cmd.Source; break }
        }
        if (-not $cache.ContainsKey($tool) -and $tool -eq 'QemuImg') {
            $q = Join-Path $env:ProgramFiles 'qemu\qemu-img.exe'
            if ([IO.File]::Exists($q)) { $cache[$tool] = $q }
        }
    }

    try {
        [void][IO.Directory]::CreateDirectory($InstallDir)
        $cache | ConvertTo-Json | Set-Content -LiteralPath $CacheFile -Encoding UTF8
    } catch { }
    $script:ToolCache = $cache
    return $cache
}

function Resolve-Tool([string]$Name, [switch]$Optional) {
    $explicit = Expand-PathValue $script:Config.Tools[$Name]
    if ($explicit) {
        if ([IO.File]::Exists($explicit)) { return $explicit }
        if ($Optional) { return $null }
        throw "$Name is configured as '$explicit' but that file does not exist. Fix Tools.$Name in $ConfigFile"
    }

    $cache = Get-ToolCache
    if ($cache[$Name] -and [IO.File]::Exists($cache[$Name])) { return $cache[$Name] }

    # Not cached yet, or the cached path went stale (tool added, moved or updated) - rescan once per run.
    if (-not $script:Rescanned) {
        $script:Rescanned = $true
        $cache = Update-ToolCache
        if ($cache[$Name]) { return $cache[$Name] }
    }
    if ($Optional) { return $null }
    throw "$Name not found. Put it under one of ToolRoots or set Tools.$Name in $ConfigFile, then use 'Check tools'."
}

function Get-ChainsawRuleSet {
    $exe = Resolve-Tool Chainsaw -Optional
    $csDir = if ($exe) { [IO.Path]::GetDirectoryName($exe) } else { $null }   # not $home: $HOME is read-only
    $cs = $script:Config.Chainsaw

    $sigma = Expand-PathValue $cs.SigmaRules
    if (-not $sigma -and $csDir) {
        foreach ($cand in @((Join-Path $csDir 'sigma\rules'), (Join-Path $csDir 'sigma'))) {
            if ([IO.Directory]::Exists($cand)) { $sigma = $cand; break }
        }
    }
    $mapping = Expand-PathValue $cs.Mapping
    if (-not $mapping -and $csDir) { $mapping = Join-Path $csDir 'mappings\sigma-event-logs-all.yml' }
    $rules = Expand-PathValue $cs.Rules
    if (-not $rules -and $csDir -and [IO.Directory]::Exists((Join-Path $csDir 'rules'))) { $rules = Join-Path $csDir 'rules' }

    return @{ Exe = $exe; Sigma = $sigma; Mapping = $mapping; Rules = $rules }
}

function Get-RECmdBatch([string]$RECmdExe) {
    $batch = Expand-PathValue $script:Config.RECmdBatch
    if ($batch) { return $batch }
    if (-not $RECmdExe) { return $null }
    $dir = Join-Path ([IO.Path]::GetDirectoryName($RECmdExe)) 'BatchExamples'
    foreach ($name in 'Kroll_Batch.reb', 'DFIRBatch.reb', 'RECmd_Batch_MC.reb') {
        $p = Join-Path $dir $name
        if ([IO.File]::Exists($p)) { return $p }
    }
    return $null
}

#endregion

#region Process helpers

# Quote arguments the way CommandLineToArgvW parses them back (handles spaces, quotes, trailing backslashes).
function ConvertTo-ArgumentString([object[]]$Arguments) {
    $parts = foreach ($a in $Arguments) {
        if ($null -eq $a) { continue }
        $s = [string]$a
        if ($s -eq '') { continue }
        if ($s -notmatch '[\s"]') { $s; continue }
        '"' + (($s -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
    }
    return ($parts -join ' ')
}

# Runs a tool in this console window (keeps its colours and progress bars) and returns the exit code.
function Invoke-Tool {
    param([string]$Tool, [object[]]$Arguments, [string]$WorkDir, [switch]$AllowFailure)

    $exe = if ($Tool -eq 'esentutl') { $Esentutl } else { Resolve-Tool $Tool }
    $argLine = ConvertTo-ArgumentString $Arguments

    Write-Host ''
    Write-Host ("> {0} {1}" -f [IO.Path]::GetFileName($exe), $argLine) -ForegroundColor DarkCyan
    Write-Host ''
    Write-Log "RUN  `"$exe`" $argLine"

    # ProcessStartInfo instead of Start-Process: no wildcard parsing of WorkingDirectory ([brackets] in
    # evidence paths) and the child shares this console.
    $psi = New-Object Diagnostics.ProcessStartInfo $exe, $argLine
    $psi.UseShellExecute = $false
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    $code = $p.ExitCode
    $p.Dispose()

    Write-Log ("EXIT {0} after {1:n1}s" -f $code, $sw.Elapsed.TotalSeconds)
    if ($code -ne 0 -and -not $AllowFailure) {
        $script:ToolFailures++
        Write-Warn "$Tool exited with code $code"
    }
    return $code
}

# EZ tools share the same CLI shape: -f <file> | -d <dir>, --csv <out>.
function Invoke-Ez([string]$Tool, $c, [object[]]$Extra = @(), [switch]$Quiet) {
    $in = if ($c.IsDir) { @('-d', $c.Path) } else { @('-f', $c.Path) }
    $a = @($in) + @('--csv', $c.Out) + @($Extra)
    if ($Quiet) { $a += '-q' }
    $null = Invoke-Tool $Tool $a
}

#endregion

#region Paths and output

function Get-SafeName([string]$Name) {
    return (($Name -replace '[\\/:*?"<>|\s]+', '_').Trim('_', '.'))
}

function New-OutputDir([string]$EvidencePath, [string]$ActionId) {
    $trimmed = $EvidencePath.TrimEnd('\')
    $leaf = Get-SafeName ([IO.Path]::GetFileName($trimmed))
    if (-not $leaf) { $leaf = 'drive_' + $EvidencePath.Substring(0, 1) }
    $name = '{0:yyyyMMdd_HHmmss}_{1}_{2}' -f (Get-Date), $ActionId, $leaf

    $bases = @()
    if ($script:Config.OutputMode -ne 'OutputRoot') {
        $parent = [IO.Path]::GetDirectoryName($trimmed)
        if ($parent) { $bases += (Join-Path $parent 'ForensicAid') }
    }
    $root = Expand-PathValue $script:Config.OutputRoot
    if ($root) { $bases += $root }

    foreach ($base in $bases) {
        $dir = Join-Path $base $name
        try {
            [void][IO.Directory]::CreateDirectory($dir)
            return $dir
        } catch {
            Write-Warn "Cannot write to $base ($($_.Exception.Message)) - trying next location."
        }
    }
    throw 'No writable output location. Check OutputRoot in the config.'
}

function Initialize-Output($c) {
    if ($c.Out) { return }
    $c.Out = New-OutputDir $c.Path $c.Action
    $script:RunLog = Join-Path $c.Out 'ForensicAid.log'
    try { [void][IO.Directory]::CreateDirectory($InstallDir); [IO.File]::WriteAllText($LastOutput, $c.Out) } catch { }
    Write-Log ("ForensicAid {0} | action={1} | user={2}\{3} | host={4}" -f $Version, $c.Action, $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)
    Write-Log "INPUT $($c.Path)"
    Write-Info "Output: $($c.Out)"
}

# Our own results (and database copies in them) live in ...\ForensicAid\... - never treat them as evidence.
function Test-OwnOutput([string]$FullName) {
    return $FullName -like '*\ForensicAid\*'
}

function Find-FirstFile([string]$Root, [string]$Name, [string]$PreferDir) {
    $hits = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -Filter $Name -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -eq $Name -and -not (Test-OwnOutput $_.FullName) })
    if ($PreferDir) {
        $pref = $hits | Where-Object { $_.Directory.Name -eq $PreferDir } | Select-Object -First 1
        if ($pref) { return $pref.FullName }
    }
    if ($hits.Count) { return $hits[0].FullName }
    return $null
}

#endregion

#region Registry hives

$HiveNames = @('NTUSER.DAT', 'UsrClass.dat', 'SYSTEM', 'SOFTWARE', 'SAM', 'SECURITY', 'DEFAULT', 'Amcache.hve')

# A hive whose primary/secondary sequence numbers differ is dirty. Returns NotHive | Clean | DirtyWithLogs | DirtyNoLogs.
function Get-HiveState([string]$File) {
    try {
        $fs = [IO.File]::Open($File, 'Open', 'Read', 'ReadWrite')
        try { $b = New-Object byte[] 12; [void]$fs.Read($b, 0, 12) } finally { $fs.Dispose() }
    } catch { return 'NotHive' }
    if ([Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'regf') { return 'NotHive' }
    if ([BitConverter]::ToUInt32($b, 4) -eq [BitConverter]::ToUInt32($b, 8)) { return 'Clean' }

    $name = [IO.Path]::GetFileName($File)
    $logs = Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($File)) -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.StartsWith("$name.LOG", [StringComparison]::OrdinalIgnoreCase) }
    if ($logs) { return 'DirtyWithLogs' }
    return 'DirtyNoLogs'
}

# Without .LOG1/.LOG2 next to a dirty hive the EZ parsers abort unless --nl is given, so add it only in that case.
function Get-HiveArgs([string]$File) {
    switch (Get-HiveState $File) {
        'DirtyWithLogs' { Write-Info 'Hive is dirty - transaction logs found next to it and will be replayed.' }
        'DirtyNoLogs' {
            Write-Warn 'Hive is dirty and has no .LOG1/.LOG2 next to it - parsing without logs (--nl), data may be incomplete.'
            return @('--nl')
        }
    }
    return @()
}

# Hives under a folder that -d mode would fail on (dirty, no logs).
function Find-HivesNeedingNl([string]$Root) {
    $names = $HiveNames | ForEach-Object { $_.ToLowerInvariant() }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
             Where-Object { $names -contains $_.Name.ToLowerInvariant() -and -not (Test-OwnOutput $_.FullName) } |
             Where-Object { (Get-HiveState $_.FullName) -eq 'DirtyNoLogs' } |
             ForEach-Object { $_.FullName })
}

# EZ tools from 2026.10 copy databases into a Temp folder next to their exe and fail when it is not
# writable (Program Files, read-only share) - point them at the output folder instead.
function Get-EzTempArgs([string]$Tool, $c) {
    $exe = Resolve-Tool $Tool
    if ((Get-FileVersionSafe (Get-Item -LiteralPath $exe)) -ge [version]'2026.10') {
        return @('--temp', (Join-Path $c.Out '_temp'))
    }
    return @()
}

#endregion

#region ESE databases

function Get-EseState([string]$File) {
    $ErrorActionPreference = 'Continue'
    $out = & $Esentutl /mh $File 2>$null | Out-String
    # 'Clean Shutdown', 'Dirty Shutdown', 'Dirty and Patched Shutdown', 'Being Converted', ...
    if ($out -match '(?m)^\s*State:\s*(.+?)\s*$') { return $Matches[1] }
    return 'Unknown'
}

# Copies database(s) plus their transaction logs to $Destination so the evidence stays untouched.
function Copy-EseSet([string[]]$Databases, [string]$Destination) {
    [void][IO.Directory]::CreateDirectory($Destination)
    $srcDir = [IO.Path]::GetDirectoryName($Databases[0])
    $siblings = @(Get-ChildItem -LiteralPath $srcDir -File -Force -ErrorAction SilentlyContinue)
    $bases = @($siblings | Where-Object { $_.Extension -eq '.chk' } |
               ForEach-Object { $_.BaseName.Substring(0, [Math]::Min(3, $_.BaseName.Length)) })

    foreach ($db in $Databases) { Copy-Item -LiteralPath $db -Destination $Destination -Force }
    $logs = $siblings | Where-Object {
        $n = $_.Name
        ($_.Extension -in '.log', '.chk', '.jrs', '.jtx') -and
        (-not $bases.Count -or @($bases | Where-Object { $n.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count)
    }
    foreach ($l in $logs) { Copy-Item -LiteralPath $l.FullName -Destination $Destination -Force }
    Write-Info ("Copied {0} database(s) and {1} log file(s) to {2}" -f $Databases.Count, @($logs).Count, $Destination)
    return $Destination
}

function Repair-EseDirectory([string]$WorkDir) {
    $dbs = @(Get-ChildItem -LiteralPath $WorkDir -File | Where-Object { $_.Extension -in '.mdb', '.edb', '.dat' })
    $states = @{}
    foreach ($db in $dbs) { $states[$db.FullName] = Get-EseState $db.FullName }
    foreach ($db in $dbs) { Write-Info ("{0}: {1}" -f $db.Name, $states[$db.FullName]) }

    $notClean = @($dbs | Where-Object { $states[$_.FullName] -ne 'Clean Shutdown' })
    if (-not $notClean.Count) { Write-Ok 'Databases are in Clean Shutdown state.'; return }

    # Soft recovery first: replay the transaction logs (esentutl /r <base> /d = use files in the current dir).
    $chk = Get-ChildItem -LiteralPath $WorkDir -Filter '*.chk' -File | Select-Object -First 1
    $log = Get-ChildItem -LiteralPath $WorkDir -Filter '*.log' -File |
           Where-Object { $_.Name -match '^[A-Za-z0-9]{3}([0-9A-Fa-f]{5,8}|tmp|res\d{5})?\.log$' } |
           Sort-Object { $_.Name.Length } | Select-Object -First 1
    $base = if ($chk) { $chk.BaseName } elseif ($log) { $log.BaseName } else { $null }
    if ($base -and $base.Length -ge 3) {
        Write-Info "Replaying transaction logs ($($base.Substring(0, 3))*.log) ..."
        $null = Invoke-Tool esentutl @('/r', $base.Substring(0, 3), '/d', '/i', '/o') -WorkDir $WorkDir -AllowFailure
    }

    foreach ($db in $notClean) {
        $state = Get-EseState $db.FullName
        if ($state -eq 'Clean Shutdown') { Write-Ok "$($db.Name): Clean Shutdown after log replay."; continue }
        if ($state -eq 'Unknown') { Write-Warn "$($db.Name): could not read the state, skipping hard repair."; continue }
        Write-Warn "$($db.Name) is still dirty - running hard repair (esentutl /p) on the copy. Confirm the Windows dialog."
        $null = Invoke-Tool esentutl @('/p', $db.FullName, '/o') -WorkDir $WorkDir
        Write-Info ("{0}: {1}" -f $db.Name, (Get-EseState $db.FullName))
    }
}

#endregion

#region Actions

function Get-MultiHash([string]$File, [switch]$ShowProgress) {
    $algs = @([Security.Cryptography.MD5]::Create(), [Security.Cryptography.SHA1]::Create(), [Security.Cryptography.SHA256]::Create())
    $fs = [IO.File]::Open($File, 'Open', 'Read', 'ReadWrite')
    try {
        $buf = New-Object byte[] (4MB)
        $len = $fs.Length; $readTotal = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            foreach ($a in $algs) { [void]$a.TransformBlock($buf, 0, $n, $null, 0) }
            $readTotal += $n
            if ($ShowProgress -and $sw.ElapsedMilliseconds -gt 500) {
                Write-Progress -Activity 'Hashing' -Status ('{0:n0} / {1:n0} MB' -f ($readTotal / 1MB), ($len / 1MB)) -PercentComplete ([int](100 * $readTotal / [Math]::Max(1, $len)))
                $sw.Restart()
            }
        }
        foreach ($a in $algs) { [void]$a.TransformFinalBlock($buf, 0, 0) }
        if ($ShowProgress) { Write-Progress -Activity 'Hashing' -Completed }
        $hex = $algs | ForEach-Object { [BitConverter]::ToString($_.Hash).Replace('-', '') }
        return [pscustomobject]@{ Size = $len; MD5 = $hex[0]; SHA1 = $hex[1]; SHA256 = $hex[2] }
    } finally {
        $fs.Dispose()
        foreach ($a in $algs) { $a.Dispose() }
    }
}

function Invoke-Hash($c) {
    if (-not $c.IsDir) {
        $h = Get-MultiHash $c.Path -ShowProgress
        Write-Host ''
        Write-Host ('File   : {0}' -f $c.Path)
        Write-Host ('Size   : {0:n0} bytes' -f $h.Size)
        Write-Host ('MD5    : {0}' -f $h.MD5)
        Write-Host ('SHA1   : {0}' -f $h.SHA1)
        Write-Host ('SHA256 : {0}' -f $h.SHA256)
        Write-Log ('HASH "{0}" size={1} md5={2} sha1={3} sha256={4}' -f $c.Path, $h.Size, $h.MD5, $h.SHA1, $h.SHA256)
        try { Set-Clipboard -Value $h.SHA256; Write-Ok 'SHA256 copied to clipboard.' } catch { }
        return
    }

    Initialize-Output $c
    $csv = Join-Path $c.Out 'hashes.csv'
    Write-Info 'Enumerating files ...'
    $files = @(Get-ChildItem -LiteralPath $c.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
               Where-Object { -not (Test-OwnOutput $_.FullName) })
    $total = [Math]::Max(1, [double](($files | Measure-Object Length -Sum).Sum))
    Write-Info ('{0:n0} files, {1:n1} GB' -f $files.Count, ($total / 1GB))

    $prefix = $c.Path.TrimEnd('\').Length + 1
    $w = New-Object IO.StreamWriter($csv, $false, (New-Object Text.UTF8Encoding($true)))
    $done = 0; $bytes = 0; $errors = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $w.WriteLine('"RelativePath","Size","LastWriteTimeUtc","MD5","SHA1","SHA256","Error"')
        foreach ($f in $files) {
            if ($sw.ElapsedMilliseconds -gt 500) {
                Write-Progress -Activity 'Hashing' -Status ('{0:n0} / {1:n0} files' -f $done, $files.Count) -PercentComplete ([int](100 * $bytes / $total))
                $sw.Restart()
            }
            $row = @($f.FullName.Substring($prefix), $f.Length, $f.LastWriteTimeUtc.ToString('o'))
            try {
                $h = Get-MultiHash $f.FullName
                $row += @($h.MD5, $h.SHA1, $h.SHA256, '')
            } catch {
                $errors++
                $ex = $_.Exception; if ($ex.InnerException) { $ex = $ex.InnerException }
                $row += @('', '', '', $ex.Message)
            }
            $w.WriteLine((($row | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' }) -join ','))
            $done++; $bytes += $f.Length
        }
    } finally {
        $w.Dispose()
        Write-Progress -Activity 'Hashing' -Completed
    }
    Write-Log "HASHDIR files=$done errors=$errors csv=$csv"
    Write-Ok "Hashed $done files -> $csv"
    if ($errors) { $script:ToolFailures++; Write-Warn "$errors file(s) could not be read (see the Error column)." }
}

function Invoke-Chainsaw($c) {
    $set = Get-ChainsawRuleSet
    if (-not $set.Exe) { [void](Resolve-Tool Chainsaw) }

    $a = @('hunt', $c.Path)
    $useSigma = $set.Sigma -and [IO.Directory]::Exists($set.Sigma)
    if ($useSigma) {
        if (-not [IO.File]::Exists($set.Mapping)) { throw "Sigma rules need a mapping file. Not found: $($set.Mapping) (set Chainsaw.Mapping in the config)." }
        $a += @('-s', $set.Sigma, '-m', $set.Mapping)
    }
    if ($set.Rules -and [IO.Directory]::Exists($set.Rules)) { $a += @('-r', $set.Rules) }
    if ($a.Count -eq 2) { throw 'No Chainsaw or Sigma rules found. Set Chainsaw.SigmaRules / Chainsaw.Rules in the config.' }
    if (-not $useSigma) { Write-Warn 'No Sigma rules configured - hunting with built-in Chainsaw rules only.' }

    $a += @('--csv', '-o', (Join-Path $c.Out 'chainsaw')) + @($script:Config.Chainsaw.ExtraArgs)
    $null = Invoke-Tool Chainsaw $a
}

function Invoke-Mft($c) {
    $extra = @()
    $name = [IO.Path]::GetFileName($c.Path)
    if ($name -eq '$J' -or $name -eq '$LogFile' -or $name -like '$UsnJrnl*') {
        # $J is usually extracted to <vol>\$Extend\$J with $MFT at <vol>\$MFT; -m resolves parent paths.
        $dir = [IO.Path]::GetDirectoryName($c.Path)
        $cands = @(Join-Path $dir '$MFT')
        $up = [IO.Path]::GetDirectoryName($dir)
        if ($up) { $cands += (Join-Path $up '$MFT') }
        $mft = $cands | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
        if ($mft) { Write-Info "Using $mft to resolve paths."; $extra = @('-m', $mft) }
        else { Write-Warn "`$MFT not found next to $name - parent paths will not be resolved." }
    }
    Invoke-Ez MFTECmd $c -Extra $extra
}

function Invoke-RECmd($c) {
    $exe = Resolve-Tool RECmd
    $batch = Get-RECmdBatch $exe
    if (-not $batch -or -not [IO.File]::Exists($batch)) { throw 'No RECmd batch file found. Set RECmdBatch in the config (e.g. ...\RECmd\BatchExamples\Kroll_Batch.reb).' }
    Write-Info "Batch: $batch"
    $extra = @('--bn', $batch)
    if (-not $c.IsDir) {
        Invoke-Ez RECmd $c -Extra ($extra + @(Get-HiveArgs $c.Path))
        return
    }

    # -d mode fails (or silently skips) dirty hives without logs; parse those one by one with --nl.
    $nl = Find-HivesNeedingNl $c.Path
    Invoke-Ez RECmd $c -Extra $extra
    $i = 0
    foreach ($h in $nl) {
        $i++
        Write-Warn "Dirty hive without .LOG1/.LOG2, parsing separately with --nl: $h"
        $sub = @{ Path = $h; IsDir = $false; Out = (Join-Path $c.Out ('nl_{0:D2}_{1}' -f $i, (Get-SafeName ([IO.Path]::GetFileName($h))))) }
        [void][IO.Directory]::CreateDirectory($sub.Out)
        Invoke-Ez RECmd $sub -Extra ($extra + @('--nl'))
    }
}

function Invoke-SBECmd($c) {
    $nl = Find-HivesNeedingNl $c.Path
    if ($nl.Count) {
        Write-Warn "SBECmd may skip these dirty hives that have no .LOG1/.LOG2 files:`n    $($nl -join "`n    ")"
    }
    Invoke-Ez SBECmd $c
}

function Invoke-Srum($c) {
    [void](Resolve-Tool SrumECmd)
    if ($c.IsDir) {
        $db = Find-FirstFile $c.Path 'SRUDB.dat'
        if (-not $db) { throw "SRUDB.dat not found under $($c.Path)" }
        $software = Find-FirstFile $c.Path 'SOFTWARE' 'config'
    } else {
        $db = $c.Path
        # Standard layout: Windows\System32\sru\SRUDB.dat and Windows\System32\config\SOFTWARE
        $sys32 = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($db))
        $software = if ($sys32) { Join-Path $sys32 'config\SOFTWARE' } else { $null }
        if ($software -and -not [IO.File]::Exists($software)) { $software = $null }
    }
    if ($software) { Write-Info "SOFTWARE hive: $software" } else { Write-Warn 'SOFTWARE hive not found - app/user names will not be resolved.' }

    $work = Copy-EseSet @($db) (Join-Path $c.Out '_db_copy')
    Repair-EseDirectory $work
    $a = @('-f', (Join-Path $work ([IO.Path]::GetFileName($db))), '--csv', $c.Out) + @(Get-EzTempArgs SrumECmd $c)
    if ($software) { $a += @('-r', $software) }
    $null = Invoke-Tool SrumECmd $a
}

function Invoke-Sum($c) {
    [void](Resolve-Tool SumECmd)
    $dir = if ($c.IsDir) { $c.Path } else { [IO.Path]::GetDirectoryName($c.Path) }
    $mdbs = @(Get-ChildItem -LiteralPath $dir -Filter '*.mdb' -File -Force -ErrorAction SilentlyContinue)
    if (-not $mdbs.Count -and $c.IsDir) {
        $current = Find-FirstFile $dir 'Current.mdb'
        if ($current) {
            $dir = [IO.Path]::GetDirectoryName($current)
            $mdbs = @(Get-ChildItem -LiteralPath $dir -Filter '*.mdb' -File -Force)
        }
    }
    if (-not $mdbs.Count) { throw "No UAL databases (*.mdb) found in $dir" }

    $work = Copy-EseSet @($mdbs | ForEach-Object { $_.FullName }) (Join-Path $c.Out '_db_copy')
    Repair-EseDirectory $work
    $null = Invoke-Tool SumECmd (@('-d', $work, '--csv', $c.Out) + @(Get-EzTempArgs SumECmd $c))
}

# WxTCmd opens SQLite in place, which checkpoints -wal into the database: always parse a copy.
function Invoke-WxT($c) {
    [void](Resolve-Tool WxTCmd)
    $work = Join-Path $c.Out '_db_copy'
    [void][IO.Directory]::CreateDirectory($work)
    foreach ($suffix in '', '-wal', '-shm', '-journal') {
        $src = $c.Path + $suffix
        if ([IO.File]::Exists($src)) { Copy-Item -LiteralPath $src -Destination $work -Force }
    }
    $null = Invoke-Tool WxTCmd (@('-f', (Join-Path $work ([IO.Path]::GetFileName($c.Path))), '--csv', $c.Out) + @(Get-EzTempArgs WxTCmd $c))
}

function Invoke-EseRepair($c) {
    $work = Copy-EseSet @($c.Path) (Join-Path $c.Out '_db_copy')
    Repair-EseDirectory $work
    Write-Ok "Working copy: $(Join-Path $work ([IO.Path]::GetFileName($c.Path))) (original not modified)"
}

function Invoke-ToRaw($c) {
    $qemu = Resolve-Tool QemuImg
    $json = & $qemu info --output=json $c.Path | Out-String
    $info = if ($LASTEXITCODE -eq 0 -and $json.Trim()) { $json | ConvertFrom-Json } else { $null }
    if (-not $info -or -not $info.format) {
        throw "qemu-img could not read $($c.Path) (exit $LASTEXITCODE). For a VHDX with a pending log, run 'qemu-img check -r all' on a COPY."
    }
    $size = [int64]$info.'virtual-size'
    $dst = Join-Path $c.Out ([IO.Path]::GetFileNameWithoutExtension($c.Path) + '.dd')
    Write-Info ('Format: {0}, virtual size: {1:n1} GB' -f $info.format, ($size / 1GB))
    try {
        $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($dst))).AvailableFreeSpace
        if ($free -lt $size) {
            Write-Warn ('Only {0:n1} GB free on the output drive.' -f ($free / 1GB))
            if ((Read-Host 'Continue anyway? [y/N]') -notmatch '^[yYtT]') { throw 'Cancelled by user.' }
        }
    } catch [System.ArgumentException] { }
    $null = Invoke-Tool QemuImg @('convert', '-p', '-f', $info.format, '-O', 'raw', $c.Path, $dst)
    if ([IO.File]::Exists($dst)) { Write-Ok "RAW image: $dst" }
}

function Invoke-Triage($c) {
    if ($c.Path.TrimEnd('\') -ieq $env:SystemDrive) {
        Write-Warn "This is the live system drive ($($c.Path)). Triage is meant for collected/mounted evidence."
        if ((Read-Host 'Continue anyway? [y/N]') -notmatch '^[yYtT]') { throw 'Cancelled by user.' }
    }

    Write-Info 'Indexing files ...'
    $byName = @{}; $exts = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $c.Path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if (Test-OwnOutput $f.FullName) { continue }
        $n = $f.Name.ToLowerInvariant()
        if (-not $byName.ContainsKey($n)) { $byName[$n] = [System.Collections.Generic.List[object]]::new() }
        $byName[$n].Add($f)
        $exts[$f.Extension.ToLowerInvariant()] = $true
    }
    $named = { param($n) if ($byName.ContainsKey($n.ToLowerInvariant())) { , $byName[$n.ToLowerInvariant()].ToArray() } else { , @() } }

    $steps = [System.Collections.Generic.List[object]]::new()
    $addDir  = { param($id) $steps.Add(@{ Id = $id; Path = $c.Path; IsDir = $true }) }
    $addFile = { param($id, $f) $steps.Add(@{ Id = $id; Path = $f.FullName; IsDir = $false }) }

    if ($exts['.evtx']) { & $addDir 'evtx'; & $addDir 'chainsaw' }
    if ($exts['.pf'])   { & $addDir 'prefetch' }
    if ($exts['.lnk'])  { & $addDir 'lnk' }
    if ($exts['.automaticdestinations-ms'] -or $exts['.customdestinations-ms']) { & $addDir 'jumplist' }
    $hives = @($HiveNames | Where-Object { $_ -ne 'Amcache.hve' } | ForEach-Object { & $named $_ })
    if ($hives.Count) { & $addDir 'registry' }
    if ((@(& $named 'NTUSER.DAT') + @(& $named 'UsrClass.dat')).Count) { & $addDir 'shellbags' }
    foreach ($f in (& $named 'SYSTEM'))             { if ($f.Directory.Name -eq 'config') { & $addFile 'shimcache' $f } }
    foreach ($f in (& $named 'Amcache.hve'))        { & $addFile 'amcache' $f }
    foreach ($f in (& $named '$MFT'))               { & $addFile 'mft' $f }
    foreach ($f in (& $named '$J'))                 { & $addFile 'mft' $f }
    foreach ($f in (& $named 'SRUDB.dat'))          { & $addFile 'srum' $f }
    foreach ($f in (& $named 'Current.mdb'))        { & $addFile 'ual' $f }
    foreach ($f in (& $named 'ActivitiesCache.db')) { & $addFile 'activities' $f }
    if (@($byName.Keys | Where-Object { $_ -like '$i*' -and $_ -ne '$i30' } | Select-Object -First 1).Count) { & $addDir 'recyclebin' }

    if (-not $steps.Count) { throw "No known artifacts found under $($c.Path)" }
    Write-Info "$($steps.Count) parser run(s) planned."

    $results = @()
    $i = 0
    foreach ($s in $steps) {
        $i++
        $entry = $Catalog | Where-Object { $_.Id -eq $s.Id }
        $input_ = if ($s.IsDir) { '' } else { $s.Path.Substring([Math]::Min($s.Path.Length, $c.Path.TrimEnd('\').Length + 1)) }
        Write-Host ''
        Write-Host ("===== [{0}/{1}] {2} {3}" -f $i, $steps.Count, $entry.Title, $input_) -ForegroundColor Magenta

        if ($entry.Tool -and -not (Resolve-Tool $entry.Tool -Optional)) {
            Write-Warn "$($entry.Tool) not available - skipped."
            $results += [pscustomobject]@{ Step = $entry.Title; Input = $input_; Status = 'SKIPPED (tool missing)'; Seconds = 0 }
            continue
        }
        $sub = @{ Action = $s.Id; Path = $s.Path; IsDir = $s.IsDir; Out = (Join-Path $c.Out ('{0:D2}_{1}' -f $i, $s.Id)) }
        [void][IO.Directory]::CreateDirectory($sub.Out)
        $before = $script:ToolFailures
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            & $entry.Run $sub
            # Most EZ tool releases exit 0 even when they fail, so also check that CSVs were produced.
            $status = if ($script:ToolFailures -gt $before) { 'WARN (non-zero exit)' }
                      elseif (-not @(Get-ChildItem -LiteralPath $sub.Out -Recurse -File -Filter '*.csv' -ErrorAction SilentlyContinue).Count) { 'WARN (no CSV output)' }
                      else { 'OK' }
        } catch {
            Write-Err $_.Exception.Message
            Write-Log "ERROR [$($s.Id)] $($_.Exception.Message)"
            $status = 'FAILED: ' + $_.Exception.Message
        }
        $results += [pscustomobject]@{ Step = $entry.Title; Input = $input_; Status = $status; Seconds = [int]$sw.Elapsed.TotalSeconds }
    }

    Write-Host ''
    Write-Host '===== Triage summary' -ForegroundColor Magenta
    $results | Format-Table Step, Status, Seconds, Input -AutoSize | Out-String -Width 250 | Write-Host
    $results | Export-Csv -LiteralPath (Join-Path $c.Out 'triage_summary.csv') -NoTypeInformation -Encoding UTF8
}

function Show-ToolTable {
    $null = Update-ToolCache
    Write-Host ''
    Write-Host 'Tools' -ForegroundColor White
    foreach ($tool in $ToolFiles.Keys) {
        $p = Resolve-Tool $tool -Optional
        if ($p) { Write-Host ('  [+] {0,-22}{1}' -f $tool, $p) -ForegroundColor Green }
        else    { Write-Host ('  [-] {0,-22}not found' -f $tool) -ForegroundColor DarkYellow }
    }
    Write-Host ('  [+] {0,-22}{1}' -f 'esentutl', $Esentutl) -ForegroundColor Green

    Write-Host ''
    Write-Host 'Rules' -ForegroundColor White
    $cs = Get-ChainsawRuleSet
    foreach ($item in @(@('Chainsaw Sigma', $cs.Sigma, 'D'), @('Chainsaw mapping', $cs.Mapping, 'F'), @('Chainsaw rules', $cs.Rules, 'D'),
                        @('RECmd batch', (Get-RECmdBatch (Resolve-Tool RECmd -Optional)), 'F'))) {
        $ok = $item[1] -and $(if ($item[2] -eq 'D') { [IO.Directory]::Exists($item[1]) } else { [IO.File]::Exists($item[1]) })
        if ($ok) { Write-Host ('  [+] {0,-22}{1}' -f $item[0], $item[1]) -ForegroundColor Green }
        else     { Write-Host ('  [-] {0,-22}{1}' -f $item[0], $(if ($item[1]) { "missing: $($item[1])" } else { 'not set' })) -ForegroundColor DarkYellow }
    }
}

function Show-Doctor {
    Write-Host "Version : $Version"
    Write-Host "Config  : $ConfigFile"
    Write-Host "Roots   : $((@($script:Config.ToolRoots) | ForEach-Object { Expand-PathValue $_ }) -join '; ')"
    Write-Host "Output  : $($script:Config.OutputMode) (fallback: $(Expand-PathValue $script:Config.OutputRoot))"
    Show-ToolTable
    Write-Host ''
    Write-Info 'Missing tools: drop them under one of the roots or set Tools.<Name> in the config, then use "Refresh menu".'
    if ([Environment]::OSVersion.Version.Build -ge 22000) {
        Write-Info 'Windows 11: the menu is under "Show more options" (or Shift+Right-click).'
    }
}

#endregion

#region Catalog

function Aqs([string[]]$Ext = @(), [string[]]$Name = @(), [string[]]$Prefix = @()) {
    $p = @()
    foreach ($e in $Ext)    { $p += 'System.FileExtension:="{0}"' -f $e }
    foreach ($n in $Name)   { $p += 'System.FileName:="{0}"' -f $n }
    foreach ($x in $Prefix) { $p += 'System.FileName:~<"{0}"' -f $x }
    return ($p -join ' OR ')
}

# Menu order follows this list; a separator is drawn where Group changes.
# Scope: File = right-click on a file, Dir = folder, drive or folder background.
# Match: AQS filter so file items only show for matching files.
$Catalog = @(
    @{ Id = 'hash'; Title = 'Hash (MD5/SHA1/SHA256)'; Group = 1; Scope = 'File', 'Dir'; NoOutput = $true
       Run = { param($c) Invoke-Hash $c } }
    @{ Id = 'timeline'; Title = 'Open in Timeline Explorer'; Group = 1; Scope = 'File'; Tool = 'TimelineExplorer'
       Match = (Aqs -Ext '.csv', '.xlsx', '.tle_sess'); NoOutput = $true; Hidden = $true; NoPause = $true
       Run = { param($c) Start-Process -FilePath (Resolve-Tool TimelineExplorer) -ArgumentList (ConvertTo-ArgumentString @($c.Path)) } }
    @{ Id = 'triage'; Title = 'Full triage (all parsers)'; Group = 1; Scope = 'Dir'
       Run = { param($c) Invoke-Triage $c } }

    @{ Id = 'chainsaw'; Title = 'Event logs - Chainsaw hunt'; Group = 2; Scope = 'File', 'Dir'; Tool = 'Chainsaw'
       Match = (Aqs -Ext '.evtx'); Run = { param($c) Invoke-Chainsaw $c } }
    @{ Id = 'evtx'; Title = 'Event logs - EvtxECmd'; Group = 2; Scope = 'File', 'Dir'; Tool = 'EvtxECmd'
       Match = (Aqs -Ext '.evtx'); Run = { param($c) Invoke-Ez EvtxECmd $c } }

    @{ Id = 'mft'; Title = 'NTFS ($MFT/$J/$Boot/$SDS) - MFTECmd'; Group = 3; Scope = 'File'; Tool = 'MFTECmd'
       Match = (Aqs -Name '$MFT', '$J', '$LogFile', '$Boot', '$SDS', '$Secure_$SDS', '$I30' -Prefix '$UsnJrnl'); Run = { param($c) Invoke-Mft $c } }
    @{ Id = 'prefetch'; Title = 'Prefetch - PECmd'; Group = 3; Scope = 'File', 'Dir'; Tool = 'PECmd'
       Match = (Aqs -Ext '.pf'); Run = { param($c) Invoke-Ez PECmd $c -Quiet } }
    @{ Id = 'lnk'; Title = 'LNK files - LECmd'; Group = 3; Scope = 'File', 'Dir'; Tool = 'LECmd'
       Match = (Aqs -Ext '.lnk'); Run = { param($c) Invoke-Ez LECmd $c -Quiet } }
    @{ Id = 'jumplist'; Title = 'Jump lists - JLECmd'; Group = 3; Scope = 'File', 'Dir'; Tool = 'JLECmd'
       Match = (Aqs -Ext '.automaticDestinations-ms', '.customDestinations-ms'); Run = { param($c) Invoke-Ez JLECmd $c -Quiet } }
    @{ Id = 'recyclebin'; Title = 'Recycle Bin ($I) - RBCmd'; Group = 3; Scope = 'File', 'Dir'; Tool = 'RBCmd'
       Match = '(System.FileName:~<"$I" AND System.FileName:<>"$I30")'; Run = { param($c) Invoke-Ez RBCmd $c -Quiet } }
    @{ Id = 'amcache'; Title = 'Amcache - AmcacheParser'; Group = 3; Scope = 'File'; Tool = 'AmcacheParser'
       Match = (Aqs -Name 'Amcache.hve'); Run = { param($c) Invoke-Ez AmcacheParser $c -Extra (@('-i') + @(Get-HiveArgs $c.Path) + @(Get-EzTempArgs AmcacheParser $c)) } }
    @{ Id = 'shimcache'; Title = 'ShimCache - AppCompatCacheParser'; Group = 3; Scope = 'File'; Tool = 'AppCompatCacheParser'
       Match = (Aqs -Name 'SYSTEM'); Run = { param($c) Invoke-Ez AppCompatCacheParser $c -Extra @(Get-HiveArgs $c.Path) } }

    @{ Id = 'registry'; Title = 'Registry - RECmd (batch)'; Group = 4; Scope = 'File', 'Dir'; Tool = 'RECmd'
       Match = (Aqs -Name 'NTUSER.DAT', 'UsrClass.dat', 'SYSTEM', 'SOFTWARE', 'SAM', 'SECURITY', 'DEFAULT', 'Amcache.hve')
       Run = { param($c) Invoke-RECmd $c } }
    @{ Id = 'shellbags'; Title = 'ShellBags - SBECmd'; Group = 4; Scope = 'Dir'; Tool = 'SBECmd'
       Run = { param($c) Invoke-SBECmd $c } }

    @{ Id = 'srum'; Title = 'SRUM - SrumECmd'; Group = 5; Scope = 'File', 'Dir'; Tool = 'SrumECmd'
       Match = (Aqs -Name 'SRUDB.dat'); Run = { param($c) Invoke-Srum $c } }
    @{ Id = 'ual'; Title = 'UAL (SUM) - SumECmd'; Group = 5; Scope = 'File', 'Dir'; Tool = 'SumECmd'
       Match = (Aqs -Ext '.mdb'); Run = { param($c) Invoke-Sum $c } }
    @{ Id = 'activities'; Title = 'Windows Timeline - WxTCmd'; Group = 5; Scope = 'File'; Tool = 'WxTCmd'
       Match = (Aqs -Name 'ActivitiesCache.db'); Run = { param($c) Invoke-WxT $c } }
    @{ Id = 'ese-repair'; Title = 'Repair ESE database (copy)'; Group = 5; Scope = 'File'
       Match = (Aqs -Ext '.edb', '.mdb' -Name 'SRUDB.dat' -Prefix 'WebCacheV'); Run = { param($c) Invoke-EseRepair $c } }

    @{ Id = 'to-raw'; Title = 'Disk image to RAW (.dd) - qemu-img'; Group = 6; Scope = 'File'; Tool = 'QemuImg'
       Match = (Aqs -Ext '.vhdx', '.vhd', '.vmdk', '.qcow2', '.vdi'); Run = { param($c) Invoke-ToRaw $c } }

    @{ Id = 'doctor'; Title = 'Check tools'; Group = 9; Scope = 'File', 'Dir'; NoOutput = $true; NoPath = $true
       Run = { param($c) Show-Doctor } }
    @{ Id = 'config'; Title = 'Edit configuration'; Group = 9; Scope = 'File', 'Dir'; NoOutput = $true; NoPath = $true; Hidden = $true; NoPause = $true
       Run = { param($c) Open-Config } }
    @{ Id = 'refresh'; Title = 'Refresh menu (after config change)'; Group = 9; Scope = 'File', 'Dir'; NoOutput = $true; NoPath = $true
       Run = { param($c) Register-Menu } }
)

#endregion

#region Install / uninstall

function Set-RegValues([string]$SubKey, [hashtable]$Values) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKey)
    try {
        foreach ($name in $Values.Keys) {
            $v = $Values[$name]
            if ($v -is [int]) { $k.SetValue($name, $v, [Microsoft.Win32.RegistryValueKind]::DWord) }
            else { $k.SetValue($name, [string]$v, [Microsoft.Win32.RegistryValueKind]::String) }
        }
    } finally { $k.Close() }
}

function Send-ShellRefresh {
    try {
        if (-not ('ForensicAid.Shell' -as [type])) {
            Add-Type -Namespace ForensicAid -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, IntPtr a, IntPtr b);'
        }
        [ForensicAid.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)   # SHCNE_ASSOCCHANGED
    } catch { }
}

function Remove-Menu {
    $hkcu = [Microsoft.Win32.Registry]::CurrentUser
    foreach ($r in $MenuRoots) { $hkcu.DeleteSubKeyTree("$RegClasses\$($r.Key)", $false) }
    $hkcu.DeleteSubKeyTree("$RegClasses\$MenuStore", $false)
}

function Register-Menu {
    $script:Config = Import-Config
    Write-Info 'Scanning for tools ...'
    $null = Update-ToolCache
    Remove-Menu

    $psExe = Join-Path $PSHOME 'powershell.exe'
    $scriptPath = Join-Path $InstallDir 'ForensicAid.ps1'
    $icon = Join-Path $InstallDir 'icon.ico'
    $placeholders = @{ File = '%1'; Dir = '%1'; Background = '%V' }

    foreach ($menu in 'File', 'Dir', 'Background') {
        $scope = if ($menu -eq 'File') { 'File' } else { 'Dir' }
        $i = 0; $lastGroup = $null; $titles = @()
        foreach ($e in $Catalog) {
            if ($e.Scope -notcontains $scope) { continue }
            if (@($script:Config.Disabled) -contains $e.Id) { continue }
            $exe = $null
            if ($e.Tool) {
                $exe = Resolve-Tool $e.Tool -Optional
                if (-not $exe -and $script:Config.HideUnavailable) { continue }
            }
            $i++
            $key = '{0}\{1}\{2}\shell\{3:D2}_{4}' -f $RegClasses, $MenuStore, $menu, $i, $e.Id
            $vals = @{ MUIVerb = $e.Title; MultiSelectModel = 'Single' }
            if ($exe) { $vals.Icon = "$exe,0" }
            if ($null -ne $lastGroup -and $e.Group -ne $lastGroup) { $vals.CommandFlags = 0x20 }   # ECF_SEPARATORBEFORE
            if ($menu -eq 'File' -and $e.Match -and $script:Config.FilterByFileType) { $vals.AppliesTo = $e.Match }
            $lastGroup = $e.Group

            $style = if ($e.Hidden) { ' -WindowStyle Hidden' } else { '' }
            $cmd = '"{0}" -NoProfile -ExecutionPolicy Bypass{1} -File "{2}" -Action {3} -Path "{4}"' -f $psExe, $style, $scriptPath, $e.Id, $placeholders[$menu]
            Set-RegValues $key $vals
            Set-RegValues "$key\command" @{ '' = $cmd }
            $titles += $e.Title
        }
        Write-Ok ("{0,-10} menu: {1} item(s)" -f $menu, $titles.Count)
    }

    foreach ($r in $MenuRoots) {
        Set-RegValues "$RegClasses\$($r.Key)" @{
            MUIVerb                = 'ForensicAid'
            Icon                   = $icon
            ExtendedSubCommandsKey = "$MenuStore\$($r.Menu)"
            MultiSelectModel       = 'Single'
        }
    }
    Send-ShellRefresh
    Write-Ok 'Context menu registered.'
}

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-RegKey($Root, [string]$SubKey) {
    $k = $Root.OpenSubKey($SubKey)
    if ($k) { $k.Close(); return $true }
    return $false
}

# Older builds that would clash with this one: menus under our key names that this version did not
# create (earlier ForensicAid / EZ_Mouse scripts) and the Python "DFIR Toolbox" (setup.py) install.
function Get-LegacyItems {
    $items = @()
    $hkcu = [Microsoft.Win32.Registry]::CurrentUser
    foreach ($r in $MenuRoots) {
        $sub = "$RegClasses\$($r.Key)"
        $k = $hkcu.OpenSubKey($sub)
        if (-not $k) { continue }
        $ext = [string]$k.GetValue('ExtendedSubCommandsKey')
        $k.Close()
        if ($ext -notlike "$MenuStore\*") { $items += @{ Hive = 'HKCU'; Key = $sub; What = 'older ForensicAid menu' } }
    }

    if ($env:FORENSICAID_REGROOT) { return $items }   # test mode: never look at machine-wide state
    $hklm = [Microsoft.Win32.Registry]::LocalMachine
    foreach ($sub in 'SOFTWARE\Classes\*\shell\HannsForensics', 'SOFTWARE\DFIR_Toolbox') {
        if (Test-RegKey $hklm $sub) { $items += @{ Hive = 'HKLM'; Key = $sub; What = 'DFIR Toolbox (setup.py) registry' } }
    }
    $store = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CommandStore\shell'
    $s = $hklm.OpenSubKey($store)
    if ($s) {
        foreach ($v in @($s.GetSubKeyNames() | Where-Object { $_ -like 'dfir_toolbox_*' })) {
            $items += @{ Hive = 'HKLM'; Key = "$store\$v"; What = 'DFIR Toolbox (setup.py) command' }
        }
        $s.Close()
    }
    $dir = Join-Path $env:ProgramData 'DFIR_Toolbox'
    if ([IO.Directory]::Exists($dir)) { $items += @{ Hive = 'Dir'; Key = $dir; What = 'DFIR Toolbox (setup.py) files' } }
    return $items
}

# Backs every item up into $Backup (reg export / file copy) and deletes it only when the backup worked.
function Remove-LegacyItems([object[]]$Items, [string]$Backup) {
    [void][IO.Directory]::CreateDirectory($Backup)
    $n = @(Get-ChildItem -LiteralPath $Backup -File -ErrorAction SilentlyContinue).Count
    foreach ($it in $Items) {
        $n++
        if ($it.Hive -eq 'Dir') {
            Copy-Item -LiteralPath $it.Key -Destination (Join-Path $Backup ('{0:D2}_{1}' -f $n, (Split-Path $it.Key -Leaf))) -Recurse -Force
            Remove-Item -LiteralPath $it.Key -Recurse -Force
        } else {
            $regFile = Join-Path $Backup ('{0:D2}_{1}.reg' -f $n, (Get-SafeName ($it.Key -replace '[\\*]', '_')))
            $ErrorActionPreference = 'Continue'
            & reg.exe export "$($it.Hive)\$($it.Key)" $regFile /y 2>&1 | Out-Null
            $ErrorActionPreference = 'Stop'
            if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($regFile)) { throw "Backup of $($it.Hive)\$($it.Key) failed - not deleting it." }
            $root = if ($it.Hive -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
            $root.DeleteSubKeyTree($it.Key, $false)
        }
        Write-Ok "Removed $($it.Hive)\$($it.Key)"
    }
}

# Returns $true when nothing old is left (or the user agreed and it was removed).
function Resolve-LegacyInstall {
    $items = @(Get-LegacyItems)
    if (-not $items.Count) { return $true }

    Write-Host ''
    Write-Warn 'Found entries from older ForensicAid / DFIR Toolbox versions:'
    foreach ($it in $items) { Write-Host ('      {0,-5} {1}   ({2})' -f $it.Hive, $it.Key, $it.What) }
    Write-Host ''
    Write-Host '  They use the same menu keys or would duplicate the menu, so they must be removed to install'
    Write-Host '  this version. A backup (.reg exports and copies of files) is saved first. Other files of the'
    Write-Host '  old tools (e.g. scripts in their own folders) are not touched.'
    if (-not $Yes) {
        if ((Read-Host '  Remove them now? [y/N]') -notmatch '^[yYtT]') { return $false }
    }

    $backup = Join-Path $InstallDir ('legacy_backup\{0:yyyyMMdd_HHmmss}' -f (Get-Date))
    $userItems = @($items | Where-Object { $_.Hive -eq 'HKCU' })
    $adminItems = @($items | Where-Object { $_.Hive -ne 'HKCU' })
    if ($userItems.Count) { Remove-LegacyItems $userItems $backup }
    if ($adminItems.Count) {
        if (Test-IsAdmin) {
            Remove-LegacyItems $adminItems $backup
        } else {
            # Only the machine-wide part needs admin; HKCU was handled above in this user's own hive.
            Write-Info 'Machine-wide entries need administrator rights - confirm the UAC prompt.'
            try {
                $p = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -Wait -PassThru -ArgumentList (
                    '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RemoveLegacy -BackupDir "{1}"' -f $PSCommandPath, $backup)
            } catch {
                throw 'Administrator rights were refused - the machine-wide leftovers are still there.'
            }
            if ($p.ExitCode -ne 0) { throw "Removing machine-wide leftovers failed (exit $($p.ExitCode))." }
            if (@(Get-LegacyItems).Count) { throw 'Some old entries are still present.' }
        }
    }
    Write-Ok "Old entries removed. Backup: $backup"
    return $true
}

# Asks a running tray icon to close (so it removes its icon), then ends any that did not.
function Stop-Tray {
    $signal = $null
    if ([Threading.EventWaitHandle]::TryOpenExisting('Local\ForensicAidTray.Exit', [ref]$signal)) {
        [void]$signal.Set()
        $signal.Dispose()
    }
    $procs = @()
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
                   Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*ForensicAidTray.ps1*' })
    } catch { }
    foreach ($p in $procs) {
        try { Wait-Process -Id $p.ProcessId -Timeout 5 -ErrorAction Stop }
        catch { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { } }
    }
    if ($procs.Count) { Write-Ok 'Tray icon stopped.' }
}

function Start-Tray {
    if (-not [IO.File]::Exists($TrayScript)) { Write-Warn "Tray icon not found: $TrayScript"; return }
    $psExe = Join-Path $PSHOME 'powershell.exe'
    $trayArgs = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $TrayScript
    Set-RegValues $RunKey @{ ForensicAidTray = ('"{0}" {1}' -f $psExe, $trayArgs) }
    Start-Process -FilePath $psExe -ArgumentList $trayArgs -WindowStyle Hidden
    Write-Ok 'Tray icon started (also at logon - untick "Start with Windows" in its menu to stop that).'
}

function Install-ForensicAid {
    Write-Host "ForensicAid $Version - installing for $env:USERNAME" -ForegroundColor White
    # Before anything is changed: older versions must go first, otherwise stop here untouched.
    if (-not (Resolve-LegacyInstall)) {
        Write-Err 'Installation cancelled - nothing was changed. The old entries must be removed to install this version.'
        exit 1
    }
    # FORENSICAID_REGROOT = test install: leave the real Run key and any running tray alone.
    $withTray = -not $env:FORENSICAID_REGROOT
    if ($withTray) { Stop-Tray }
    [void][IO.Directory]::CreateDirectory($InstallDir)
    $src = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    if ($src -ine [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')) {
        foreach ($f in 'ForensicAid.ps1', 'ForensicAidTray.ps1', 'icon.ico') {
            Copy-Item -LiteralPath (Join-Path $src $f) -Destination $InstallDir -Force
        }
        if ($ResetConfig -or -not [IO.File]::Exists($ConfigFile)) {
            Copy-Item -LiteralPath (Join-Path $src 'ForensicAid.config.psd1') -Destination $ConfigFile -Force
            Write-Ok "Config written: $ConfigFile"
        } else {
            Write-Info "Keeping existing config: $ConfigFile (use -ResetConfig to overwrite)"
        }
    }
    Get-ChildItem -LiteralPath $InstallDir -File | Unblock-File
    Write-Ok "Files installed to $InstallDir"

    Register-Menu
    if ($withTray) { Start-Tray } else { Write-Info 'Test mode (FORENSICAID_REGROOT): tray icon not started or added to autostart.' }
    Show-ToolTable
    Write-Host ''
    Write-Info "Edit tool paths in $ConfigFile and use ForensicAid > Refresh menu."
    if ([Environment]::OSVersion.Version.Build -ge 22000) {
        Write-Info 'Windows 11: the menu is under "Show more options" (or Shift+Right-click).'
    }
}

function Uninstall-ForensicAid {
    if (-not $env:FORENSICAID_REGROOT) {
        Stop-Tray
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RunKey, $true)
        if ($k) { try { $k.DeleteValue('ForensicAidTray', $false) } finally { $k.Close() } }
    }
    Remove-Menu
    Send-ShellRefresh
    Write-Ok 'Context menu removed.'
    foreach ($f in 'ForensicAid.ps1', 'ForensicAidTray.ps1', 'icon.ico', 'tools.cache.json') {
        $p = Join-Path $InstallDir $f
        if ([IO.File]::Exists($p)) { Remove-Item -LiteralPath $p -Force }
    }
    Write-Info "Config and history kept in $InstallDir - delete the folder to remove them."
    $left = @(Get-LegacyItems)
    if ($left.Count) { Write-Warn "Entries from older versions are still present ($($left.Count)); install.cmd offers to remove them." }
}

#endregion

#region Main

if ($Install)   { Install-ForensicAid; return }
if ($Uninstall) { Uninstall-ForensicAid; return }

# Elevated helper started by Resolve-LegacyInstall: machine-wide leftovers only.
if ($RemoveLegacy) {
    try {
        Remove-LegacyItems @(Get-LegacyItems | Where-Object { $_.Hive -ne 'HKCU' }) $BackupDir
    } catch {
        Write-Err $_.Exception.Message
        Wait-AnyKey
        exit 1
    }
    return
}

if ($RegisterMenu) {
    try { Register-Menu } catch { Write-Err $_.Exception.Message; exit 1 }
    return
}

# JSON for the tray icon - stdout must carry nothing but the JSON.
if ($ListActions) {
    try {
        $script:Config = Import-Config
        if (-not [IO.File]::Exists($CacheFile)) { $null = Update-ToolCache }
        $trayOff = @(Get-MenuState)
        $list = foreach ($e in $Catalog) {
            $enabled = @($script:Config.Disabled) -notcontains $e.Id
            [pscustomobject]@{
                Id             = $e.Id
                Title          = $e.Title
                Group          = $e.Group
                Scope          = @($e.Scope)
                Tool           = $e.Tool
                Available      = (-not $e.Tool) -or [bool](Resolve-Tool $e.Tool -Optional)
                Enabled        = $enabled
                ConfigDisabled = (-not $enabled) -and ($trayOff -notcontains $e.Id)
                NoPath         = [bool]$e.NoPath
            }
        }
        ConvertTo-Json -InputObject @($list) -Depth 3
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
    return
}

$entry = $Catalog | Where-Object { $_.Id -eq $Action } | Select-Object -First 1
$failed = $false
$c = $null
try {
    try {
        $script:Config = Import-Config
    } catch {
        # A broken config must not lock out "Edit configuration" / "Check tools".
        if (-not ($entry -and $entry.NoPath)) { throw }
        Write-Warn $_.Exception.Message
        $script:Config = Import-Config -DefaultsOnly
    }
    if (-not $entry) { throw "Unknown action '$Action'. Known: $(($Catalog | ForEach-Object { $_.Id }) -join ', ')" }
    try { $Host.UI.RawUI.WindowTitle = "ForensicAid - $($entry.Title)" } catch { }

    # Explorer passes "E:\" for drive roots; the trailing \" turns into a literal quote, so undo that.
    $p = if ($Path) { $Path.Trim().Trim('"') } else { '' }
    if ($p -match '^[A-Za-z]:$') { $p += '\' }
    $c = @{ Action = $entry.Id; Path = $p; IsDir = $false; Out = $null }

    if (-not $entry.NoPath) {
        if (-not $p) { throw 'No -Path given.' }
        $c.IsDir = [IO.Directory]::Exists($p)
        if (-not $c.IsDir -and -not [IO.File]::Exists($p)) { throw "Path not found: $p" }
        if ($c.IsDir -and $entry.Scope -notcontains 'Dir') { throw "'$($entry.Title)' works on files, not folders." }
        if (-not $c.IsDir -and $entry.Scope -notcontains 'File') { throw "'$($entry.Title)' works on folders, not files." }
        Write-Host ("ForensicAid :: {0}" -f $entry.Title) -ForegroundColor White
        Write-Host ("Input       :: {0}" -f $p) -ForegroundColor White
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not $entry.NoOutput) { Initialize-Output $c }
    & $entry.Run $c
    $failed = $script:ToolFailures -gt 0

    if (-not $entry.NoPath -and -not $entry.Hidden) {
        Write-Host ''
        if ($failed) { Write-Warn ("Finished with warnings in {0:n1}s" -f $sw.Elapsed.TotalSeconds) }
        else { Write-Ok ("Done in {0:n1}s" -f $sw.Elapsed.TotalSeconds) }
    }
} catch {
    $failed = $true
    Write-Host ''
    Write-Err $_.Exception.Message
    Write-Log "ERROR $($_.Exception.Message)"
}

if ($c -and $c.Out -and [IO.Directory]::Exists($c.Out)) {
    Write-Info "Results: $($c.Out)"
    if ($script:Config -and $script:Config.OpenOutputFolder -and @(Get-ChildItem -LiteralPath $c.Out -Force).Count) {
        Start-Process explorer.exe -ArgumentList (ConvertTo-ArgumentString @($c.Out))
    }
}

$pause = if ($script:Config) { $script:Config.PauseOnExit } else { 'Always' }
if (-not ($entry -and $entry.NoPause) -and ($pause -eq 'Always' -or ($pause -eq 'OnError' -and $failed))) { Wait-AnyKey }
if ($failed) { exit 1 }

#endregion
