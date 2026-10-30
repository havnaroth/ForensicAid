<#
.SYNOPSIS
    ForensicAid tray icon - manage the toolbox and its Explorer menu from the notification area.

.DESCRIPTION
    Started at logon (HKCU\...\Run, value ForensicAidTray) by the installer:

      powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ForensicAidTray.ps1

    The action list comes from 'ForensicAid.ps1 -ListActions', so the catalog lives in one place.
    Long work (menu registration, tool scan) runs in child processes; the UI only polls them.
    Only one instance runs per session (mutex Local\ForensicAidTray). Setting the named event
    Local\ForensicAidTray.Exit closes it cleanly (the uninstaller does that).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$PsExe = Join-Path $PSHOME 'powershell.exe'

# WinForms needs a single-threaded apartment.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    Start-Process -FilePath $PsExe -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $PSCommandPath)
    return
}

$AppName    = 'ForensicAid'
$InstallDir = if ($env:FORENSICAID_HOME) { $env:FORENSICAID_HOME } else { Join-Path $env:LOCALAPPDATA $AppName }
$MainScript = Join-Path $PSScriptRoot 'ForensicAid.ps1'
if (-not [IO.File]::Exists($MainScript)) { $MainScript = Join-Path $InstallDir 'ForensicAid.ps1' }
$ConfigFile = Join-Path $InstallDir 'ForensicAid.config.psd1'
$Template   = Join-Path $PSScriptRoot 'ForensicAid.config.psd1'
$StateFile  = Join-Path $InstallDir 'menu.state.json'
$LastOutput = Join-Path $InstallDir 'last_output.txt'
$HistoryLog = Join-Path $InstallDir 'history.log'
$CacheFile  = Join-Path $InstallDir 'tools.cache.json'
$IconFile   = Join-Path $PSScriptRoot 'icon.ico'
$RunKey     = 'Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue   = 'ForensicAidTray'
$TestMode   = [bool]$env:FORENSICAID_REGROOT   # test install: never touch the real Run key

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ForensicAidTray', [ref]$createdNew)
if (-not $createdNew) { $mutex.Dispose(); return }

$script:Jobs            = New-Object System.Collections.ArrayList
$script:Actions         = @()
$script:LoadError       = $null
$script:ActionsSig      = ''
$script:ListJob         = $null
$script:ListPending     = $false
$script:RegisterJob     = $null
$script:RegisterPending = $false
$script:LastDir         = $null

#region Helpers

# Same quoting as ForensicAid.ps1 (CommandLineToArgvW rules).
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

function Show-Balloon([string]$Text, [string]$Kind = 'Info') {
    if (-not $script:Notify) { return }
    if ($Text.Length -gt 250) { $Text = $Text.Substring(0, 250) + '...' }
    $script:Notify.ShowBalloonTip(4000, $AppName, $Text, [System.Windows.Forms.ToolTipIcon]$Kind)
}

function Get-MainVersion {
    try {
        $m = Select-String -LiteralPath $MainScript -Pattern "^\`$Version\s*=\s*'([^']+)'" | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value }
    } catch { }
    return '?'
}

# Changes to any of these files mean the action list may be different.
function Get-Signature {
    $parts = foreach ($f in $ConfigFile, $Template, $StateFile, $CacheFile, $MainScript) {
        if ([IO.File]::Exists($f)) { [IO.File]::GetLastWriteTimeUtc($f).Ticks } else { 0 }
    }
    return ($parts -join '|')
}

function Get-OutputRoot {
    $root = '%USERPROFILE%\ForensicAid_Output'
    foreach ($f in $ConfigFile, $Template) {
        if (-not [IO.File]::Exists($f)) { continue }
        try {
            $cfg = Import-PowerShellDataFile -LiteralPath $f
            if ($cfg.OutputRoot) { $root = [string]$cfg.OutputRoot }
        } catch { }
        break
    }
    return [Environment]::ExpandEnvironmentVariables($root.Trim().Trim('"'))
}

function Open-Folder([string]$Dir) {
    Start-Process explorer.exe -ArgumentList (ConvertTo-ArgumentString @($Dir))
}

function Open-InNotepad([string]$File) {
    Start-Process notepad.exe -ArgumentList (ConvertTo-ArgumentString @($File))
}

# Opens a visible console running one ForensicAid action.
function Start-MainVisible([object[]]$Arguments) {
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MainScript) + $Arguments
    Start-Process -FilePath $PsExe -ArgumentList (ConvertTo-ArgumentString $all)
}

#endregion

#region Background child processes

# Starts ForensicAid.ps1 hidden with captured output; $OnDone gets the job once the process ends.
function Start-Child([string]$Arguments, [scriptblock]$OnDone) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PsExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $MainScript, $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    # Drain both pipes on the thread pool so a full pipe can never stall the child.
    $job = @{
        Process  = $p
        OutTask  = $p.StandardOutput.ReadToEndAsync()
        ErrTask  = $p.StandardError.ReadToEndAsync()
        OnDone   = $OnDone
        ExitCode = $null
        StdOut   = ''
        StdErr   = ''
    }
    [void]$script:Jobs.Add($job)
    return $job
}

function Get-JobError($Job) {
    $lines = @(($Job.StdErr + "`n" + $Job.StdOut) -split "`r?`n" | Where-Object { $_.Trim() })
    $err = @($lines | Where-Object { $_ -like '`[x`]*' })
    if ($err.Count) { return $err[-1].Substring(3).Trim() }
    if ($lines.Count) { return $lines[-1].Trim() }
    return "exit code $($Job.ExitCode)"
}

function Invoke-Tick {
    if ($script:ExitSignal.WaitOne(0)) { Exit-Tray; return }
    foreach ($job in @($script:Jobs)) {
        if (-not $job.Process.HasExited -or -not $job.OutTask.IsCompleted -or -not $job.ErrTask.IsCompleted) { continue }
        $script:Jobs.Remove($job)
        $job.Process.WaitForExit()
        $job.ExitCode = $job.Process.ExitCode
        $job.StdOut = [string]$job.OutTask.Result
        $job.StdErr = [string]$job.ErrTask.Result
        $job.Process.Dispose()
        try { & $job.OnDone $job } catch { Show-Balloon $_.Exception.Message 'Error' }
    }
}

#endregion

#region Action list

function Update-Actions([switch]$Force) {
    if ($script:ListJob) { if ($Force) { $script:ListPending = $true }; return }
    if (-not $Force -and (Get-Signature) -eq $script:ActionsSig) { return }
    $script:ListJob = Start-Child '-ListActions' $script:OnActionsLoaded
}

$script:OnActionsLoaded = {
    param($job)
    $script:ListJob = $null
    if ($job.ExitCode -eq 0) {
        try {
            $parsed = $job.StdOut | ConvertFrom-Json
            $script:Actions = @($parsed)
            $script:LoadError = $null
        } catch {
            $script:LoadError = 'Bad action list: ' + $_.Exception.Message
        }
    } else {
        $script:LoadError = Get-JobError $job
    }
    # Signature taken after the load: -ListActions may itself have written the tool cache.
    $script:ActionsSig = if ($script:LoadError) { '' } else { Get-Signature }
    if ($script:LoadError) { Show-Balloon "Cannot read the action list: $($script:LoadError)" 'Error' }
    Update-ActionMenus
    if ($script:ListPending) { $script:ListPending = $false; Update-Actions -Force }
}

function Clear-DropDown($Item) {
    $old = @($Item.DropDownItems)
    $Item.DropDownItems.Clear()
    foreach ($o in $old) { $o.Dispose() }
}

function Add-Note($Menu, [string]$Text) {
    $n = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
    $n.Enabled = $false
    [void]$Menu.DropDownItems.Add($n)
}

function Update-ActionMenus {
    Clear-DropDown $script:RunMenu
    Clear-DropDown $script:ItemsMenu
    if ($script:LoadError) {
        foreach ($m in $script:RunMenu, $script:ItemsMenu) { Add-Note $m '(action list unavailable - see Check tools)' }
        return
    }

    # Run action...: enabled actions whose tool exists and that work on a path.
    $lastGroup = $null; $n = 0
    foreach ($a in $script:Actions) {
        if ($a.NoPath -or -not $a.Enabled -or -not $a.Available) { continue }
        if ($null -ne $lastGroup -and $a.Group -ne $lastGroup) {
            [void]$script:RunMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        }
        $lastGroup = $a.Group
        $scopes = @($a.Scope)
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($a.Title)
        if ($scopes -contains 'File' -and $scopes -contains 'Dir') {
            foreach ($mode in 'File', 'Dir') {
                $text = if ($mode -eq 'File') { 'On a file...' } else { 'On a folder or drive...' }
                $sub = New-Object System.Windows.Forms.ToolStripMenuItem($text)
                $sub.Tag = @{ Id = $a.Id; Title = $a.Title; Mode = $mode }
                $sub.Add_Click($script:OnRunClick)
                [void]$item.DropDownItems.Add($sub)
            }
        } else {
            $item.Text = $a.Title + '...'
            $item.Tag = @{ Id = $a.Id; Title = $a.Title; Mode = $scopes[0] }
            $item.Add_Click($script:OnRunClick)
        }
        [void]$script:RunMenu.DropDownItems.Add($item)
        $n++
    }
    if (-not $n) { Add-Note $script:RunMenu '(no actions available - see Check tools)' }

    # Context menu items: checked = shown in the Explorer menu.
    $lastGroup = $null
    foreach ($a in $script:Actions) {
        if ($null -ne $lastGroup -and $a.Group -ne $lastGroup) {
            [void]$script:ItemsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        }
        $lastGroup = $a.Group
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($a.Title)
        $item.Checked = [bool]$a.Enabled
        $item.Tag = @{ Id = $a.Id; Title = $a.Title }
        if (-not $a.Available) {
            $item.Text += '  (tool missing)'
            $item.Enabled = $false
        } elseif ($a.ConfigDisabled) {
            $item.Text += '  (disabled in config)'
            $item.Enabled = $false
        } else {
            $item.Add_Click($script:OnToggleClick)
        }
        [void]$script:ItemsMenu.DropDownItems.Add($item)
    }
    if (-not @($script:Actions).Count) { Add-Note $script:ItemsMenu '(none)' }
}

#endregion

#region Menu actions

function Show-Picker([string]$Mode, [string]$Title) {
    # An invisible topmost owner keeps the dialog in front (a tray app has no window of its own).
    $owner = New-Object System.Windows.Forms.Form
    $owner.FormBorderStyle = 'None'
    $owner.ShowInTaskbar = $false
    $owner.TopMost = $true
    $owner.StartPosition = 'Manual'
    $owner.Location = New-Object System.Drawing.Point(-32000, -32000)
    $owner.Size = New-Object System.Drawing.Size(1, 1)
    $dlg = $null
    try {
        $owner.Show()
        $owner.Activate()
        $start = if ($script:LastDir -and [IO.Directory]::Exists($script:LastDir)) { $script:LastDir } else { $null }
        if ($Mode -eq 'File') {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = $Title
            $dlg.Filter = 'All files (*.*)|*.*'
            $dlg.DereferenceLinks = $false   # .lnk files are evidence, not shortcuts to follow
            if ($start) { $dlg.InitialDirectory = $start }
            if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
                $script:LastDir = [IO.Path]::GetDirectoryName($dlg.FileName)
                return $dlg.FileName
            }
        } else {
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = $Title
            $dlg.ShowNewFolderButton = $false
            if ($start) { $dlg.SelectedPath = $start }
            if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
                $script:LastDir = $dlg.SelectedPath
                return $dlg.SelectedPath
            }
        }
        return $null
    } finally {
        if ($dlg) { $dlg.Dispose() }
        $owner.Close()
        $owner.Dispose()
    }
}

function Invoke-RunAction($Tag) {
    $what = if ($Tag.Mode -eq 'File') { 'evidence file' } else { 'evidence folder or drive' }
    $p = Show-Picker $Tag.Mode ('{0} - choose the {1}' -f $Tag.Title, $what)
    if (-not $p) { return }
    Start-MainVisible @('-Action', $Tag.Id, '-Path', $p)
}

function Save-MenuState([string[]]$Disabled) {
    [void][IO.Directory]::CreateDirectory($InstallDir)
    $json = ConvertTo-Json -InputObject @{ Disabled = @($Disabled) } -Compress
    [IO.File]::WriteAllText($StateFile, $json)
}

function Get-MenuState {
    if (-not [IO.File]::Exists($StateFile)) { return @() }
    try {
        return @((Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).Disabled | Where-Object { $_ })
    } catch { return @() }
}

function Switch-MenuItem($Item) {
    $id = $Item.Tag.Id
    $enable = -not $Item.Checked
    $off = New-Object System.Collections.Generic.List[string]
    foreach ($d in @(Get-MenuState)) { if ($d -ne $id -and -not $off.Contains($d)) { $off.Add($d) } }
    if (-not $enable) { $off.Add($id) }
    Save-MenuState $off.ToArray()
    $Item.Checked = $enable
    Start-Register
}

# Re-registers the Explorer menu in a hidden child; requests made meanwhile are coalesced into one more run.
function Start-Register {
    if ($script:RegisterJob) { $script:RegisterPending = $true; return }
    $script:RefreshItem.Enabled = $false
    $script:RegisterJob = Start-Child '-RegisterMenu' $script:OnRegisterDone
}

$script:OnRegisterDone = {
    param($job)
    $script:RegisterJob = $null
    if ($script:RegisterPending) { $script:RegisterPending = $false; Start-Register; return }
    $script:RefreshItem.Enabled = $true
    if ($job.ExitCode -eq 0) { Show-Balloon 'Explorer context menu updated.' }
    else { Show-Balloon "Updating the context menu failed: $(Get-JobError $job)" 'Error' }
    Update-Actions -Force
}

function Open-LastResults {
    $dir = $null
    if ([IO.File]::Exists($LastOutput)) { $dir = ([IO.File]::ReadAllText($LastOutput)).Trim() }
    if ($dir -and [IO.Directory]::Exists($dir)) { Open-Folder $dir; return }
    Show-Balloon 'No results yet - run an action first.'
}

function Open-OutputRoot {
    $root = Get-OutputRoot
    [void][IO.Directory]::CreateDirectory($root)
    Open-Folder $root
}

function Edit-Config {
    if (-not [IO.File]::Exists($ConfigFile)) {
        if (-not [IO.File]::Exists($Template)) { Show-Balloon "Config not found: $ConfigFile" 'Warning'; return }
        [void][IO.Directory]::CreateDirectory($InstallDir)
        Copy-Item -LiteralPath $Template -Destination $ConfigFile
    }
    Open-InNotepad $ConfigFile
    Show-Balloon 'After saving the config use Refresh menu.'
}

function Open-HistoryLog {
    if ([IO.File]::Exists($HistoryLog)) { Open-InNotepad $HistoryLog } else { Show-Balloon 'No history yet.' }
}

function Open-InstallDir {
    if ([IO.Directory]::Exists($InstallDir)) { Open-Folder $InstallDir } else { Show-Balloon "Not installed: $InstallDir" 'Warning' }
}

function Test-Autostart {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RunKey)
    if (-not $k) { return $false }
    try { return $null -ne $k.GetValue($RunValue) } finally { $k.Close() }
}

function Set-Autostart([bool]$On) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($RunKey)
    try {
        if ($On) {
            $cmd = '"{0}" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{1}"' -f $PsExe, $PSCommandPath
            $k.SetValue($RunValue, $cmd, [Microsoft.Win32.RegistryValueKind]::String)
        } else {
            $k.DeleteValue($RunValue, $false)
        }
    } finally { $k.Close() }
}

function Exit-Tray {
    $script:Timer.Stop()
    $script:Notify.Visible = $false
    $script:Context.ExitThread()
}

#endregion

#region UI

# Every handler catches its own errors and shows them as a balloon, so the message loop keeps running.
$script:OnRunClick    = { try { Invoke-RunAction $this.Tag } catch { Show-Balloon $_.Exception.Message 'Error' } }
$script:OnToggleClick = { try { Switch-MenuItem $this } catch { Show-Balloon $_.Exception.Message 'Error' } }

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$header = New-Object System.Windows.Forms.ToolStripMenuItem("$AppName $(Get-MainVersion)")
$header.Enabled = $false
$header.Font = New-Object System.Drawing.Font($header.Font, [System.Drawing.FontStyle]::Bold)
[void]$menu.Items.Add($header)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$script:RunMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Run action...')
$script:ItemsMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Context menu items')
foreach ($m in $script:RunMenu, $script:ItemsMenu) { Add-Note $m '(loading...)'; [void]$menu.Items.Add($m) }
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$items = [ordered]@{
    'Check tools'        = { try { Start-MainVisible @('-Action', 'doctor') } catch { Show-Balloon $_.Exception.Message 'Error' } }
    'Edit configuration' = { try { Edit-Config } catch { Show-Balloon $_.Exception.Message 'Error' } }
    'Refresh menu'       = { try { Start-Register } catch { Show-Balloon $_.Exception.Message 'Error' } }
    '-1'                 = $null
    'Open last results'  = { try { Open-LastResults } catch { Show-Balloon $_.Exception.Message 'Error' } }
    'Open output folder' = { try { Open-OutputRoot } catch { Show-Balloon $_.Exception.Message 'Error' } }
    'Open history log'   = { try { Open-HistoryLog } catch { Show-Balloon $_.Exception.Message 'Error' } }
    'Open install folder' = { try { Open-InstallDir } catch { Show-Balloon $_.Exception.Message 'Error' } }
    '-2'                 = $null
}
foreach ($text in $items.Keys) {
    if ($text -like '-*') { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); continue }
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $item.Add_Click($items[$text])
    [void]$menu.Items.Add($item)
    if ($text -eq 'Refresh menu') { $script:RefreshItem = $item }
    if ($text -eq 'Open last results') { $item.Font = New-Object System.Drawing.Font($item.Font, [System.Drawing.FontStyle]::Bold) }
}

$script:AutoItem = New-Object System.Windows.Forms.ToolStripMenuItem('Start with Windows')
if ($TestMode) {
    $script:AutoItem.Text += '  (test mode)'
    $script:AutoItem.Enabled = $false
} else {
    $script:AutoItem.Add_Click({
        try { Set-Autostart (-not $this.Checked); $this.Checked = Test-Autostart } catch { Show-Balloon $_.Exception.Message 'Error' }
    })
}
[void]$menu.Items.Add($script:AutoItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
$exitItem.Add_Click({ try { Exit-Tray } catch { [System.Windows.Forms.Application]::ExitThread() } })
[void]$menu.Items.Add($exitItem)

$menu.Add_Opening({
    try {
        if (-not $TestMode) { $script:AutoItem.Checked = Test-Autostart }
        Update-Actions
    } catch { }
})

$trayIcon = $null
try {
    if ([IO.File]::Exists($IconFile)) { $trayIcon = New-Object System.Drawing.Icon($IconFile, [System.Windows.Forms.SystemInformation]::SmallIconSize) }
} catch { }

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Icon = if ($trayIcon) { $trayIcon } else { [System.Drawing.SystemIcons]::Application }
$script:Notify.Text = $AppName
$script:Notify.ContextMenuStrip = $menu
$script:Notify.Add_MouseDoubleClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        try { Open-LastResults } catch { Show-Balloon $_.Exception.Message 'Error' }
    }
})

$script:ExitSignal = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\ForensicAidTray.Exit')
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 300
$script:Timer.Add_Tick({ try { Invoke-Tick } catch { } })

$script:Context = New-Object System.Windows.Forms.ApplicationContext

#endregion

#region Main

try {
    $script:Notify.Visible = $true
    $script:Timer.Start()
    Update-Actions -Force
    [System.Windows.Forms.Application]::Run($script:Context)
} finally {
    $script:Timer.Stop()
    $script:Timer.Dispose()
    $script:Notify.Visible = $false
    $script:Notify.Dispose()
    $menu.Dispose()
    if ($trayIcon) { $trayIcon.Dispose() }
    foreach ($job in @($script:Jobs)) { try { $job.Process.Dispose() } catch { } }
    $script:ExitSignal.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

#endregion
