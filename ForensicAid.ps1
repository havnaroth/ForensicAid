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
      ForensicAid.ps1 -SettingsInfo             config and tool status as JSON (used by the settings window)
      ForensicAid.ps1 -SetConfig <file.json>    save settings into the config, then re-register the menu

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
    [Parameter(ParameterSetName = 'Install')] [Parameter(ParameterSetName = 'ScanTools')] [switch] $Yes,
    [Parameter(ParameterSetName = 'ScanTools', Mandatory)] [switch] $ScanTools,
    [Parameter(ParameterSetName = 'ScanTools')] [switch] $Deep,
    [Parameter(ParameterSetName = 'RemoveLegacy', Mandatory)] [switch] $RemoveLegacy,
    [Parameter(ParameterSetName = 'RemoveLegacy', Mandatory)] [string] $BackupDir,
    [Parameter(ParameterSetName = 'Uninstall', Mandatory)] [switch] $Uninstall,
    [Parameter(ParameterSetName = 'ListActions', Mandatory)] [switch] $ListActions,
    [Parameter(ParameterSetName = 'RegisterMenu', Mandatory)] [switch] $RegisterMenu,
    [Parameter(ParameterSetName = 'SettingsInfo', Mandatory)] [switch] $SettingsInfo,
    [Parameter(ParameterSetName = 'SetConfig', Mandatory)] [string] $SetConfig
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
$MenuJson   = Join-Path $InstallDir 'menu.json'   # read by the Windows 11 extension
$ShellPackage = 'ForensicAid.ShellExtension'
$RunKey     = 'Software\Microsoft\Windows\CurrentVersion\Run'   # autostart fallback (and older versions)
$TaskName   = 'ForensicAidTray ({0})' -f $env:USERNAME   # per-user logon task that starts the tray
$Esentutl  = Join-Path $env:windir 'System32\esentutl.exe'

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
    RdpCacheStitcher     = @('RdpCacheStitcher.exe')
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
    Win11Menu        = $true
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

function Open-Config([switch]$File) {
    if (-not [IO.File]::Exists($ConfigFile)) {
        [void][IO.Directory]::CreateDirectory($InstallDir)
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ForensicAid.config.psd1') -Destination $ConfigFile
    }
    $settings = Join-Path $PSScriptRoot 'ForensicAidSettings.ps1'
    if (-not $File -and [IO.File]::Exists($settings)) {
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $settings)
        return
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
    param([string]$Tool, [object[]]$Arguments, [string]$WorkDir, [switch]$AllowFailure, [string]$ArgLine, [string]$Exe)

    $exe = if ($Exe) { $Exe } elseif ($Tool -eq 'esentutl') { $Esentutl } else { Resolve-Tool $Tool }
    $argLine = if ($PSBoundParameters.ContainsKey('ArgLine')) { $ArgLine } else { ConvertTo-ArgumentString $Arguments }

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

#endregion

#region Command templates

# Each menu item that runs one program has a command template: its arguments with {placeholders}.
# The built-in template sits in the catalog; actions\<id>.psd1 can replace it (Settings > Menu items).
# A placeholder outside quotes becomes ready-quoted arguments (a list adds several, an empty list none);
# inside quotes ("{Out}\x") the raw value is inserted.
function Expand-CommandTemplate([string]$Template, [hashtable]$Vars) {
    $sb = New-Object Text.StringBuilder
    $pos = 0
    foreach ($m in [regex]::Matches($Template, '\{(\w+)\}')) {
        $name = $m.Groups[1].Value
        if (-not $Vars.ContainsKey($name)) { throw "Unknown placeholder {$name} in the command: $Template" }
        [void]$sb.Append($Template, $pos, $m.Index - $pos)
        $values = @($Vars[$name] | Where-Object { $null -ne $_ })
        $inQuotes = (@($Template.Substring(0, $m.Index).ToCharArray() | Where-Object { $_ -eq '"' }).Count % 2) -eq 1
        if ($inQuotes) {
            $raw = ($values | ForEach-Object { [string]$_ }) -join ' '
            $end = $m.Index + $m.Length
            if ($end -lt $Template.Length -and $Template[$end] -eq '"') { $raw = $raw -replace '(\\+)$', '$1$1' }   # "E:\" would escape the quote
            [void]$sb.Append($raw)
        } elseif ($values.Count -eq 1 -and [string]$values[0] -eq '') {
            [void]$sb.Append('""')
        } else {
            [void]$sb.Append((ConvertTo-ArgumentString $values))
        }
        $pos = $m.Index + $m.Length
    }
    [void]$sb.Append($Template.Substring($pos))
    return $sb.ToString().Trim()
}

function Get-EntryCommand($Entry) {
    if ($Entry.UserCommand) { return $Entry.UserCommand }
    return $Entry.Command
}

# Placeholders every item has; items add their own (Vars in the catalog).
function Get-BaseVars($c) {
    return @{
        Path = $c.Path
        In   = $(if ($c.IsDir) { @('-d', $c.Path) } else { @('-f', $c.Path) })
        Out  = [string]$c.Out
        Name = [IO.Path]::GetFileName($c.Path.TrimEnd('\'))
        Dir  = $(if ($c.IsDir) { $c.Path } else { [IO.Path]::GetDirectoryName($c.Path) })
    }
}

# Runs one catalog item's program with its (possibly user-edited) command template.
function Invoke-ItemCommand([string]$Id, [string]$Tool, $c, [hashtable]$Vars = @{}) {
    $entry = $Catalog | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    $all = Get-BaseVars $c
    foreach ($k in $Vars.Keys) { $all[$k] = $Vars[$k] }
    $null = Invoke-Tool $Tool -ArgLine (Expand-CommandTemplate (Get-EntryCommand $entry) $all)
}

# The program a menu item needs: a known tool, or the exe of a custom item. $null when missing.
function Resolve-EntryExe($Entry) {
    if ($Entry.Program) {
        $p = Expand-PathValue $Entry.Program
        if ($p -and [IO.File]::Exists($p)) { return $p }
        return $null
    }
    if ($Entry.Tool) { return Resolve-Tool $Entry.Tool -Optional }
    return $null
}

function Test-FileSignature([string]$File, $Signature) {
    $want = [byte[]]@(($Signature.Hex -split '(..)' | Where-Object { $_ }) | ForEach-Object { [Convert]::ToByte($_, 16) })
    $ok = $false
    $fs = [IO.File]::Open($File, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -ge $Signature.Offset + $want.Length) {
            $fs.Position = $Signature.Offset
            $buf = New-Object byte[] $want.Length
            $ok = ($fs.Read($buf, 0, $buf.Length) -eq $want.Length) -and ([BitConverter]::ToString($buf) -eq [BitConverter]::ToString($want))
        }
    } finally { $fs.Dispose() }
    if (-not $ok) { throw ("This file does not have the expected signature ({0} at offset {1})." -f $Signature.Hex, $Signature.Offset) }
}

function Invoke-CustomItem($c) {
    $e = $c.Entry
    $exe = Resolve-EntryExe $e
    if (-not $exe) { throw "Program not found: $($e.Program). Fix it in Settings > Menu items." }
    if ($e.Signature -and -not $c.IsDir) { Test-FileSignature $c.Path $e.Signature }
    $line = Expand-CommandTemplate $e.Command (Get-BaseVars $c)
    if ($e.Wait) {
        $null = Invoke-Tool $e.Title -Exe $exe -ArgLine $line
    } else {
        Write-Log "START `"$exe`" $line"
        if ($line) { Start-Process -FilePath $exe -ArgumentList $line } else { Start-Process -FilePath $exe }
    }
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

    # EvidenceFolder: straight into the folder of the evidence (or the folder clicked), no subfolder.
    if ($script:Config.OutputMode -eq 'EvidenceFolder') {
        $dir = if ([IO.Directory]::Exists($EvidencePath)) { $EvidencePath } else { [IO.Path]::GetDirectoryName($trimmed) }
        if ($dir -and (Test-Writable $dir)) { return $dir }
        Write-Warn "Cannot write to $dir - using the output folder instead."
    }

    $bases = @()
    if ($script:Config.OutputMode -notin 'OutputRoot', 'EvidenceFolder') {
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

# The folder exists already, so creating it proves nothing - write and delete a probe file.
function Test-Writable([string]$Dir) {
    try {
        $probe = Join-Path $Dir ('.forensicaid_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
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
# With OutputMode EvidenceFolder they sit among the evidence, so the working copies are told apart by name.
function Test-OwnOutput([string]$FullName) {
    return $FullName -like '*\ForensicAid\*' -or $FullName -like '*\_db_copy\*' -or $FullName -like '*\_temp\*'
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

    $a = @()
    $useSigma = $set.Sigma -and [IO.Directory]::Exists($set.Sigma)
    if ($useSigma) {
        if (-not [IO.File]::Exists($set.Mapping)) { throw "Sigma rules need a mapping file. Not found: $($set.Mapping) (set Chainsaw.Mapping in the config)." }
        $a += @('-s', $set.Sigma, '-m', $set.Mapping)
    }
    if ($set.Rules -and [IO.Directory]::Exists($set.Rules)) { $a += @('-r', $set.Rules) }
    if ($a.Count -eq 0) { throw 'No Chainsaw or Sigma rules found. Set Chainsaw.SigmaRules / Chainsaw.Rules in the config.' }
    if (-not $useSigma) { Write-Warn 'No Sigma rules configured - hunting with built-in Chainsaw rules only.' }

    Invoke-ItemCommand chainsaw Chainsaw $c @{ RuleArgs = $a; ExtraArgs = @($script:Config.Chainsaw.ExtraArgs) }
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
    Invoke-ItemCommand mft MFTECmd $c @{ MftArg = $extra }
}

function Invoke-RECmd($c) {
    $exe = Resolve-Tool RECmd
    $batch = Get-RECmdBatch $exe
    if (-not $batch -or -not [IO.File]::Exists($batch)) { throw 'No RECmd batch file found. Set RECmdBatch in the config (e.g. ...\RECmd\BatchExamples\Kroll_Batch.reb).' }
    Write-Info "Batch: $batch"
    if (-not $c.IsDir) {
        Invoke-ItemCommand registry RECmd $c @{ Batch = $batch; HiveArgs = @(Get-HiveArgs $c.Path) }
        return
    }

    # -d mode fails (or silently skips) dirty hives without logs; parse those one by one with --nl.
    $nl = Find-HivesNeedingNl $c.Path
    Invoke-ItemCommand registry RECmd $c @{ Batch = $batch; HiveArgs = @() }
    $i = 0
    foreach ($h in $nl) {
        $i++
        Write-Warn "Dirty hive without .LOG1/.LOG2, parsing separately with --nl: $h"
        $sub = @{ Path = $h; IsDir = $false; Out = (Join-Path $c.Out ('nl_{0:D2}_{1}' -f $i, (Get-SafeName ([IO.Path]::GetFileName($h))))) }
        [void][IO.Directory]::CreateDirectory($sub.Out)
        Invoke-ItemCommand registry RECmd $sub @{ Batch = $batch; HiveArgs = @('--nl') }
    }
}

function Invoke-SBECmd($c) {
    $nl = Find-HivesNeedingNl $c.Path
    if ($nl.Count) {
        Write-Warn "SBECmd may skip these dirty hives that have no .LOG1/.LOG2 files:`n    $($nl -join "`n    ")"
    }
    Invoke-ItemCommand shellbags SBECmd $c
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
    Invoke-ItemCommand srum SrumECmd $c @{
        Db          = (Join-Path $work ([IO.Path]::GetFileName($db)))
        TempArgs    = @(Get-EzTempArgs SrumECmd $c)
        SoftwareArg = $(if ($software) { @('-r', $software) } else { @() })
    }
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
    Invoke-ItemCommand ual SumECmd $c @{ Db = $work; TempArgs = @(Get-EzTempArgs SumECmd $c) }
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
    Invoke-ItemCommand activities WxTCmd $c @{ Db = (Join-Path $work ([IO.Path]::GetFileName($c.Path))); TempArgs = @(Get-EzTempArgs WxTCmd $c) }
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
    Invoke-ItemCommand to-raw QemuImg $c @{ Format = [string]$info.format; Dest = $dst }
    if ([IO.File]::Exists($dst)) { Write-Ok "RAW image: $dst" }
}

# RDP bitmap cache of mstsc: CacheNNNN.bin (RDP 8+: "RDP8bmp" + version, then tiles of 8-byte key,
# UInt16 width, UInt16 height, width*height*4 bytes BGRA top-down) and the older bcache*.bmc (20-byte
# tile header: keys, width, height, length, flags; bottom-up, 16/24/32 bpp; RLE-compressed tiles are
# counted but not decoded). Every tile is saved as PNG, plus a collage per cache file for quick review.
# With -BmpDir the tiles are also written as BMP, one folder per cache file - the only input
# RdpCacheStitcher reads (*.bmp, same size, alphabetical order = order in the cache file).
function Export-RdpCacheFile([string]$File, [string]$OutDir, [string]$BmpDir) {
    Add-Type -AssemblyName System.Drawing
    $data = [IO.File]::ReadAllBytes($File)   # mstsc keeps each cache file around 100 MB at most
    $name = Get-SafeName ([IO.Path]::GetFileName($File))
    $isBin = $data.Length -ge 12 -and [Text.Encoding]::ASCII.GetString($data, 0, 7) -eq 'RDP8bmp'
    $isBmc = [IO.Path]::GetExtension($File) -ieq '.bmc'
    $result = [pscustomobject]@{ File = $File; Format = $(if ($isBin) { 'RDP8 .bin' } elseif ($isBmc) { 'bmc' } else { 'unknown' }); Tiles = 0; Skipped = 0; Collage = ''; BmpDir = '' }
    if (-not ($isBin -or $isBmc)) { return $result }

    $tileDir = Join-Path $OutDir $name
    [void][IO.Directory]::CreateDirectory($tileDir)
    if ($BmpDir) {
        $result.BmpDir = Join-Path $BmpDir $name
        [void][IO.Directory]::CreateDirectory($result.BmpDir)
    }
    $bitmaps = [System.Collections.Generic.List[object]]::new()
    $pos = if ($isBin) { 12 } else { 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ($isBin) {
            if ($pos + 12 -gt $data.Length) { break }
            $w = [BitConverter]::ToUInt16($data, $pos + 8); $h = [BitConverter]::ToUInt16($data, $pos + 10)
            $bpp = 4; $len = $w * $h * 4; $start = $pos + 12; $compressed = $false; $bottomUp = $false
        } else {
            if ($pos + 20 -gt $data.Length) { break }
            $w = [BitConverter]::ToUInt16($data, $pos + 8); $h = [BitConverter]::ToUInt16($data, $pos + 10)
            $len = [BitConverter]::ToUInt32($data, $pos + 12); $flags = [BitConverter]::ToUInt32($data, $pos + 16)
            $start = $pos + 20; $compressed = ($flags -band 0x08) -ne 0; $bottomUp = $true
            $bpp = if ($w * $h) { $len / ($w * $h) } else { 0 }
        }
        if ($w -eq 0 -or $h -eq 0 -or $w -gt 256 -or $h -gt 256 -or $start + $len -gt $data.Length) { break }
        $pos = $start + $len

        $format = switch ($bpp) { 4 { 'Format32bppRgb' } 3 { 'Format24bppRgb' } 2 { 'Format16bppRgb565' } default { $null } }
        if ($compressed -or -not $format) { $result.Skipped++; continue }

        $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::$format)
        $bd = $bmp.LockBits((New-Object System.Drawing.Rectangle(0, 0, $w, $h)), 'WriteOnly', $bmp.PixelFormat)
        $row = $w * $bpp
        if (-not $bottomUp -and $bd.Stride -eq $row) {
            [Runtime.InteropServices.Marshal]::Copy($data, $start, $bd.Scan0, $len)
        } else {
            for ($y = 0; $y -lt $h; $y++) {
                $src = if ($bottomUp) { $h - 1 - $y } else { $y }
                [Runtime.InteropServices.Marshal]::Copy($data, $start + $src * $row, [IntPtr]($bd.Scan0.ToInt64() + $y * $bd.Stride), $row)
            }
        }
        $bmp.UnlockBits($bd)
        $bmp.Save((Join-Path $tileDir ('{0}_{1:D5}.png' -f $name, $bitmaps.Count)), [System.Drawing.Imaging.ImageFormat]::Png)
        if ($BmpDir) { $bmp.Save((Join-Path $result.BmpDir ('{0}_{1:D5}.bmp' -f $name, $bitmaps.Count)), [System.Drawing.Imaging.ImageFormat]::Bmp) }
        $bitmaps.Add($bmp)
        if ($sw.ElapsedMilliseconds -gt 500) {
            Write-Progress -Activity "RDP cache $name" -Status "$($bitmaps.Count) tiles" -PercentComplete ([int](100 * $pos / $data.Length))
            $sw.Restart()
        }
    }
    Write-Progress -Activity "RDP cache $name" -Completed
    $result.Tiles = $bitmaps.Count

    # Collage in file order (64 tiles per row): neighbouring tiles often belong to the same screen.
    if ($bitmaps.Count) {
        $cols = [Math]::Min(64, $bitmaps.Count)
        $rows = [Math]::Ceiling($bitmaps.Count / $cols)
        $collage = New-Object System.Drawing.Bitmap(($cols * 64), ([int]$rows * 64))
        $g = [System.Drawing.Graphics]::FromImage($collage)
        $g.Clear([System.Drawing.Color]::Black)
        for ($i = 0; $i -lt $bitmaps.Count; $i++) { $g.DrawImageUnscaled($bitmaps[$i], ($i % $cols) * 64, [Math]::Floor($i / $cols) * 64) }
        $g.Dispose()
        $result.Collage = Join-Path $OutDir "$name`_collage.png"
        $collage.Save($result.Collage, [System.Drawing.Imaging.ImageFormat]::Png)
        $collage.Dispose()
    }
    foreach ($b in $bitmaps) { $b.Dispose() }
    return $result
}

function Invoke-RdpCache($c) {
    $files = if ($c.IsDir) {
        @(Get-ChildItem -LiteralPath $c.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
          Where-Object { ($_.Name -like 'Cache*.bin' -or $_.Extension -ieq '.bmc') -and $_.Length -gt 0 -and -not (Test-OwnOutput $_.FullName) } |
          ForEach-Object { $_.FullName })
    } else { @($c.Path) }
    if (-not $files.Count) { throw "No RDP bitmap cache files (Cache*.bin, bcache*.bmc) under $($c.Path)" }

    # BMP copies only when RdpCacheStitcher is there to use them (they double the disk usage).
    $rcs = Resolve-Tool RdpCacheStitcher -Optional
    $bmpRoot = if ($rcs) { Join-Path $c.Out 'for_RdpCacheStitcher' } else { '' }
    $results = foreach ($f in $files) {
        Write-Info "Parsing $f"
        $r = Export-RdpCacheFile $f $c.Out $bmpRoot
        if ($r.Format -eq 'unknown') { Write-Warn "Not an RDP bitmap cache: $f" }
        else { Write-Ok ("{0}: {1} tiles{2}" -f [IO.Path]::GetFileName($f), $r.Tiles, $(if ($r.Skipped) { ", $($r.Skipped) compressed/unsupported skipped" } else { '' })) }
        Write-Log ("RDPCACHE `"{0}`" format={1} tiles={2} skipped={3}" -f $f, $r.Format, $r.Tiles, $r.Skipped)
        $r
    }
    $results | Export-Csv -LiteralPath (Join-Path $c.Out 'rdpcache_summary.csv') -NoTypeInformation -Encoding UTF8
    $withTiles = @($results | Where-Object { $_.Tiles -gt 0 })
    if (-not $withTiles.Count) { $script:ToolFailures++; Write-Warn 'No tiles extracted.'; return }
    if (-not $rcs) { Write-Info 'Install RdpCacheStitcher (github.com/bsi-bund/RdpCacheStitcher) to rebuild whole screens from these tiles.'; return }
    if (-not $c.InTriage -and (Read-Host '  Open the tiles in RdpCacheStitcher now? [y/N]') -match '^[yYtT]') {
        Open-RdpCacheStitcher @($withTiles | ForEach-Object { $_.BmpDir })
    }
}

# Folders under $Root that hold BMP tiles (the folder itself, or for_RdpCacheStitcher\* in results).
function Find-RdpTileFolders([string]$Root) {
    $hasBmp = { param($d) [bool](Get-ChildItem -LiteralPath $d -Filter '*.bmp' -File -ErrorAction SilentlyContinue | Select-Object -First 1) }
    if (& $hasBmp $Root) { return @($Root) }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
             Where-Object { & $hasBmp $_.FullName } | ForEach-Object { $_.FullName })
}

# RdpCacheStitcher takes no command-line arguments (checked in its source), so start it, put the
# tile folder on the clipboard and say where to paste it.
function Open-RdpCacheStitcher([string[]]$Folders) {
    $exe = Resolve-Tool RdpCacheStitcher
    $Folders = @($Folders | Where-Object { $_ })
    if (-not $Folders.Count) { throw 'No BMP tile folders. Run "RDP bitmap cache" on the cache files first.' }
    $folder = $Folders[0]
    if ($Folders.Count -gt 1) {
        Write-Host '  Tile folders (one case each):'
        for ($i = 0; $i -lt $Folders.Count; $i++) {
            $n = @(Get-ChildItem -LiteralPath $Folders[$i] -Filter '*.bmp' -File).Count
            Write-Host ('    [{0}] {1}  ({2} tiles)' -f ($i + 1), $Folders[$i], $n)
        }
        $answer = Read-Host ("  Which one? [1-{0}, Enter = 1]" -f $Folders.Count)
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Folders.Count) { $folder = $Folders[[int]$answer - 1] }
    }

    # RdpCacheStitcher needs the Visual C++ 2015-2022 runtime (x64).
    $vc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64' -ErrorAction SilentlyContinue
    if (-not ($vc -and $vc.Installed -eq 1)) {
        Write-Warn 'RdpCacheStitcher needs the Microsoft Visual C++ Redistributable (x64): https://aka.ms/vs/17/release/vc_redist.x64.exe'
    }

    try { Set-Clipboard -Value $folder } catch { }
    Start-Process -FilePath $exe -WorkingDirectory ([IO.Path]::GetDirectoryName($exe))
    Write-Log "RDPSTITCH `"$exe`" folder=$folder"
    Write-Host ''
    Write-Ok 'RdpCacheStitcher started. The tile folder is on the clipboard:'
    Write-Host "      $folder"
    Write-Host '  In RdpCacheStitcher: File > New case, paste the folder (Ctrl+V) into the folder box, then "Select Folder".'
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
    if ($exts['.bmc'] -or @($byName.Keys | Where-Object { $_ -like 'cache000?.bin' } | Select-Object -First 1).Count) { & $addDir 'rdpcache' }

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
        $sub = @{ Action = $s.Id; Path = $s.Path; IsDir = $s.IsDir; Out = (Join-Path $c.Out ('{0:D2}_{1}' -f $i, $s.Id)); InTriage = $true }
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

#region Tool scan

# Folders where the tools probably are, cheapest first: folders seen in this user's execution history
# (Program Compatibility Assistant store and MuiCache - both readable without admin; Prefetch and BAM
# need admin and are not used) plus one or two levels up (the whole tool suite), the usual user
# folders, ToolRoots, common install folders and top-level folders named like a tool collection.
# -Deep scans whole fixed drives instead (minutes on large disks).
function Get-ToolScanRoots([switch]$Deep) {
    if ($env:FORENSICAID_SCANROOTS) { return @($env:FORENSICAID_SCANROOTS -split ';' | Where-Object { $_ }) }   # tests
    $roots = [System.Collections.Generic.List[string]]::new()
    $fixed = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })
    if ($Deep) { foreach ($d in $fixed) { $roots.Add($d.RootDirectory.FullName) }; return $roots }

    $exeNames = @($ToolFiles.Values | ForEach-Object { $_ } | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $stop = @($env:USERPROFILE, $env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) | Where-Object { $_ }
    foreach ($k in 'Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store',
                   'Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache') {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($k)
        if (-not $key) { continue }
        foreach ($v in $key.GetValueNames()) {
            if ($v -notmatch "(?i)^([A-Z]:\\.+?)\\($exeNames)") { continue }
            $dir = $Matches[1]
            for ($i = 0; $i -lt 3 -and $dir -and $dir.Length -gt 3 -and $stop -notcontains $dir; $i++) {
                $roots.Add($dir)
                $dir = [IO.Path]::GetDirectoryName($dir)
            }
        }
        $key.Close()
    }

    foreach ($f in 'Desktop', 'MyDocuments') { $roots.Add([Environment]::GetFolderPath($f)) }
    $roots.Add((Join-Path $env:USERPROFILE 'Downloads'))
    foreach ($r in @($script:Config.ToolRoots)) { $roots.Add((Expand-PathValue $r)) }
    $roots.Add((Join-Path $env:ProgramFiles 'qemu'))
    $roots.Add((Join-Path $env:ProgramData 'chocolatey\bin'))
    $roots.Add((Join-Path $env:USERPROFILE 'scoop'))
    foreach ($d in $fixed) {
        Get-ChildItem -LiteralPath $d.RootDirectory.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)tool|forensic|dfir|zimmerman|^ez|kape|chainsaw|^ir$|incident|triage' } |
            ForEach-Object { $roots.Add($_.FullName) }
    }

    # Existing folders only, and no folder that sits inside another one on the list.
    $unique = @{}   # case-insensitive keys; Sort-Object -Unique would also drop different paths of equal length
    foreach ($r in $roots) { if ($r -and [IO.Directory]::Exists($r)) { $unique[[IO.Path]::GetFullPath($r).TrimEnd('\')] = $true } }
    $kept = @()
    foreach ($r in ($unique.Keys | Sort-Object Length)) {
        if (-not ($kept | Where-Object { $r.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase) -or $r -ieq $_ })) { $kept += $r }
    }
    return $kept
}

function Find-ToolCandidates([string[]]$Roots) {
    $wanted = @{}
    foreach ($tool in $ToolFiles.Keys) { foreach ($f in $ToolFiles[$tool]) { $wanted[$f.ToLowerInvariant()] = $tool } }
    $names = @($wanted.Keys)
    $skip = @($env:TEMP, $InstallDir) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') + '\' }

    $found = @{}
    foreach ($root in $Roots) {
        Write-Host "    $root" -ForegroundColor DarkGray
        $ErrorActionPreference = 'Continue'
        $hits = & where.exe /r $root @names 2>$null
        $ErrorActionPreference = 'Stop'
        foreach ($h in @($hits)) {
            if (-not $h -or (Test-OwnOutput $h) -or $h -like '*\$Recycle.Bin\*') { continue }
            if ($skip | Where-Object { $h.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) { continue }
            $tool = $wanted[[IO.Path]::GetFileName($h).ToLowerInvariant()]
            if (-not $tool) { continue }
            if (-not $found.ContainsKey($tool)) { $found[$tool] = [System.Collections.Generic.List[string]]::new() }
            if (-not $found[$tool].Contains($h)) { $found[$tool].Add($h) }
        }
    }
    return $found
}

function Get-ToolVersion([string]$Tool, [string]$Exe) {
    if ($Tool -eq 'Chainsaw') { return Get-ChainsawVersion $Exe }
    return Get-FileVersionSafe (Get-Item -LiteralPath $Exe)
}

function Set-ConfigTools([hashtable]$Paths) { Set-ConfigValues @{ Tools = $Paths } }

# A literal value as the config holds it: 'text', $true, 42 or an @( ... ) list (possibly over several lines).
$ConfigValuePattern = '(?:''(?:[^'']|'''')*''|"[^"]*"|\$\w+|@\((?:[^()''"]|''(?:[^'']|'''')*''|"[^"]*")*\)|[\w.]+)'
$ConfigSections = @{ Tools = @($ToolFiles.Keys); Chainsaw = @('SigmaRules', 'Mapping', 'Rules', 'ExtraArgs') }

function ConvertTo-ConfigLiteral($Value) {
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [array]) { return '@(' + ((@($Value) | ForEach-Object { ConvertTo-ConfigLiteral $_ }) -join ', ') + ')' }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

# Where a 'Name = @{ ... }' section sits: Body = just after '@{', End = its closing '}'.
# Sections hold only quoted strings and @() lists, so the first '}' outside quotes and comments closes them.
function Get-ConfigSection([string]$Text, [string]$Name) {
    $m = [regex]::Match($Text, "(?m)^[ \t]*$Name[ \t]*=[ \t]*@\{")
    if (-not $m.Success) { return $null }
    $quote = $null
    for ($i = $m.Index + $m.Length; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($quote) { if ($ch -eq $quote) { $quote = $null }; continue }
        if ($ch -eq "'" -or $ch -eq '"') { $quote = $ch; continue }
        if ($ch -eq '#') { $i = $Text.IndexOf("`n", $i); if ($i -lt 0) { break }; continue }
        if ($ch -eq '}') { return @{ Start = $m.Index; Body = $m.Index + $m.Length; End = $i } }
    }
    return $null
}

# Replaces the value of Key between Start and End (skipping the spans in $Skip); $null when the key is not there.
function Set-ConfigKey([string]$Text, [int]$Start, [int]$End, [string]$Key, [string]$Literal, [object[]]$Skip = @()) {
    $re = New-Object regex ("(?m)^([ \t]*$Key[ \t]*=[ \t]*)$ConfigValuePattern")
    foreach ($m in $re.Matches($Text.Substring(0, $End), $Start)) {
        $at = $m.Index
        if (@($Skip | Where-Object { $at -ge $_.Start -and $at -le $_.End }).Count) { continue }
        $prefix = $m.Groups[1].Value
        return $Text.Substring(0, $at) + $prefix + $Literal + $Text.Substring($at + $m.Length)
    }
    return $null
}

# Writes settings into the user's config in place, keeping every comment and every setting not given.
# $Values: top-level keys of $Defaults; Tools and Chainsaw take a hashtable of their own keys.
function Set-ConfigValues([hashtable]$Values) {
    if (-not [IO.File]::Exists($ConfigFile)) {
        [void][IO.Directory]::CreateDirectory($InstallDir)
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ForensicAid.config.psd1') -Destination $ConfigFile
    }
    $text = [IO.File]::ReadAllText($ConfigFile)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $last = $text.LastIndexOf('}')
    if ($last -lt 0) { throw "$ConfigFile does not look like a PowerShell data file - fix it by hand." }

    foreach ($key in $Values.Keys) {
        if (-not $Defaults.ContainsKey($key)) { throw "Unknown setting '$key'." }
        if ($ConfigSections.ContainsKey($key)) {
            $sub = $Values[$key]
            if ($sub -isnot [hashtable]) { throw "Setting '$key' takes a list of named values." }
            if (-not (Get-ConfigSection $text $key)) {
                # A trimmed-down config without this section: add an empty one before the closing brace.
                $text = $text.Insert($text.LastIndexOf('}'), "    $key = @{$nl    }$nl")
            }
            foreach ($name in $sub.Keys) {
                if ($ConfigSections[$key] -notcontains $name) { throw "Unknown setting '$key.$name'." }
                $sec = Get-ConfigSection $text $key
                $literal = ConvertTo-ConfigLiteral $sub[$name]
                $new = Set-ConfigKey $text $sec.Body $sec.End $name $literal
                if ($null -eq $new) { $new = $text.Insert($sec.Body, "$nl        $name = $literal") }
                $text = $new
            }
        } else {
            $skip = @($ConfigSections.Keys | ForEach-Object { Get-ConfigSection $text $_ } | Where-Object { $_ })
            $literal = ConvertTo-ConfigLiteral $Values[$key]
            $new = Set-ConfigKey $text 0 $text.Length $key $literal $skip
            if ($null -eq $new) { $new = $text.Insert($text.LastIndexOf('}'), "    $key = $literal$nl") }
            $text = $new
        }
    }
    # Validate before replacing the user's file; keep the previous version next to it.
    $tmp = "$ConfigFile.new"
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($true)))   # BOM: PS 5.1 reads BOM-less files as ANSI
    try { $null = Import-PowerShellDataFile -LiteralPath $tmp } catch { Remove-Item -LiteralPath $tmp; throw "Updated config would be invalid, not saved: $($_.Exception.Message)" }
    Copy-Item -LiteralPath $ConfigFile -Destination "$ConfigFile.bak" -Force
    Move-Item -LiteralPath $tmp -Destination $ConfigFile -Force
}

function Invoke-ScanTools([switch]$Deep, [switch]$NoRegister) {
    if (-not $script:Config) { $script:Config = Import-Config }
    $roots = @(Get-ToolScanRoots -Deep:$Deep)
    Write-Info ("Scanning {0} folder(s) for tools{1} ..." -f $roots.Count, $(if ($Deep) { ' (all fixed drives - this can take minutes)' } else { '' }))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $found = Find-ToolCandidates $roots
    Write-Info ("Scan finished in {0:n0}s." -f $sw.Elapsed.TotalSeconds)
    Write-Host ''

    # Candidates per tool, newest first.
    $plan = [ordered]@{}
    foreach ($tool in $ToolFiles.Keys) {
        $current = Resolve-Tool $tool -Optional
        $paths = @(@($found[$tool]) + @($current) | Where-Object { $_ -and [IO.File]::Exists($_) } | Sort-Object -Unique)
        $cands = @($paths | ForEach-Object { [pscustomobject]@{ Path = $_; Version = (Get-ToolVersion $tool $_) } } |
                   Sort-Object @{ Expression = 'Version'; Descending = $true }, @{ Expression = { $_.Path -ine $current } })
        $plan[$tool] = @{
            Cands      = $cands
            Configured = Expand-PathValue $script:Config.Tools[$tool]
            Current    = $current
            Conflict   = @($cands | ForEach-Object { $_.Version } | Sort-Object -Unique).Count -gt 1
        }
    }

    # Different versions of the same tool: ask once how to resolve them, not once per tool.
    # newest = take the newest everywhere; keep = leave tools already set in the config alone; choose = ask per tool.
    $conflicts = @($plan.Keys | Where-Object { $plan[$_].Conflict })
    $mode = 'keep'
    if ($conflicts.Count -and -not $Yes) {
        Write-Info ("Different versions found for {0} tool(s): {1}" -f $conflicts.Count, ($conflicts -join ', '))
        $answer = Read-Host '  Use the newest for all (Enter), choose for each tool (c), or keep what the config already uses (k)?'
        $mode = if ($answer -match '^[cC]') { 'choose' } elseif ($answer -match '^[kK]') { 'keep' } else { 'newest' }
        Write-Host ''
    }

    $changes = @{}
    foreach ($tool in $plan.Keys) {
        $p = $plan[$tool]
        $cands = $p.Cands
        $configured = $p.Configured
        if (-not $cands.Count) { Write-Host ('  [-] {0,-22}not found' -f $tool) -ForegroundColor DarkYellow; continue }

        $pick = $cands[0]
        $inConfig = $cands | Where-Object { $_.Path -ieq $configured } | Select-Object -First 1
        if ($p.Conflict -and $mode -eq 'keep' -and $inConfig) { $pick = $inConfig }
        if ($p.Conflict -and $mode -eq 'choose') {
            Write-Host ("  [?] {0} - different versions found:" -f $tool) -ForegroundColor Yellow
            for ($i = 0; $i -lt $cands.Count; $i++) {
                Write-Host ('      [{0}] {1,-14} {2}{3}' -f ($i + 1), $cands[$i].Version, $cands[$i].Path, $(if ($cands[$i].Path -ieq $p.Current) { '  (in use)' } else { '' }))
            }
            $answer = Read-Host ("      Use which? [1-{0}, Enter = 1 (newest), s = skip]" -f $cands.Count)
            if ($answer -match '^[sS]') { continue }
            if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $cands.Count) { $pick = $cands[[int]$answer - 1] }
        }
        $note = if ($cands.Count -gt 1) { " ($($cands.Count) copies)" } else { '' }
        if ($pick.Path -ieq $configured) {
            Write-Host ('  [=] {0,-22}{1}  v{2}{3}' -f $tool, $pick.Path, $pick.Version, $note) -ForegroundColor Green
        } else {
            $changes[$tool] = $pick.Path
            Write-Host ('  [+] {0,-22}{1}  v{2}{3}' -f $tool, $pick.Path, $pick.Version, $note) -ForegroundColor Green
        }
    }

    Write-Host ''
    if ($changes.Count) {
        Set-ConfigTools $changes
        Write-Ok "Linked $($changes.Count) tool(s) in $ConfigFile (previous version: ForensicAid.config.psd1.bak)."
        $script:Config = Import-Config
        $script:ToolCache = $null
        $null = Update-ToolCache
        if (-not $NoRegister) { Register-Menu }
    } else {
        Write-Ok 'Config already points at the tools found - nothing to change.'
    }
    if (-not $Deep) { Write-Info 'Tools somewhere else? Run a full scan: ForensicAid.ps1 -ScanTools -Deep' }
}

#endregion

function Show-Doctor {
    Write-Host "Version : $Version"
    Write-Host "Config  : $ConfigFile"
    Write-Host "Roots   : $((@($script:Config.ToolRoots) | ForEach-Object { Expand-PathValue $_ }) -join '; ')"
    Write-Host "Output  : $($script:Config.OutputMode) (fallback: $(Expand-PathValue $script:Config.OutputRoot))"
    Show-ToolTable
    $custom = @($Catalog | Where-Object { $_.Custom })
    if ($custom.Count -or $script:ActionErrors.Count) {
        Write-Host ''
        Write-Host 'Custom items' -ForegroundColor White
        foreach ($e in $custom) {
            $exe = Resolve-EntryExe $e
            if ($exe) { Write-Host ('  [+] {0,-22}{1}' -f $e.Id, $exe) -ForegroundColor Green }
            else      { Write-Host ('  [-] {0,-22}program not found: {1}' -f $e.Id, $e.Program) -ForegroundColor DarkYellow }
        }
        foreach ($err in $script:ActionErrors) { Write-Host "  [x] $err" -ForegroundColor Red }
    }
    Write-Host ''
    Write-Info 'Missing tools: drop them under one of the roots or set the path in Settings, then use "Refresh menu".'
    Write-MenuHint
}

#endregion

#region Catalog

# File filter for an item: shown when the name has one of Ext, equals one of Name or starts with a Prefix,
# and is not in Exclude (all case-insensitive). Feeds both AppliesTo (classic menu) and menu.json (Windows 11).
function FileMatch([string[]]$Ext = @(), [string[]]$Name = @(), [string[]]$Prefix = @(), [string[]]$Exclude = @()) {
    return @{ Ext = $Ext; Name = $Name; Prefix = $Prefix; Exclude = $Exclude }
}

function ConvertTo-Aqs($Match) {
    $p = @()
    foreach ($e in $Match.Ext)    { $p += 'System.FileExtension:="{0}"' -f $e }
    foreach ($n in $Match.Name)   { $p += 'System.FileName:="{0}"' -f $n }
    foreach ($x in $Match.Prefix) { $p += 'System.FileName:~<"{0}"' -f $x }
    $aqs = $p -join ' OR '
    if (@($Match.Exclude).Count) {
        $aqs = '({0}) AND {1}' -f $aqs, ((@($Match.Exclude) | ForEach-Object { 'System.FileName:<>"{0}"' -f $_ }) -join ' AND ')
    }
    return $aqs
}

# Menu order follows this list; a separator is drawn where Group changes.
# Scope: File = right-click on a file, Dir = folder, drive or folder background.
# Match: AQS filter so file items only show for matching files.
$HiveVar = @{ HiveArgs = '--nl when the hive is dirty and has no .LOG1/.LOG2 next to it, else nothing' }
$TempVar = @{ TempArgs = '--temp <results>\_temp for EZ tools from 2026.10 (they copy databases next to their exe), else nothing' }
$Catalog = @(
    @{ Id = 'hash'; Title = 'Hash (MD5/SHA1/SHA256)'; Group = 1; Scope = 'File', 'Dir'; NoOutput = $true
       Run = { param($c) Invoke-Hash $c } }
    @{ Id = 'timeline'; Title = 'Open in Timeline Explorer'; Group = 1; Scope = 'File'; Tool = 'TimelineExplorer'
       Match = (FileMatch -Ext '.csv', '.xlsx', '.tle_sess'); NoOutput = $true; Hidden = $true; NoPause = $true
       Command = '{Path}'
       Run = { param($c) Start-Process -FilePath (Resolve-Tool TimelineExplorer) -ArgumentList (Expand-CommandTemplate (Get-EntryCommand $c.Entry) (Get-BaseVars $c)) } }
    @{ Id = 'triage'; Title = 'Full triage (all parsers)'; Group = 1; Scope = 'Dir'
       Run = { param($c) Invoke-Triage $c } }

    @{ Id = 'chainsaw'; Title = 'Event logs - Chainsaw hunt'; Group = 2; Scope = 'File', 'Dir'; Tool = 'Chainsaw'
       Match = (FileMatch -Ext '.evtx'); Command = 'hunt {Path} {RuleArgs} --csv -o "{Out}\chainsaw" {ExtraArgs}'
       Vars = @{ RuleArgs = '-s <Sigma rules> -m <mapping> and/or -r <Chainsaw rules>, from Settings > General'
                 ExtraArgs = 'Chainsaw.ExtraArgs from the config file (default --skip-errors)' }
       Run = { param($c) Invoke-Chainsaw $c } }
    @{ Id = 'evtx'; Title = 'Event logs - EvtxECmd'; Group = 2; Scope = 'File', 'Dir'; Tool = 'EvtxECmd'
       Match = (FileMatch -Ext '.evtx'); Command = '{In} --csv {Out}'; Run = { param($c) Invoke-ItemCommand evtx EvtxECmd $c } }

    @{ Id = 'mft'; Title = 'NTFS ($MFT/$J/$Boot/$SDS) - MFTECmd'; Group = 3; Scope = 'File'; Tool = 'MFTECmd'
       Match = (FileMatch -Name '$MFT', '$J', '$LogFile', '$Boot', '$SDS', '$Secure_$SDS', '$I30' -Prefix '$UsnJrnl')
       Command = '{In} --csv {Out} {MftArg}'; Vars = @{ MftArg = '-m <$MFT next to it> for $J / $LogFile, to resolve parent paths' }
       Run = { param($c) Invoke-Mft $c } }
    @{ Id = 'prefetch'; Title = 'Prefetch - PECmd'; Group = 3; Scope = 'File', 'Dir'; Tool = 'PECmd'
       Match = (FileMatch -Ext '.pf'); Command = '{In} --csv {Out} -q'; Run = { param($c) Invoke-ItemCommand prefetch PECmd $c } }
    @{ Id = 'lnk'; Title = 'LNK files - LECmd'; Group = 3; Scope = 'File', 'Dir'; Tool = 'LECmd'
       Match = (FileMatch -Ext '.lnk'); Command = '{In} --csv {Out} -q'; Run = { param($c) Invoke-ItemCommand lnk LECmd $c } }
    @{ Id = 'jumplist'; Title = 'Jump lists - JLECmd'; Group = 3; Scope = 'File', 'Dir'; Tool = 'JLECmd'
       Match = (FileMatch -Ext '.automaticDestinations-ms', '.customDestinations-ms'); Command = '{In} --csv {Out} -q'
       Run = { param($c) Invoke-ItemCommand jumplist JLECmd $c } }
    @{ Id = 'recyclebin'; Title = 'Recycle Bin ($I) - RBCmd'; Group = 3; Scope = 'File', 'Dir'; Tool = 'RBCmd'
       Match = (FileMatch -Prefix '$I' -Exclude '$I30'); Command = '{In} --csv {Out} -q'; Run = { param($c) Invoke-ItemCommand recyclebin RBCmd $c } }
    @{ Id = 'rdpcache'; Title = 'RDP bitmap cache (tiles + collage)'; Group = 3; Scope = 'File', 'Dir'
       Match = (FileMatch -Ext '.bmc' -Name 'Cache0000.bin', 'Cache0001.bin', 'Cache0002.bin', 'Cache0003.bin', 'Cache0004.bin')
       Run = { param($c) Invoke-RdpCache $c } }
    @{ Id = 'rdp-stitch'; Title = 'Open tiles in RdpCacheStitcher'; Group = 3; Scope = 'Dir'; Tool = 'RdpCacheStitcher'; NoOutput = $true
       Run = { param($c) Open-RdpCacheStitcher (Find-RdpTileFolders $c.Path) } }
    @{ Id = 'amcache'; Title = 'Amcache - AmcacheParser'; Group = 3; Scope = 'File'; Tool = 'AmcacheParser'
       Match = (FileMatch -Name 'Amcache.hve'); Command = '{In} --csv {Out} -i {HiveArgs} {TempArgs}'; Vars = $HiveVar + $TempVar
       Run = { param($c) Invoke-ItemCommand amcache AmcacheParser $c @{ HiveArgs = @(Get-HiveArgs $c.Path); TempArgs = @(Get-EzTempArgs AmcacheParser $c) } } }
    @{ Id = 'shimcache'; Title = 'ShimCache - AppCompatCacheParser'; Group = 3; Scope = 'File'; Tool = 'AppCompatCacheParser'
       Match = (FileMatch -Name 'SYSTEM'); Command = '{In} --csv {Out} {HiveArgs}'; Vars = $HiveVar
       Run = { param($c) Invoke-ItemCommand shimcache AppCompatCacheParser $c @{ HiveArgs = @(Get-HiveArgs $c.Path) } } }

    @{ Id = 'registry'; Title = 'Registry - RECmd (batch)'; Group = 4; Scope = 'File', 'Dir'; Tool = 'RECmd'
       Match = (FileMatch -Name 'NTUSER.DAT', 'UsrClass.dat', 'SYSTEM', 'SOFTWARE', 'SAM', 'SECURITY', 'DEFAULT', 'Amcache.hve')
       Command = '{In} --csv {Out} --bn {Batch} {HiveArgs}'
       Vars = @{ Batch = 'the RECmd batch file (Settings > General)'
                 HiveArgs = '--nl for a dirty hive without .LOG1/.LOG2 (folders: such hives get a separate run with --nl)' }
       Run = { param($c) Invoke-RECmd $c } }
    @{ Id = 'shellbags'; Title = 'ShellBags - SBECmd'; Group = 4; Scope = 'Dir'; Tool = 'SBECmd'
       Command = '{In} --csv {Out}'; Run = { param($c) Invoke-SBECmd $c } }

    @{ Id = 'srum'; Title = 'SRUM - SrumECmd'; Group = 5; Scope = 'File', 'Dir'; Tool = 'SrumECmd'
       Match = (FileMatch -Name 'SRUDB.dat'); Command = '-f {Db} --csv {Out} {TempArgs} {SoftwareArg}'
       Vars = @{ Db = 'the repaired copy of SRUDB.dat in <results>\_db_copy'; SoftwareArg = '-r <SOFTWARE hive> when one is found, else nothing' } + $TempVar
       Run = { param($c) Invoke-Srum $c } }
    @{ Id = 'ual'; Title = 'UAL (SUM) - SumECmd'; Group = 5; Scope = 'File', 'Dir'; Tool = 'SumECmd'
       Match = (FileMatch -Ext '.mdb'); Command = '-d {Db} --csv {Out} {TempArgs}'
       Vars = @{ Db = 'the folder with repaired copies of the *.mdb databases (<results>\_db_copy)' } + $TempVar
       Run = { param($c) Invoke-Sum $c } }
    @{ Id = 'activities'; Title = 'Windows Timeline - WxTCmd'; Group = 5; Scope = 'File'; Tool = 'WxTCmd'
       Match = (FileMatch -Name 'ActivitiesCache.db'); Command = '-f {Db} --csv {Out} {TempArgs}'
       Vars = @{ Db = 'a copy of ActivitiesCache.db (with -wal/-shm) in <results>\_db_copy' } + $TempVar
       Run = { param($c) Invoke-WxT $c } }
    @{ Id = 'ese-repair'; Title = 'Repair ESE database (copy)'; Group = 5; Scope = 'File'
       Match = (FileMatch -Ext '.edb', '.mdb' -Name 'SRUDB.dat' -Prefix 'WebCacheV'); Run = { param($c) Invoke-EseRepair $c } }

    @{ Id = 'to-raw'; Title = 'Disk image to RAW (.dd) - qemu-img'; Group = 6; Scope = 'File'; Tool = 'QemuImg'
       Match = (FileMatch -Ext '.vhdx', '.vhd', '.vmdk', '.qcow2', '.vdi'); Command = 'convert -p -f {Format} -O raw {Path} {Dest}'
       Vars = @{ Format = 'the image format qemu-img detected (vhdx, vmdk, ...)'; Dest = '<results>\<image name>.dd' }
       Run = { param($c) Invoke-ToRaw $c } }

    @{ Id = 'scan-tools'; Title = 'Find tools on this PC'; Group = 9; Scope = 'File', 'Dir'; NoOutput = $true; NoPath = $true
       Run = { param($c) Invoke-ScanTools } }
    @{ Id = 'doctor'; Title = 'Check tools'; Group = 9; Scope = 'File', 'Dir'; NoOutput = $true; NoPath = $true
       Run = { param($c) Show-Doctor } }
    @{ Id = 'config'; Title = 'Settings'; Group = 9; Scope = 'File', 'Dir'; NoOutput = $true; NoPath = $true; Hidden = $true; NoPause = $true
       Run = { param($c) Open-Config } }
    @{ Id = 'refresh'; Title = 'Refresh menu (after config change)'; Group = 9; Scope = 'File', 'Dir'; NoOutput = $true; NoPath = $true
       Run = { param($c) Register-Menu } }
)

#endregion

#region Menu item files

# actions\<id>.psd1, one file per item so items can be shared. A file named after a built-in item
# holds only its Command; any other file is a custom item:
#   @{ Title = 'Foo - FooParser'; Program = 'C:\Tools\Foo.exe'; Command = '-f {Path} --csv {Out}'
#      Scope = @('File'); Ext = @('.foo'); Name = @(); Prefix = @()
#      Signature = @{ Offset = 0; Hex = '464F4F00' }   # optional, checked before the program runs
#      Output = $true    # create a results folder ({Out})
#      Wait = $true }    # run in the ForensicAid console; $false starts it and returns (viewers)
$ActionsDir = Join-Path $InstallDir 'actions'
$CustomKeys = 'Title', 'Program', 'Command', 'Scope', 'Ext', 'Name', 'Prefix', 'Signature', 'Output', 'Wait'
$script:ActionErrors = @()

function ConvertTo-Signature($Value) {
    if (-not $Value -or -not $Value.Hex) { return $null }
    $hex = ([string]$Value.Hex -replace '[\s-]', '').ToUpperInvariant()
    if ($hex -notmatch '^([0-9A-F]{2})+$') { throw 'Signature.Hex must be pairs of hex digits, e.g. 4D5A9000.' }
    $offset = [int64]$Value.Offset
    if ($offset -lt 0) { throw 'Signature.Offset cannot be negative.' }
    return @{ Offset = $offset; Hex = $hex }
}

function Import-ActionFiles {
    # Safe to call again after the files changed: start from the built-in items only.
    $script:Catalog = @($Catalog | Where-Object { -not $_.Custom })
    foreach ($e in $Catalog) { $e.Remove('UserCommand') }
    $script:ActionErrors = @()
    if (-not [IO.Directory]::Exists($ActionsDir)) { return }
    $custom = @()
    foreach ($f in (Get-ChildItem -LiteralPath $ActionsDir -Filter '*.psd1' -File | Sort-Object Name)) {
        $id = $f.BaseName
        try {
            if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw 'the file name may only use letters, digits, - and _' }
            $d = Import-PowerShellDataFile -LiteralPath $f.FullName
            $builtin = $Catalog | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if ($builtin) {
                if (-not $builtin.Command) { throw "'$($builtin.Title)' does not run a single program, so its command cannot be changed" }
                if ($d.Command) { $builtin.UserCommand = [string]$d.Command }
                continue
            }
            foreach ($k in 'Title', 'Program', 'Command') { if (-not $d[$k]) { throw "$k is missing" } }
            $scope = @($d.Scope | Where-Object { $_ })
            if (-not $scope.Count) { $scope = @('File') }
            foreach ($s in $scope) { if ($s -notin 'File', 'Dir') { throw "Scope '$s' - use File and/or Dir" } }
            $ext = @($d.Ext | Where-Object { $_ } | ForEach-Object { if ($_ -like '.*') { $_ } else { ".$_" } })
            $names = @($d.Name | Where-Object { $_ })
            $prefixes = @($d.Prefix | Where-Object { $_ })
            $wait = $d.Wait -ne $false
            $custom += @{
                Id = $id; Title = [string]$d.Title; Group = 7; Scope = $scope; Custom = $true
                Program = [string]$d.Program; Command = [string]$d.Command; Signature = (ConvertTo-Signature $d.Signature)
                Match = $(if ($ext.Count + $names.Count + $prefixes.Count) { FileMatch -Ext $ext -Name $names -Prefix $prefixes } else { $null })
                NoOutput = $d.Output -eq $false; Wait = $wait; Hidden = -not $wait; NoPause = -not $wait
                Run = { param($c) Invoke-CustomItem $c }
            }
        } catch {
            $script:ActionErrors += "$($f.Name): $($_.Exception.Message)"
        }
    }
    # Custom items go after the built-in parsers, before the items that manage ForensicAid itself.
    if ($custom.Count) { $script:Catalog = @($Catalog | Where-Object { $_.Group -lt 9 }) + $custom + @($Catalog | Where-Object { $_.Group -ge 9 }) }
}

# Writes (or with $null removes) actions\<id>.psd1 - validated before it replaces the old file.
function Save-ActionFile([string]$Id, $Def) {
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw "Bad item id '$Id' - use letters, digits, - and _." }
    $file = Join-Path $ActionsDir "$Id.psd1"
    if ($null -eq $Def) {
        if ([IO.File]::Exists($file)) { Remove-Item -LiteralPath $file -Force }
        return
    }
    $builtin = $Catalog | Where-Object { $_.Id -eq $Id -and -not $_.Custom } | Select-Object -First 1
    $keys = if ($builtin) { @('Command') } else { $CustomKeys }
    foreach ($k in $Def.Keys) { if ($keys -notcontains $k) { throw "Item '$Id': unknown setting '$k'." } }
    if ($builtin -and -not $builtin.Command) { throw "'$($builtin.Title)' does not run a single program, so its command cannot be changed." }

    $lines = @('# ForensicAid menu item - edited in Settings > Menu items (see docs/ADVANCED.md).', '@{')
    foreach ($k in $keys) {
        if (-not $Def.ContainsKey($k)) { continue }
        $v = $Def[$k]
        if ($k -eq 'Signature') {
            $sig = ConvertTo-Signature $v
            if ($sig) { $lines += "    Signature = @{{ Offset = {0}; Hex = '{1}' }}" -f $sig.Offset, $sig.Hex }
            continue
        }
        if ($k -in 'Scope', 'Ext', 'Name', 'Prefix') { $v = @($v | Where-Object { $_ -is [string] -and $_ }) }
        $lines += "    $k = $(ConvertTo-ConfigLiteral $v)"
    }
    $lines += '}'
    [void][IO.Directory]::CreateDirectory($ActionsDir)
    $tmp = "$file.new"
    [IO.File]::WriteAllText($tmp, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($true)))
    try {
        $d = Import-PowerShellDataFile -LiteralPath $tmp
        if (-not $builtin) { foreach ($k in 'Title', 'Program', 'Command') { if (-not $d[$k]) { throw "$k is missing" } } }
    } catch { Remove-Item -LiteralPath $tmp; throw "Item '$Id' not saved: $($_.Exception.Message)" }
    Move-Item -LiteralPath $tmp -Destination $file -Force
}

# Menu items on/off: off goes to the tray's state file; on also takes the id out of the config's Disabled list.
function Set-ItemsEnabled([hashtable]$Enabled) {
    $state = [System.Collections.Generic.List[string]]@(Get-MenuState)
    $user = @()
    if ([IO.File]::Exists($ConfigFile)) { try { $user = @((Import-PowerShellDataFile -LiteralPath $ConfigFile).Disabled | Where-Object { $_ }) } catch { } }
    $configList = [System.Collections.Generic.List[string]]$user
    foreach ($id in $Enabled.Keys) {
        if ($Enabled[$id]) {
            [void]$state.Remove($id)
            [void]$configList.Remove($id)
        } elseif (-not $state.Contains($id) -and -not $configList.Contains($id)) {
            $state.Add($id)
        }
    }
    [void][IO.Directory]::CreateDirectory($InstallDir)
    [IO.File]::WriteAllText($StateFile, (ConvertTo-Json -InputObject @{ Disabled = @($state) } -Compress))
    if ($configList.Count -ne $user.Count) { Set-ConfigValues @{ Disabled = @($configList) } }
}


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
    $command = {
        param($e, $placeholder)
        $style = if ($e.Hidden) { ' -WindowStyle Hidden' } else { '' }
        '"{0}" -NoProfile -ExecutionPolicy Bypass{1} -File "{2}" -Action {3} -Path "{4}"' -f $psExe, $style, $scriptPath, $e.Id, $placeholder
    }

    # Items that make it into the menu, with their tool icon.
    $shown = foreach ($e in $Catalog) {
        if (@($script:Config.Disabled) -contains $e.Id) { continue }
        $exe = Resolve-EntryExe $e
        if (($e.Tool -or $e.Program) -and -not $exe -and $script:Config.HideUnavailable) { continue }
        @{ Entry = $e; Icon = $(if ($exe) { "$exe,0" } else { '' }) }
    }

    # Classic menu (all Windows versions; "Show more options" on Windows 11).
    foreach ($menu in 'File', 'Dir', 'Background') {
        $scope = if ($menu -eq 'File') { 'File' } else { 'Dir' }
        $i = 0; $lastGroup = $null
        foreach ($s in $shown) {
            $e = $s.Entry
            if ($e.Scope -notcontains $scope) { continue }
            $i++
            $key = '{0}\{1}\{2}\shell\{3:D2}_{4}' -f $RegClasses, $MenuStore, $menu, $i, $e.Id
            $vals = @{ MUIVerb = $e.Title; MultiSelectModel = 'Single' }
            if ($s.Icon) { $vals.Icon = $s.Icon }
            if ($null -ne $lastGroup -and $e.Group -ne $lastGroup) { $vals.CommandFlags = 0x20 }   # ECF_SEPARATORBEFORE
            if ($menu -eq 'File' -and $e.Match -and $script:Config.FilterByFileType) { $vals.AppliesTo = ConvertTo-Aqs $e.Match }
            $lastGroup = $e.Group
            Set-RegValues $key $vals
            Set-RegValues "$key\command" @{ '' = (& $command $e $placeholders[$menu]) }
        }
        Write-Ok ("{0,-10} menu: {1} item(s)" -f $menu, $i)
    }

    # menu.json for the Windows 11 extension (ForensicAidShell.dll reads it on every change).
    $lastGroup = $null
    $items = foreach ($s in $shown) {
        $e = $s.Entry
        $m = if ($e.Match -and $script:Config.FilterByFileType) { $e.Match } else { FileMatch }
        $scopes = @()
        if ($e.Scope -contains 'File') { $scopes += 'File' }
        if ($e.Scope -contains 'Dir') { $scopes += 'Dir', 'Background' }
        [ordered]@{
            id = $e.Id; title = $e.Title; icon = $s.Icon; scopes = $scopes; group = [int]$e.Group
            ext = @($m.Ext); names = @($m.Name); prefixes = @($m.Prefix); excludeNames = @($m.Exclude)
            separatorBefore = ($null -ne $lastGroup -and $e.Group -ne $lastGroup); hidden = [bool]$e.Hidden
            command = (& $command $e '%1')
        }
        $lastGroup = $e.Group
    }
    $json = [ordered]@{ version = 1; title = 'ForensicAid'; icon = $icon; items = @($items) } | ConvertTo-Json -Depth 5
    [void][IO.Directory]::CreateDirectory($InstallDir)
    [IO.File]::WriteAllText($MenuJson, $json, (New-Object Text.UTF8Encoding($false)))

    # With the Windows 11 package registered, its verb shows in both the new and the classic menu, so the
    # classic verbs would appear twice - keep only drive icons, which packaged verbs cannot cover.
    $roots = $MenuRoots
    if (Test-ShellExtension) {
        $roots = @($MenuRoots | Where-Object { $_.Key -like 'Drive\*' })
        Write-Ok 'Windows 11 package registered - classic entries only for drive icons.'
    }
    foreach ($r in $roots) {
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
# create (earlier ForensicAid scripts) and the Python "DFIR Toolbox" (setup.py) install.
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

function Get-TaskFolder {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    return $svc.GetFolder('\')
}

# A logon task, not HKCU\...\Run: Windows holds Run entries back until Explorer has settled, which
# can put the tray icon a minute or more behind the desktop. Same task as in ForensicAidTray.ps1.
function Register-TrayTask([string]$PsExe, [string]$Arguments) {
    $user = [Security.SecurityElement]::Escape([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $xml = @"
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>ForensicAid tray icon</Description></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>$user</UserId></LogonTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>$user</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
  </Settings>
  <Actions Context="Author"><Exec><Command>$([Security.SecurityElement]::Escape($PsExe))</Command><Arguments>$([Security.SecurityElement]::Escape($Arguments))</Arguments></Exec></Actions>
</Task>
"@
    [void](Get-TaskFolder).RegisterTask($TaskName, $xml, 6, $null, $null, 3)   # create or update, interactive token
}

function Remove-TrayAutostart {
    try { (Get-TaskFolder).DeleteTask($TaskName, 0) } catch { }   # throws when there is no task
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RunKey, $true)
    if ($k) { try { $k.DeleteValue('ForensicAidTray', $false) } finally { $k.Close() } }
}

function Start-Tray {
    if (-not [IO.File]::Exists($TrayScript)) { Write-Warn "Tray icon not found: $TrayScript"; return }
    $psExe = Join-Path $PSHOME 'powershell.exe'
    $trayArgs = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $TrayScript
    Remove-TrayAutostart   # also drops the Run value older versions used
    try {
        Register-TrayTask $psExe $trayArgs
    } catch {
        Write-Warn "Logon task not created ($($_.Exception.Message)) - using the Run key, which starts later."
        Set-RegValues $RunKey @{ ForensicAidTray = ('"{0}" {1}' -f $psExe, $trayArgs) }
    }
    Start-Process -FilePath $psExe -ArgumentList $trayArgs -WindowStyle Hidden
    Write-Ok 'Tray icon started (also at logon - untick "Start with Windows" in its menu to stop that).'
}

function Test-Win11 { return [Environment]::OSVersion.Version.Build -ge 22000 }

function Test-ShellExtension {
    if ($env:FORENSICAID_REGROOT -or -not (Test-Win11) -or -not $script:Config.Win11Menu) { return $false }
    try { return [bool](Get-AppxPackage -Name $ShellPackage -ErrorAction SilentlyContinue) } catch { return $false }
}

function Write-MenuHint {
    if (-not (Test-Win11)) { return }
    if (Test-ShellExtension) { Write-Info 'Windows 11: ForensicAid is in the top-level menu (drive icons: "Show more options").' }
    else { Write-Info 'Windows 11: the menu is under "Show more options" (or Shift+Right-click).' }
}

# A DLL loaded by a running dllhost cannot be overwritten, but it can be renamed out of the way.
function Copy-InUseFile([string]$Source, [string]$Destination) {
    try {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    } catch {
        Move-Item -LiteralPath $Destination -Destination ('{0}.{1:yyyyMMddHHmmss}.old' -f $Destination, (Get-Date)) -Force
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
}

# Windows 11 top-level menu: sparse package (win11\dist, built by win11\build.ps1) whose COM server
# ForensicAidShell.dll lives in the install folder and reads menu.json.
function Install-ShellExtension([string]$SourceDir) {
    if ($env:FORENSICAID_REGROOT -or -not (Test-Win11)) { return }
    if (-not $script:Config.Win11Menu) { Write-Info 'Windows 11 top-level menu disabled in the config (Win11Menu).'; return }
    $dist = Join-Path $SourceDir 'win11\dist'
    $msix = Join-Path $dist 'ForensicAid-Shell.msix'
    $cer = Join-Path $dist 'ForensicAid-Shell.cer'
    if (-not ([IO.File]::Exists($msix) -and [IO.File]::Exists($cer) -and [IO.File]::Exists((Join-Path $dist 'ForensicAidShell.dll')))) {
        Write-Warn 'Windows 11 top-level menu not built - run win11\build.ps1 (needs Visual Studio), then install.cmd again.'
        return
    }

    Get-ChildItem -LiteralPath $InstallDir -Filter '*.old' -File | Remove-Item -Force -ErrorAction SilentlyContinue
    foreach ($f in 'ForensicAidShell.dll', 'ForensicAidStub.exe') { Copy-InUseFile (Join-Path $dist $f) (Join-Path $InstallDir $f) }

    $thumb = (New-Object Security.Cryptography.X509Certificates.X509Certificate2 $cer).Thumbprint
    $isTrusted = { [bool](Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object { $_.Thumbprint -eq $thumb }) }
    if (-not (& $isTrusted)) {
        Write-Info 'Windows only registers signed packages: the ForensicAid certificate must be trusted (one UAC prompt).'
        $cmd = "Import-Certificate -FilePath '{0}' -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null" -f $cer.Replace("'", "''")
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        try {
            $null = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -EncodedCommand $enc"
        } catch { }
        if (-not (& $isTrusted)) { Write-Warn 'Certificate not trusted (UAC refused?) - Windows 11 top-level menu skipped, classic menu works.'; return }
    }

    # Update in place, never remove first: removing a package whose menu handler Explorer holds can hang.
    $want = ([xml](Get-Content -LiteralPath (Join-Path $dist 'AppxManifest.xml') -Raw)).Package.Identity.Version
    $have = Get-AppxPackage -Name $ShellPackage
    if ($have -and [string]$have.Version -eq $want -and [string]$have.Status -eq 'Ok') {
        Write-Ok "Windows 11 top-level menu already registered (version $want)."
        return
    }
    try {
        Add-AppxPackage -Path $msix -ExternalLocation $InstallDir -ForceApplicationShutdown -ForceUpdateFromAnyVersion
    } catch {
        Write-Warn "Registering the Windows 11 menu failed: $($_.Exception.Message)"
        return
    }
    Write-Ok "Windows 11 top-level menu registered (version $want)."
    if ((Read-Host '  Restart Explorer now so the new menu shows up? Open Explorer windows will close. [y/N]') -match '^[yYtT]') {
        Stop-Process -Name explorer -Force
        Start-Sleep -Seconds 3
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    }
}

function Uninstall-ShellExtension {
    if ($env:FORENSICAID_REGROOT -or -not (Test-Win11)) { return }
    $pkg = Get-AppxPackage -Name $ShellPackage
    if ($pkg) { $pkg | Remove-AppxPackage; Write-Ok 'Windows 11 top-level menu removed.' }
    foreach ($f in 'ForensicAidShell.dll', 'ForensicAidStub.exe') {
        $p = Join-Path $InstallDir $f
        if ([IO.File]::Exists($p)) {
            try { Remove-Item -LiteralPath $p -Force } catch { Move-Item -LiteralPath $p -Destination "$p.old" -Force }   # still loaded: goes on next install
        }
    }
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
        foreach ($f in 'ForensicAid.ps1', 'ForensicAidTray.ps1', 'ForensicAidSettings.ps1', 'icon.ico') {
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

    $script:Config = Import-Config
    $missing = @($ToolFiles.Keys | Where-Object { -not (Resolve-Tool $_ -Optional) })
    if ($missing.Count -and ($Yes -or (Read-Host "  $($missing.Count) tool(s) not found yet. Look for them on this PC now (about a minute)? [Y/n]") -notmatch '^[nN]')) {
        Invoke-ScanTools -NoRegister
    }
    Install-ShellExtension $src
    Register-Menu   # after the package: decides which classic entries are still needed
    if ($withTray) { Start-Tray } else { Write-Info 'Test mode (FORENSICAID_REGROOT): tray icon not started or added to autostart.' }
    Show-ToolTable
    Write-Host ''
    Write-Info "Change tool paths and settings in ForensicAid > Settings (also in the tray icon menu)."
    Write-MenuHint
}

function Uninstall-ForensicAid {
    if (-not $env:FORENSICAID_REGROOT) {
        Stop-Tray
        Remove-TrayAutostart
    }
    Uninstall-ShellExtension
    Remove-Menu
    Send-ShellRefresh
    Write-Ok 'Context menu removed.'
    foreach ($f in 'ForensicAid.ps1', 'ForensicAidTray.ps1', 'ForensicAidSettings.ps1', 'icon.ico', 'tools.cache.json', 'menu.json') {
        $p = Join-Path $InstallDir $f
        if ([IO.File]::Exists($p)) { Remove-Item -LiteralPath $p -Force }
    }
    Write-Info "Config, menu items (actions folder) and history kept in $InstallDir - delete the folder to remove them."
    $left = @(Get-LegacyItems)
    if ($left.Count) { Write-Warn "Entries from older versions are still present ($($left.Count)); install.cmd offers to remove them." }
}

#endregion

#region Main

Import-ActionFiles

if ($Install)   { Install-ForensicAid; return }
if ($ScanTools) {
    try { Invoke-ScanTools -Deep:$Deep } catch { Write-Err $_.Exception.Message; exit 1 }
    return
}
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

# JSON for the settings window - stdout must carry nothing but the JSON.
if ($SettingsInfo) {
    try {
        $script:Config = Import-Config
        $tools = foreach ($t in $ToolFiles.Keys) {
            $resolved = Resolve-Tool $t -Optional
            [pscustomobject]@{
                Name       = $t
                Configured = [string]$script:Config.Tools[$t]
                Resolved   = [string]$resolved
                Version    = $(if ($resolved) { [string](Get-ToolVersion $t $resolved) } else { '' })
            }
        }
        $cs = Get-ChainsawRuleSet
        $shown = @{}   # not $config: that is $script:Config at this scope
        foreach ($k in $Defaults.Keys) { if ($k -notin 'Tools', 'Disabled') { $shown[$k] = $script:Config[$k] } }
        $items = foreach ($e in $Catalog) {
            $m = $e.Match
            [pscustomobject]@{
                Id             = $e.Id
                Title          = $e.Title
                Group          = $e.Group
                Scope          = @($e.Scope)
                Tool           = [string]$e.Tool
                Program        = [string]$e.Program
                Exe            = [string](Resolve-EntryExe $e)
                Custom         = [bool]$e.Custom
                Enabled        = @($script:Config.Disabled) -notcontains $e.Id
                Command        = [string](Get-EntryCommand $e)
                DefaultCommand = $(if ($e.Custom) { '' } else { [string]$e.Command })
                Vars           = $e.Vars
                Ext            = @($m.Ext); Name = @($m.Name); Prefix = @($m.Prefix)
                Signature      = $e.Signature
                Output         = -not $e.NoOutput
                Wait           = [bool]$e.Wait
            }
        }
        [pscustomobject]@{
            ConfigFile = $ConfigFile
            ActionsDir = $ActionsDir
            Config     = $shown
            Tools      = @($tools)
            Items      = @($items)
            Errors     = @($script:ActionErrors)
            InUse      = @{ SigmaRules = [string]$cs.Sigma; Mapping = [string]$cs.Mapping; Rules = [string]$cs.Rules
                            RECmdBatch = [string](Get-RECmdBatch (Resolve-Tool RECmd -Optional)) }
        } | ConvertTo-Json -Depth 4
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
    return
}

if ($SetConfig) {
    try {
        $json = [IO.File]::ReadAllText($SetConfig) | ConvertFrom-Json
        # Two levels of objects become hashtables: Tools.<name>, Actions.<id>.<setting> (Signature is a third).
        $toHash = {
            param($o)
            if ($o -isnot [Management.Automation.PSCustomObject]) { return , $o }
            $h = @{}
            foreach ($q in $o.PSObject.Properties) { $h[$q.Name] = (& $toHash $q.Value) }
            return $h
        }
        $values = & $toHash $json
        # Items first: a config error must not leave them half done, and they are independent of it.
        if ($values.ContainsKey('Actions')) {
            $savedIds = @($values.Actions.Keys)
            foreach ($id in $savedIds) { Save-ActionFile $id $values.Actions[$id] }
            $values.Remove('Actions')
            Import-ActionFiles
            $bad = @($script:ActionErrors | Where-Object { $savedIds -contains ($_ -replace '\.psd1:.*$', '') })
            if ($bad.Count) { throw ($bad -join "`n") }
            Write-Ok "Menu items saved in $ActionsDir"
        }
        if ($values.ContainsKey('Enabled')) {
            Set-ItemsEnabled $values.Enabled
            $values.Remove('Enabled')
        }
        if ($values.Count) {
            Set-ConfigValues $values
            Write-Ok "Saved $ConfigFile (previous version: ForensicAid.config.psd1.bak)."
        }
        Register-Menu
    } catch { Write-Err $_.Exception.Message; exit 1 }
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
                Available      = (-not ($e.Tool -or $e.Program)) -or [bool](Resolve-EntryExe $e)
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
        # A broken config must not lock out "Settings" / "Check tools".
        if (-not ($entry -and $entry.NoPath)) { throw }
        Write-Warn $_.Exception.Message
        $script:Config = Import-Config -DefaultsOnly
    }
    if (-not $entry) { throw "Unknown action '$Action'. Known: $(($Catalog | ForEach-Object { $_.Id }) -join ', ')" }
    try { $Host.UI.RawUI.WindowTitle = "ForensicAid - $($entry.Title)" } catch { }

    # Explorer passes "E:\" for drive roots; the trailing \" turns into a literal quote, so undo that.
    $p = if ($Path) { $Path.Trim().Trim('"') } else { '' }
    if ($p -match '^[A-Za-z]:$') { $p += '\' }
    $c = @{ Action = $entry.Id; Path = $p; IsDir = $false; Out = $null; Entry = $entry }

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
