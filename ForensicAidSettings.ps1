<#
.SYNOPSIS
    ForensicAid settings window - change tool paths and options without editing the config file.

.DESCRIPTION
    Opened from the tray icon and from ForensicAid > Settings in the Explorer menu:

      powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ForensicAidSettings.ps1

    The window never writes the config itself. It reads 'ForensicAid.ps1 -SettingsInfo' and hands only the
    changed values to 'ForensicAid.ps1 -SetConfig', which edits the file in place (comments and settings
    not shown here stay as they are) and re-registers the menu. Only one window runs per session.
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
$IconFile   = Join-Path $PSScriptRoot 'icon.ico'
$WindowTitle = "$AppName settings"

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# One window per session: a second start brings the open one to the front.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ForensicAidSettings', [ref]$createdNew)
if (-not $createdNew) {
    try { [void](New-Object -ComObject WScript.Shell).AppActivate($WindowTitle) } catch { }
    return
}

$script:Info    = $null    # last -SettingsInfo result
$script:Job     = $null    # running ForensicAid.ps1 child
$script:Fields  = [ordered]@{}
$script:Closing = $false

#region Helpers

function Expand-PathValue([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return [Environment]::ExpandEnvironmentVariables($Value.Trim().Trim('"'))
}

function Show-Message([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    return [System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $WindowTitle,
        [System.Windows.Forms.MessageBoxButtons]::$Buttons, [System.Windows.Forms.MessageBoxIcon]::$Icon)
}

function Set-Status([string]$Text, [string]$Kind = 'Info') {
    $script:StatusLabel.Text = $Text
    $script:StatusLabel.ForeColor = switch ($Kind) {
        'Error' { [System.Drawing.Color]::Firebrick }
        'Ok'    { [System.Drawing.Color]::DarkGreen }
        default { [System.Drawing.SystemColors]::ControlText }
    }
}

function Open-ConfigFile {
    if ($script:Info) { $file = $script:Info.ConfigFile } else { $file = $ConfigFile }
    Start-Process notepad.exe -ArgumentList ('"{0}"' -f $file)
}

function Select-PathDialog([string]$Kind, [string]$Current, [string]$Filter = 'All files (*.*)|*.*') {
    $cur = Expand-PathValue $Current
    if ($Kind -eq 'Folder') {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ([IO.Directory]::Exists($cur)) { $dlg.SelectedPath = $cur }
        try { if ($dlg.ShowDialog($script:Form) -eq 'OK') { return $dlg.SelectedPath } } finally { $dlg.Dispose() }
    } else {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = $Filter
        if ([IO.File]::Exists($cur)) { $dlg.InitialDirectory = [IO.Path]::GetDirectoryName($cur); $dlg.FileName = [IO.Path]::GetFileName($cur) }
        try { if ($dlg.ShowDialog($script:Form) -eq 'OK') { return $dlg.FileName } } finally { $dlg.Dispose() }
    }
    return $null
}

#endregion

#region Background child process

# Runs ForensicAid.ps1 hidden with captured output; $OnDone gets the job once the process ends.
function Start-Main([string]$Arguments, [string]$Busy, [scriptblock]$OnDone) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PsExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $MainScript, $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $script:Job = @{
        Process = $p
        OutTask = $p.StandardOutput.ReadToEndAsync()
        ErrTask = $p.StandardError.ReadToEndAsync()
        OnDone  = $OnDone
    }
    Set-Busy $true
    Set-Status $Busy
}

function Get-JobError($Job) {
    $lines = @(($Job.StdErr + "`n" + $Job.StdOut) -split "`r?`n" | Where-Object { $_.Trim() })
    $err = @($lines | Where-Object { $_ -like '`[x`]*' })
    if ($err.Count) { return $err[-1].Substring(3).Trim() }
    if ($lines.Count) { return $lines[-1].Trim() }
    return "exit code $($Job.ExitCode)"
}

function Invoke-Tick {
    $job = $script:Job
    if (-not $job -or -not $job.Process.HasExited -or -not $job.OutTask.IsCompleted -or -not $job.ErrTask.IsCompleted) { return }
    $script:Job = $null
    $job.Process.WaitForExit()
    $job.ExitCode = $job.Process.ExitCode
    $job.StdOut = [string]$job.OutTask.Result
    $job.StdErr = [string]$job.ErrTask.Result
    $job.Process.Dispose()
    Set-Busy $false
    & $job.OnDone $job
}

function Set-Busy([bool]$On) {
    $script:Form.UseWaitCursor = $On
    foreach ($b in $script:SaveButton, $script:ScanButton) { $b.Enabled = -not $On -and $null -ne $script:Info }
}

#endregion

#region Load and save

function Import-Settings([string]$Done = '') {
    $script:LoadedMessage = $Done
    Start-Main '-SettingsInfo' 'Reading the configuration and looking for tools ...' {
        param($job)
        if ($job.ExitCode -ne 0) {
            $msg = Get-JobError $job
            Set-Status "The config could not be read: $msg" 'Error'
            if ((Show-Message "The config could not be read:`n`n$msg`n`nOpen the config file in Notepad to fix it?" 'YesNo' 'Warning') -eq 'Yes') { Open-ConfigFile }
            return
        }
        $script:Info = $job.StdOut | ConvertFrom-Json
        Show-Settings
        Set-Busy $false
        Set-Status $script:LoadedMessage 'Ok'
    }
}

function Show-Settings {
    $script:Grid.Rows.Clear()
    foreach ($t in $script:Info.Tools) {
        $i = $script:Grid.Rows.Add(@($t.Name, $t.Configured, $null, '', ''))
        $row = $script:Grid.Rows[$i]
        $row.Tag = $t
        Update-ToolRow $row
    }
    foreach ($f in $script:Fields.Values) {
        $src = $script:Info.Config
        if ($f.Section) { $src = $src.($f.Section) }
        $f.Original = $src.($f.Name)
        if ($f.List) { $f.Original = @($f.Original | Where-Object { $_ }) }
        & $f.Set $f.Original
        if ($f.InUse) {
            $used = [string]$script:Info.InUse.($f.InUse)
            $f.Note.Text = if ($used) { "Empty = automatic. In use now: $used" } else { 'Empty = automatic. Nothing found yet.' }
        }
    }
    Show-Items
}

# Version and status for one tool row, from the path typed in it.
function Update-ToolRow($Row) {
    $t = $Row.Tag
    $typed = ([string]$Row.Cells['Path'].Value).Trim().Trim('"')
    $status = $Row.Cells['Status']
    $version = ''
    $status.ToolTipText = ''
    if (-not $typed) {
        if (-not $t.Configured -and $t.Resolved) {
            $version = $t.Version
            $status.Value = "Found: $($t.Resolved)"
            $status.ToolTipText = $t.Resolved
            $status.Style.ForeColor = [System.Drawing.Color]::DarkGreen
        } else {
            $status.Value = 'Not found - searched for when saved'
            $status.Style.ForeColor = [System.Drawing.Color]::DarkGoldenrod
        }
    } else {
        $exe = Expand-PathValue $typed
        if ([IO.File]::Exists($exe)) {
            if ($typed -eq $t.Configured) { $version = $t.Version }
            elseif ($t.Name -ne 'Chainsaw') { try { $version = ((Get-Item -LiteralPath $exe).VersionInfo.FileVersion -replace '[^\d\.].*$', '') } catch { } }
            $status.Value = 'OK'
            $status.Style.ForeColor = [System.Drawing.Color]::DarkGreen
        } else {
            $status.Value = 'File not found'
            $status.Style.ForeColor = [System.Drawing.Color]::Firebrick
        }
    }
    if ($version -match '^0(\.0)*$') { $version = '' }   # the exe carries no version
    $Row.Cells['Version'].Value = $version
}

function Test-Same($A, $B) {
    if ($A -is [array] -or $B -is [array]) { return (@($A) -join "`n") -ceq (@($B) -join "`n") }
    return "$A" -ceq "$B"
}

# Only what differs from the file goes to -SetConfig, so untouched settings keep their exact text.
function Get-Changes {
    $changes = @{}
    if (-not $script:Info) { return $changes }
    [void]$script:Grid.EndEdit()
    $tools = @{}
    foreach ($row in $script:Grid.Rows) {
        $typed = ([string]$row.Cells['Path'].Value).Trim().Trim('"')
        if ($typed -ne [string]$row.Tag.Configured) { $tools[$row.Tag.Name] = $typed }
    }
    if ($tools.Count) { $changes.Tools = $tools }
    if ($script:ItemDrafts.Count) { $changes.Actions = $script:ItemDrafts.Clone() }
    [void]$script:ItemGrid.EndEdit()
    $enabled = @{}
    foreach ($row in $script:ItemGrid.Rows) {
        $on = [bool]$row.Cells['On'].Value
        if ($on -ne [bool]$row.Tag.Enabled -and -not ($row.Tag.New -and $on)) { $enabled[$row.Tag.Id] = $on }
    }
    if ($enabled.Count) { $changes.Enabled = $enabled }
    foreach ($f in $script:Fields.Values) {
        $v = & $f.Get
        if ($f.List) { $v = @($v | Where-Object { $_ }) }
        if (Test-Same $v $f.Original) { continue }
        if ($f.Section) {
            if (-not $changes.ContainsKey($f.Section)) { $changes[$f.Section] = @{} }
            $changes[$f.Section][$f.Name] = $v
        } else {
            $changes[$f.Name] = $v
        }
    }
    return $changes
}

function Save-Settings([scriptblock]$Then) {
    $changes = Get-Changes
    if (-not $changes.Count) {
        Set-Status 'Nothing to save.'
        if ($Then) { & $Then }
        return
    }
    # Kept in script scope: the handler below runs after this function has returned.
    $script:SaveFile = Join-Path ([IO.Path]::GetTempPath()) ("ForensicAid.settings.$PID.json")
    [IO.File]::WriteAllText($script:SaveFile, (ConvertTo-Json -InputObject $changes -Depth 4))
    $script:AfterSave = $Then
    Start-Main ('-SetConfig "{0}"' -f $script:SaveFile) 'Saving and refreshing the Explorer menu ...' {
        param($job)
        Remove-Item -LiteralPath $script:SaveFile -ErrorAction SilentlyContinue
        if ($job.ExitCode -ne 0) {
            $msg = Get-JobError $job
            Set-Status "Not saved: $msg" 'Error'
            [void](Show-Message "The settings were not saved:`n`n$msg" 'OK' 'Error')
            return
        }
        if ($script:AfterSave) { & $script:AfterSave } else { Import-Settings 'Saved. The Explorer menu is up to date.' }
    }
}

function Start-ToolScan {
    $go = {
        Start-Main '-ScanTools -Yes' 'Searching this PC for tools (up to a minute) ...' {
            param($job)
            if ($job.ExitCode -ne 0) { Set-Status "Scan failed: $(Get-JobError $job)" 'Error'; return }
            Import-Settings 'Search finished. Paths found are saved in the config.'
        }
    }
    # The scan writes into the config itself, so pending edits must be saved (or kept back) first.
    if ((Get-Changes).Count) {
        if ((Show-Message 'Save your changes before searching for tools?' 'OKCancel' 'Question') -ne 'OK') { return }
        Save-Settings $go
    } else {
        & $go
    }
}

#endregion

#region Menu items

# Edits waiting for Save: id -> the item's new definition, or $null to delete its file
# (a custom item goes away, a built-in one gets its default command back).
$script:ItemDrafts = @{}

$CommonVars = [ordered]@{
    Path = 'the file or folder you right-clicked'
    In   = '-f <file> or -d <folder> (how the EZ tools take their input)'
    Out  = 'the results folder of this run'
    Name = 'the file or folder name, without its path'
    Dir  = 'the folder you clicked, or the folder holding the file'
}

function Get-ItemVarHelp($Item) {
    $vars = [ordered]@{}
    foreach ($k in $CommonVars.Keys) { $vars[$k] = $CommonVars[$k] }
    if ($Item -and $Item.Vars) { foreach ($p in $Item.Vars.PSObject.Properties) { $vars[$p.Name] = $p.Value } }
    return $vars
}

# What the row shows now: the pending draft if there is one, else what -SettingsInfo reported.
function Get-ItemView($Item) {
    $v = @{ Title = $Item.Title; Program = $Item.Program; Command = $Item.Command; Scope = @($Item.Scope); Ext = @($Item.Ext)
            Name = @($Item.Name); Prefix = @($Item.Prefix); Signature = $Item.Signature; Output = $Item.Output; Wait = $Item.Wait }
    if ($script:ItemDrafts.ContainsKey($Item.Id)) {
        $d = $script:ItemDrafts[$Item.Id]
        if ($null -eq $d) { $v.Command = $Item.DefaultCommand }
        else { foreach ($k in $d.Keys) { $v[$k] = $d[$k] } }
    }
    return $v
}

function Update-ItemRow($Row) {
    $item = $Row.Tag
    $v = Get-ItemView $item
    $Row.Cells['Item'].Value = $v.Title
    $grey = [System.Drawing.SystemColors]::GrayText
    if ($item.Custom) {
        $Row.Cells['Program'].Value = $v.Program
        $exists = [IO.File]::Exists((Expand-PathValue $v.Program))
        $Row.Cells['Program'].Style.ForeColor = if ($exists) { [System.Drawing.SystemColors]::ControlText } else { [System.Drawing.Color]::Firebrick }
        $Row.Cells['Program'].ToolTipText = if ($exists) { '' } else { 'Program not found' }
    } else {
        $Row.Cells['Program'].Value = $item.Tool
        $Row.Cells['Program'].ToolTipText = $item.Exe
    }
    if ($v.Command) {
        $Row.Cells['Command'].Value = $v.Command
        $Row.Cells['Command'].Style.ForeColor = [System.Drawing.SystemColors]::ControlText
        $changed = (-not $item.Custom) -and $v.Command -cne $item.DefaultCommand
        $Row.Cells['Command'].Style.Font = if ($changed) { $script:BoldFont } else { $null }
        $Row.Cells['Command'].ToolTipText = if ($changed) { "Changed. Default: $($item.DefaultCommand)" } else { '' }
    } else {
        $Row.Cells['Command'].Value = if ($item.Group -ge 9) { '(manages ForensicAid)' } else { '(several steps - not editable)' }
        $Row.Cells['Command'].Style.ForeColor = $grey
    }
    $Row.Cells['Edit'].Value = if ($v.Command) { 'Edit...' } else { '' }
}

function Show-Items {
    $script:ItemDrafts = @{}
    $script:ItemGrid.Rows.Clear()
    foreach ($item in $script:Info.Items) {
        $i = $script:ItemGrid.Rows.Add(@([bool]$item.Enabled, '', '', '', ''))
        $row = $script:ItemGrid.Rows[$i]
        $row.Tag = $item
        Update-ItemRow $row
    }
    $errors = @($script:Info.Errors)
    $script:ItemErrors.Visible = $errors.Count -gt 0
    $script:ItemErrors.Text = "Some item files could not be read and are left out:`n" + ($errors -join "`n")
}

function New-ItemId([string]$Title) {
    $slug = ($Title.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    if (-not $slug) { $slug = 'item' }
    $taken = @($script:ItemGrid.Rows | ForEach-Object { $_.Tag.Id })
    $id = $slug; $n = 2
    while ($taken -contains $id) { $id = "$slug-$n"; $n++ }
    return $id
}

# The command as it would run on a made-up example; values only known at run time show as <Name>.
function Format-CommandPreview([string]$Exe, [string]$Template, $Item, [string[]]$Scope, [string]$SampleName) {
    $isDir = $Scope -notcontains 'File'
    $path = if ($isDir) { 'E:\Case\C' } else { "E:\Case\C\$SampleName" }
    $leaf = [IO.Path]::GetFileName($path)
    $sample = @{
        Path = @($path); In = @($(if ($isDir) { '-d' } else { '-f' }), $path); Name = @($leaf)
        Out = @("E:\Case\C\ForensicAid\20261031_120000_$($Item.Id)_$leaf"); Dir = @($(if ($isDir) { $path } else { 'E:\Case\C' }))
    }
    $known = Get-ItemVarHelp $Item
    $quote = { param($s) if ($s -match '\s') { '"' + $s + '"' } else { $s } }
    $line = [regex]::Replace($Template, '\{(\w+)\}', [Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $name = $m.Groups[1].Value
        if (-not $known.Contains($name)) { return "{$name?}" }
        if (-not $sample.ContainsKey($name)) { return "<$name>" }
        $inQuotes = (@($Template.Substring(0, $m.Index).ToCharArray() | Where-Object { $_ -eq '"' }).Count % 2) -eq 1
        if ($inQuotes) { return ($sample[$name] -join ' ') }
        return (($sample[$name] | ForEach-Object { & $quote $_ }) -join ' ')
    })
    return ('{0} {1}' -f $Exe, $line).Trim()
}

# Edit dialog for one item. $Item = $null adds a custom item. Returns the new definition, or $null if cancelled.
function Show-ItemDialog($Item) {
    $isNew = $null -eq $Item
    if ($isNew) { $Item = [pscustomobject]@{ Id = ''; Custom = $true; Vars = $null; DefaultCommand = '' } }
    $custom = [bool]$Item.Custom
    $v = if ($isNew) {
        @{ Title = ''; Program = ''; Command = '{Path}'; Scope = @('File'); Ext = @(); Name = @(); Prefix = @(); Signature = $null; Output = $true; Wait = $true }
    } else { Get-ItemView $Item }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = if ($isNew) { 'Add menu item' } else { "Menu item - $($v.Title)" }
    $dlg.Font = $form.Font
    $dlg.StartPosition = 'CenterParent'
    $dlg.Size = New-Object System.Drawing.Size(780, $(if ($custom) { 640 } else { 470 }))
    $dlg.MinimumSize = New-Object System.Drawing.Size(560, 360)
    $dlg.MinimizeBox = $false
    $dlg.ShowIcon = $false

    $tl = New-Object System.Windows.Forms.TableLayoutPanel
    $tl.Dock = 'Fill'
    $tl.AutoScroll = $true
    $tl.Padding = New-Object System.Windows.Forms.Padding(10, 8, 20, 8)
    $tl.ColumnCount = 3
    [void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
    [void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
    $add = {
        param($Label, $Control, $Button)
        $r = $tl.RowCount; $tl.RowCount++
        [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
        if ($Label) {
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $Label; $l.AutoSize = $true; $l.Anchor = 'Left'
            $tl.Controls.Add($l, 0, $r)
        }
        $Control.Anchor = 'Left, Right'
        $tl.Controls.Add($Control, 1, $r)
        if ($Button) { $tl.Controls.Add($Button, 2, $r) }
    }
    $newLabel = {
        param($Text, [switch]$Grey)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text; $l.AutoSize = $true
        if ($Grey) { $l.ForeColor = [System.Drawing.SystemColors]::GrayText }
        return $l
    }
    $mono = New-Object System.Drawing.Font('Consolas', $form.Font.Size)

    $titleBox = New-Object System.Windows.Forms.TextBox
    $titleBox.Text = $v.Title
    $titleBox.ReadOnly = -not $custom
    & $add 'Title' $titleBox

    $programBox = New-Object System.Windows.Forms.TextBox
    $browse = $null
    if ($custom) {
        $programBox.Text = $v.Program
        $browse = New-Object System.Windows.Forms.Button
        $browse.Text = 'Browse...'; $browse.AutoSize = $true
        $browse.Add_Click({
            $picked = Select-PathDialog 'File' $programBox.Text 'Programs (*.exe)|*.exe|All files (*.*)|*.*'
            if ($picked) { $programBox.Text = $picked }
        })
    } else {
        $programBox.Text = if ($Item.Exe) { "$($Item.Tool)  ($($Item.Exe))" } else { "$($Item.Tool)  (not found - set its path on the Tools tab)" }
        $programBox.ReadOnly = $true
    }
    & $add 'Program' $programBox $browse

    $commandBox = New-Object System.Windows.Forms.TextBox
    $commandBox.Font = $mono
    $commandBox.Text = $v.Command
    $reset = $null
    if (-not $custom) {
        $reset = New-Object System.Windows.Forms.Button
        $reset.Text = 'Reset to default'; $reset.AutoSize = $true
        $reset.Add_Click({ $commandBox.Text = $Item.DefaultCommand })
    }
    & $add 'Arguments' $commandBox $reset

    $previewLabel = & $newLabel ''
    $previewLabel.Font = $mono
    $previewLabel.MaximumSize = New-Object System.Drawing.Size(640, 0)
    & $add 'Runs as' $previewLabel

    $help = (Get-ItemVarHelp $Item).GetEnumerator() | ForEach-Object { '{{{0}}}  {1}' -f $_.Key, $_.Value }
    $helpLabel = & $newLabel (($help -join "`n") + "`nPut a placeholder in quotes to insert it as is, e.g. `"{Out}\report`".") -Grey
    $helpLabel.MaximumSize = New-Object System.Drawing.Size(640, 0)
    & $add 'Placeholders' $helpLabel

    if ($custom) {
        $scopePanel = New-Object System.Windows.Forms.FlowLayoutPanel
        $scopePanel.AutoSize = $true
        $fileCheck = New-Object System.Windows.Forms.CheckBox
        $fileCheck.Text = 'Files'; $fileCheck.AutoSize = $true; $fileCheck.Checked = @($v.Scope) -contains 'File'
        $dirCheck = New-Object System.Windows.Forms.CheckBox
        $dirCheck.Text = 'Folders and drives'; $dirCheck.AutoSize = $true; $dirCheck.Checked = @($v.Scope) -contains 'Dir'
        $scopePanel.Controls.AddRange(@($fileCheck, $dirCheck))
        & $add 'Shown on' $scopePanel

        $extBox = New-Object System.Windows.Forms.TextBox;    $extBox.Text = @($v.Ext) -join ', '
        $nameBox = New-Object System.Windows.Forms.TextBox;   $nameBox.Text = @($v.Name) -join ', '
        $prefixBox = New-Object System.Windows.Forms.TextBox; $prefixBox.Text = @($v.Prefix) -join ', '
        & $add 'Extensions' $extBox
        & $add 'File names' $nameBox
        & $add 'Name starts with' $prefixBox
        & $add $null (& $newLabel 'Comma separated, e.g. .foo, .bar. All three empty = shown on every file.' -Grey)

        $sigPanel = New-Object System.Windows.Forms.FlowLayoutPanel
        $sigPanel.AutoSize = $true
        $offsetBox = New-Object System.Windows.Forms.NumericUpDown
        $offsetBox.Maximum = [decimal]::MaxValue; $offsetBox.Width = 90
        $hexBox = New-Object System.Windows.Forms.TextBox
        $hexBox.Width = 260; $hexBox.Font = $mono
        if ($v.Signature) { $offsetBox.Value = [decimal]$v.Signature.Offset; $hexBox.Text = $v.Signature.Hex }
        $sigPanel.Controls.AddRange(@((& $newLabel 'bytes (hex)'), $hexBox, (& $newLabel 'at offset'), $offsetBox))
        & $add 'Signature' $sigPanel
        & $add $null (& $newLabel 'Optional. Checked before the program runs; e.g. 4D5A at offset 0 for an .exe. Empty = not checked.' -Grey)

        $outputCheck = New-Object System.Windows.Forms.CheckBox
        $outputCheck.Text = 'Create a results folder ({Out})'; $outputCheck.AutoSize = $true; $outputCheck.Checked = [bool]$v.Output
        & $add $null $outputCheck
        $waitCheck = New-Object System.Windows.Forms.CheckBox
        $waitCheck.Text = 'Run in the ForensicAid console and wait (untick for programs with their own window)'
        $waitCheck.AutoSize = $true; $waitCheck.Checked = [bool]$v.Wait
        & $add $null $waitCheck
    }

    $updatePreview = {
        $scope = if ($custom) { @($(if ($fileCheck.Checked) { 'File' }), $(if ($dirCheck.Checked) { 'Dir' }) | Where-Object { $_ }) } else { @($Item.Scope) }
        $sampleName = 'Security.evtx'
        if ($custom) {
            $n = @($nameBox.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $e = @($extBox.Text -split ',' | ForEach-Object { $_.Trim().TrimStart('.') } | Where-Object { $_ })
            $sampleName = if ($n.Count) { $n[0] } elseif ($e.Count) { "evidence.$($e[0])" } else { 'evidence.bin' }
            $exe = [IO.Path]::GetFileName($programBox.Text.Trim().Trim('"'))
        } else {
            if (@($Item.Name).Count) { $sampleName = @($Item.Name)[0] }
            elseif (@($Item.Ext).Count) { $sampleName = 'evidence' + @($Item.Ext)[0] }
            $exe = if ($Item.Exe) { [IO.Path]::GetFileName($Item.Exe) } else { "$($Item.Tool).exe" }
        }
        if (-not $scope.Count) { $scope = @('File') }
        $previewLabel.Text = Format-CommandPreview $exe $commandBox.Text $Item $scope $sampleName
    }
    $commandBox.Add_TextChanged($updatePreview)
    if ($custom) {
        foreach ($c in $programBox, $extBox, $nameBox) { $c.Add_TextChanged($updatePreview) }
        foreach ($c in $fileCheck, $dirCheck) { $c.Add_CheckedChanged($updatePreview) }
    }
    & $updatePreview

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Bottom'; $buttons.FlowDirection = 'RightToLeft'; $buttons.AutoSize = $true
    $buttons.Padding = New-Object System.Windows.Forms.Padding(8)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $buttons.Controls.AddRange(@($cancel, $ok))
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    $script:DialogResultDef = $null
    $ok.Add_Click({
        $problems = @()
        $command = $commandBox.Text.Trim()
        if (-not $command -and -not $custom) { $problems += 'The arguments cannot be empty - use Reset to default.' }
        $known = Get-ItemVarHelp $Item
        foreach ($m in [regex]::Matches($command, '\{(\w+)\}')) {
            if (-not $known.Contains($m.Groups[1].Value)) { $problems += "Unknown placeholder {$($m.Groups[1].Value)}." }
        }
        if ($custom) {
            if (-not $titleBox.Text.Trim()) { $problems += 'Give the item a title.' }
            if (-not $programBox.Text.Trim()) { $problems += 'Choose the program to run.' }
            if (-not $fileCheck.Checked -and -not $dirCheck.Checked) { $problems += 'Tick Files and/or Folders.' }
            $hex = $hexBox.Text -replace '[\s-]', ''
            if ($hex -and $hex -notmatch '^([0-9A-Fa-f]{2})+$') { $problems += 'The signature must be pairs of hex digits, e.g. 4D5A.' }
        }
        if ($problems.Count) {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, ($problems -join "`n"), $dlg.Text, 'OK', 'Warning')
            return
        }
        if ($custom) {
            $split = { param($t) @($t -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            $script:DialogResultDef = @{
                Title = $titleBox.Text.Trim(); Program = $programBox.Text.Trim().Trim('"'); Command = $command
                Scope = @($(if ($fileCheck.Checked) { 'File' }), $(if ($dirCheck.Checked) { 'Dir' }) | Where-Object { $_ })
                Ext = @(& $split $extBox.Text); Name = @(& $split $nameBox.Text); Prefix = @(& $split $prefixBox.Text)
                Signature = $(if ($hex) { @{ Offset = [int64]$offsetBox.Value; Hex = $hex.ToUpperInvariant() } } else { $null })
                Output = $outputCheck.Checked; Wait = $waitCheck.Checked
            }
        } else {
            $script:DialogResultDef = @{ Command = $command }
        }
        $dlg.DialogResult = 'OK'
    })

    # Spare height goes to an empty last row, not to the last field.
    $tl.RowCount++
    [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    $dlg.Add_Shown({ if ($isNew) { [void]$titleBox.Focus() } else { [void]$commandBox.Focus() } })

    $dlg.Controls.Add($tl)
    $dlg.Controls.Add($buttons)
    try {
        if ($dlg.ShowDialog($form) -ne 'OK') { return $null }
        return $script:DialogResultDef
    } finally { $dlg.Dispose() }
}

function Edit-Item($Row) {
    $item = $Row.Tag
    if (-not (Get-ItemView $item).Command) { return }
    $def = Show-ItemDialog $item
    if ($null -eq $def) { return }
    if ($item.Custom) {
        $script:ItemDrafts[$item.Id] = $def
    } elseif ($def.Command -ceq $item.Command) {
        $script:ItemDrafts.Remove($item.Id)          # back to what is saved
    } elseif ($def.Command -ceq $item.DefaultCommand) {
        $script:ItemDrafts[$item.Id] = $null         # default again: drop the override file
    } else {
        $script:ItemDrafts[$item.Id] = $def
    }
    Update-ItemRow $Row
}

function Add-Item {
    $def = Show-ItemDialog $null
    if ($null -eq $def) { return }
    $id = New-ItemId $def.Title
    $item = [pscustomobject]@{ Id = $id; Title = $def.Title; Group = 7; Custom = $true; New = $true; Enabled = $true
                               Tool = ''; Exe = ''; Vars = $null; DefaultCommand = '' }
    foreach ($k in 'Program', 'Command', 'Scope', 'Ext', 'Name', 'Prefix', 'Signature', 'Output', 'Wait') { $item | Add-Member -NotePropertyName $k -NotePropertyValue $def[$k] }
    $script:ItemDrafts[$id] = $def
    # Before the items that manage ForensicAid itself, like the menu will show it.
    $at = @($script:ItemGrid.Rows | Where-Object { $_.Tag.Group -ge 9 } | Select-Object -First 1)
    $index = if ($at.Count) { $at[0].Index } else { $script:ItemGrid.Rows.Count }
    $script:ItemGrid.Rows.Insert($index, @($true, '', '', '', ''))
    $row = $script:ItemGrid.Rows[$index]
    $row.Tag = $item
    Update-ItemRow $row
    $script:ItemGrid.CurrentCell = $row.Cells['Item']
}

function Remove-CustomItem {
    $row = $script:ItemGrid.CurrentRow
    if (-not $row) { return }
    $item = $row.Tag
    if (-not $item.Custom) { [void](Show-Message 'Built-in items cannot be deleted - untick them to hide them from the menu.'); return }
    if ((Show-Message "Delete '$((Get-ItemView $item).Title)'?" 'YesNo' 'Question') -ne 'Yes') { return }
    if ($item.New) { $script:ItemDrafts.Remove($item.Id) } else { $script:ItemDrafts[$item.Id] = $null }
    $script:ItemGrid.Rows.Remove($row)
}

#endregion

#region UI

$script:Form = New-Object System.Windows.Forms.Form
$form = $script:Form
$form.Text = $WindowTitle
$form.Font = [System.Drawing.SystemFonts]::MessageBoxFont
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(900, 640)
$form.MinimumSize = New-Object System.Drawing.Size(640, 480)
try { if ([IO.File]::Exists($IconFile)) { $form.Icon = New-Object System.Drawing.Icon($IconFile) } } catch { }

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'

# --- Tools tab ---------------------------------------------------------------

$toolsTab = New-Object System.Windows.Forms.TabPage('Tools')
$toolsTab.Padding = New-Object System.Windows.Forms.Padding(8)

$toolsHint = New-Object System.Windows.Forms.Label
$toolsHint.Text = 'Leave a path empty to have the tool found automatically in the tool folders (General tab).'
$toolsHint.Dock = 'Top'
$toolsHint.AutoSize = $false
$toolsHint.Height = 24

$script:Grid = New-Object System.Windows.Forms.DataGridView
$grid = $script:Grid
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'CellSelect'
$grid.EditMode = 'EditOnEnter'
$grid.BackgroundColor = [System.Drawing.SystemColors]::Window
$grid.AutoSizeRowsMode = 'AllCells'

$col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$col.Name = 'Tool'; $col.HeaderText = 'Tool'; $col.ReadOnly = $true; $col.Width = 150
[void]$grid.Columns.Add($col)
$col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$col.Name = 'Path'; $col.HeaderText = 'Path (empty = automatic)'; $col.AutoSizeMode = 'Fill'; $col.FillWeight = 55
[void]$grid.Columns.Add($col)
$col = New-Object System.Windows.Forms.DataGridViewButtonColumn
$col.Name = 'Browse'; $col.HeaderText = ''; $col.Text = '...'; $col.UseColumnTextForButtonValue = $true; $col.Width = 32
[void]$grid.Columns.Add($col)
$col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$col.Name = 'Version'; $col.HeaderText = 'Version'; $col.ReadOnly = $true; $col.Width = 90
[void]$grid.Columns.Add($col)
$col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$col.Name = 'Status'; $col.HeaderText = 'Status'; $col.ReadOnly = $true; $col.AutoSizeMode = 'Fill'; $col.FillWeight = 45
[void]$grid.Columns.Add($col)

$grid.Add_CellEndEdit({
    try { if ($_.ColumnIndex -eq $grid.Columns['Path'].Index) { Update-ToolRow $grid.Rows[$_.RowIndex] } } catch { Set-Status $_.Exception.Message 'Error' }
})
$grid.Add_CellContentClick({
    try {
        if ($_.RowIndex -lt 0 -or $_.ColumnIndex -ne $grid.Columns['Browse'].Index) { return }
        $row = $grid.Rows[$_.RowIndex]
        $current = [string]$row.Cells['Path'].Value
        if (-not $current) { $current = [string]$row.Tag.Resolved }
        $picked = Select-PathDialog 'File' $current 'Programs (*.exe)|*.exe|All files (*.*)|*.*'
        if ($picked) { $row.Cells['Path'].Value = $picked; Update-ToolRow $row }
    } catch { Set-Status $_.Exception.Message 'Error' }
})

$toolButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$toolButtons.Dock = 'Bottom'
$toolButtons.AutoSize = $true
$toolButtons.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$script:ScanButton = New-Object System.Windows.Forms.Button
$script:ScanButton.Text = 'Find tools on this PC'
$script:ScanButton.AutoSize = $true
$script:ScanButton.Enabled = $false
$script:ScanButton.Add_Click({ try { Start-ToolScan } catch { Set-Status $_.Exception.Message 'Error' } })
$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = 'Clear path (automatic)'
$clearButton.AutoSize = $true
$clearButton.Add_Click({
    try {
        if ($grid.CurrentRow) { $grid.CurrentRow.Cells['Path'].Value = ''; Update-ToolRow $grid.CurrentRow }
    } catch { Set-Status $_.Exception.Message 'Error' }
})
$toolButtons.Controls.AddRange(@($script:ScanButton, $clearButton))

$toolsTab.Controls.Add($grid)
$toolsTab.Controls.Add($toolButtons)
$toolsTab.Controls.Add($toolsHint)

# --- General tab -------------------------------------------------------------

$generalTab = New-Object System.Windows.Forms.TabPage('General')
$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.AutoScroll = $true
$layout.Padding = New-Object System.Windows.Forms.Padding(10, 6, 24, 10)
$layout.ColumnCount = 3
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
$generalTab.Controls.Add($layout)

function Add-Row($Label, $Control, $Button) {
    $r = $layout.RowCount
    $layout.RowCount++
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
    if ($Label) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Label
        $l.AutoSize = $true
        $l.Anchor = 'Left'
        $layout.Controls.Add($l, 0, $r)
    }
    $Control.Anchor = 'Left, Right'
    $layout.Controls.Add($Control, 1, $r)
    if ($Button) { $layout.Controls.Add($Button, 2, $r) }
}

function Add-Heading([string]$Text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $true
    $l.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 14, 0, 4)
    $r = $layout.RowCount
    $layout.RowCount++
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
    $layout.Controls.Add($l, 0, $r)
    $layout.SetColumnSpan($l, 3)
}

function New-Note {
    $n = New-Object System.Windows.Forms.Label
    $n.AutoSize = $true
    $n.ForeColor = [System.Drawing.SystemColors]::GrayText
    $n.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 6)
    Add-Row $null $n
    return $n
}

# A setting shown on this tab. Get/Set move the value between the control and the config's form.
function Register-Field([string]$Name, [scriptblock]$Get, [scriptblock]$Set, [string]$Section, [switch]$List, [string]$InUse, $Note) {
    $script:Fields["$Section.$Name"] = @{ Name = $Name; Section = $Section; Get = $Get; Set = $Set; List = [bool]$List
                                         InUse = $InUse; Note = $Note; Original = $null }
}

function Add-Choice([string]$Name, [string]$Label, [System.Collections.Specialized.OrderedDictionary]$Choices) {
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    foreach ($text in $Choices.Values) { [void]$combo.Items.Add($text) }
    Add-Row $Label $combo
    $keys = @($Choices.Keys)
    Register-Field $Name { $keys[$combo.SelectedIndex] }.GetNewClosure() {
        param($v)
        $i = [array]::IndexOf($keys, [string]$v)
        $combo.SelectedIndex = [Math]::Max(0, $i)
    }.GetNewClosure()
}

function Add-Check([string]$Name, [string]$Text) {
    $check = New-Object System.Windows.Forms.CheckBox
    $check.Text = $Text
    $check.AutoSize = $true
    Add-Row $null $check
    Register-Field $Name { $check.Checked }.GetNewClosure() { param($v) $check.Checked = [bool]$v }.GetNewClosure()
}

function Add-PathField([string]$Name, [string]$Label, [string]$Kind, [string]$Section, [string]$Filter, [string]$InUse) {
    $box = New-Object System.Windows.Forms.TextBox
    $button = New-Object System.Windows.Forms.Button
    $button.Text = 'Browse...'
    $button.AutoSize = $true
    # No GetNewClosure here: a closure cannot see this script's functions, so the handler reads $this.Tag.
    $button.Tag = @{ Box = $box; Kind = $Kind; Filter = $(if ($Filter) { $Filter } else { 'All files (*.*)|*.*' }) }
    $button.Add_Click({
        $t = $this.Tag
        $picked = Select-PathDialog $t.Kind $t.Box.Text $t.Filter
        if ($picked) { $t.Box.Text = $picked }
    })
    Add-Row $Label $box $button
    $note = if ($InUse) { New-Note } else { $null }
    Register-Field $Name { $box.Text.Trim().Trim('"') }.GetNewClosure() { param($v) $box.Text = [string]$v }.GetNewClosure() $Section -InUse $InUse -Note $note
}

Add-Heading 'Results'
Add-Choice 'OutputMode' 'Results go' ([ordered]@{
    NextToEvidence = 'Next to the evidence (in a ForensicAid folder beside it)'
    OutputRoot     = 'Always in the output folder below'
    EvidenceFolder = 'In the evidence folder itself (mixed with the evidence; a new run overwrites the last)'
})
Add-PathField 'OutputRoot' 'Output folder' 'Folder'
$n = New-Note
$n.Text = 'Also used when the evidence sits somewhere read-only.'
Add-Check 'OpenOutputFolder' 'Open the results folder when an action finishes'
Add-Choice 'PauseOnExit' 'Keep the console open' ([ordered]@{
    Always  = 'Always'
    OnError = 'Only after errors'
    Never   = 'Never'
})

Add-Heading 'Explorer menu'
Add-Check 'FilterByFileType' 'Show file items only for matching files (e.g. Amcache only on Amcache.hve)'
Add-Check 'HideUnavailable' 'Hide items whose tool was not found'
Add-Check 'Win11Menu' 'Windows 11: show ForensicAid in the top-level menu, not only under "Show more options"'
Add-Check 'EnableLogging' 'Keep a history of runs (history.log in the install folder)'

Add-Heading 'Tool folders'
$rootsBox = New-Object System.Windows.Forms.TextBox
$rootsBox.Multiline = $true
$rootsBox.ScrollBars = 'Vertical'
$rootsBox.Height = 80
$rootsButton = New-Object System.Windows.Forms.Button
$rootsButton.Text = 'Add folder...'
$rootsButton.AutoSize = $true
$rootsButton.Anchor = 'Top'
$rootsButton.Add_Click({
    $picked = Select-PathDialog 'Folder' ''
    if ($picked) { $rootsBox.Text = (@($rootsBox.Lines | Where-Object { $_.Trim() }) + $picked) -join "`r`n" }
})
Add-Row 'Search in' $rootsBox $rootsButton
Register-Field 'ToolRoots' { @($rootsBox.Lines | ForEach-Object { $_.Trim().Trim('"') }) } { param($v) $rootsBox.Text = @($v) -join "`r`n" } -List
$n = New-Note
$n.Text = 'One folder per line, subfolders included. Tools with an empty path are looked for here.'

Add-Heading 'Rules'
Add-PathField 'SigmaRules' 'Chainsaw Sigma rules' 'Folder' 'Chainsaw' -InUse 'SigmaRules'
Add-PathField 'Mapping' 'Chainsaw mapping' 'File' 'Chainsaw' 'Chainsaw mapping (*.yml)|*.yml|All files (*.*)|*.*' -InUse 'Mapping'
Add-PathField 'Rules' 'Chainsaw rules' 'Folder' 'Chainsaw' -InUse 'Rules'
Add-PathField 'RECmdBatch' 'RECmd batch file' 'File' '' 'RECmd batch (*.reb)|*.reb|All files (*.*)|*.*' -InUse 'RECmdBatch'

# --- Menu items tab ----------------------------------------------------------

$itemsTab = New-Object System.Windows.Forms.TabPage('Menu items')
$itemsTab.Padding = New-Object System.Windows.Forms.Padding(8)
$script:BoldFont = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)

$itemsHint = New-Object System.Windows.Forms.Label
$itemsHint.Text = 'Untick an item to hide it. Edit... changes the arguments its program is run with (changed ones are bold). Add... puts your own program in the menu.'
$itemsHint.Dock = 'Top'
$itemsHint.AutoSize = $false
$itemsHint.Height = 24

$script:ItemErrors = New-Object System.Windows.Forms.Label
$script:ItemErrors.Dock = 'Top'
$script:ItemErrors.AutoSize = $true
$script:ItemErrors.ForeColor = [System.Drawing.Color]::Firebrick
$script:ItemErrors.Visible = $false

$script:ItemGrid = New-Object System.Windows.Forms.DataGridView
$itemGrid = $script:ItemGrid
$itemGrid.Dock = 'Fill'
$itemGrid.AllowUserToAddRows = $false
$itemGrid.AllowUserToDeleteRows = $false
$itemGrid.AllowUserToResizeRows = $false
$itemGrid.RowHeadersVisible = $false
$itemGrid.SelectionMode = 'FullRowSelect'
$itemGrid.MultiSelect = $false
$itemGrid.BackgroundColor = [System.Drawing.SystemColors]::Window

$col = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$col.Name = 'On'; $col.HeaderText = 'On'; $col.Width = 36
[void]$itemGrid.Columns.Add($col)
foreach ($spec in @(@('Item', 'Menu item', 34), @('Program', 'Program', 18), @('Command', 'Arguments', 48))) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $spec[0]; $col.HeaderText = $spec[1]; $col.ReadOnly = $true; $col.AutoSizeMode = 'Fill'; $col.FillWeight = $spec[2]
    [void]$itemGrid.Columns.Add($col)
}
$col = New-Object System.Windows.Forms.DataGridViewButtonColumn
$col.Name = 'Edit'; $col.HeaderText = ''; $col.Width = 70
[void]$itemGrid.Columns.Add($col)

$itemGrid.Add_CellContentClick({
    try {
        if ($_.RowIndex -lt 0) { return }
        if ($_.ColumnIndex -eq $itemGrid.Columns['Edit'].Index) { Edit-Item $itemGrid.Rows[$_.RowIndex] }
        # Commit the tick at once, so Save and the close prompt see it.
        if ($_.ColumnIndex -eq $itemGrid.Columns['On'].Index) { [void]$itemGrid.CommitEdit('CurrentCellChange') }
    } catch { Set-Status $_.Exception.Message 'Error' }
})
$itemGrid.Add_CellDoubleClick({
    try { if ($_.RowIndex -ge 0 -and $_.ColumnIndex -ne $itemGrid.Columns['On'].Index) { Edit-Item $itemGrid.Rows[$_.RowIndex] } } catch { Set-Status $_.Exception.Message 'Error' }
})

$itemButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$itemButtons.Dock = 'Bottom'
$itemButtons.AutoSize = $true
$itemButtons.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
foreach ($spec in @(@('&Add...', { Add-Item }), @('&Edit...', { if ($itemGrid.CurrentRow) { Edit-Item $itemGrid.CurrentRow } }), @('&Delete', { Remove-CustomItem }))) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $spec[0]
    $b.AutoSize = $true
    $b.Tag = $spec[1]
    $b.Add_Click({ try { & $this.Tag } catch { Set-Status $_.Exception.Message 'Error' } })
    $itemButtons.Controls.Add($b)
}
$folderLink = New-Object System.Windows.Forms.LinkLabel
$folderLink.Text = 'Open the items folder (to share an item, copy its file)'
$folderLink.AutoSize = $true
$folderLink.Margin = New-Object System.Windows.Forms.Padding(12, 9, 3, 3)
$folderLink.Add_LinkClicked({
    try {
        $dir = if ($script:Info) { $script:Info.ActionsDir } else { Join-Path $InstallDir 'actions' }
        [void][IO.Directory]::CreateDirectory($dir)
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $dir)
    } catch { Set-Status $_.Exception.Message 'Error' }
})
$itemButtons.Controls.Add($folderLink)

$itemsTab.Controls.Add($itemGrid)
$itemsTab.Controls.Add($itemButtons)
$itemsTab.Controls.Add($script:ItemErrors)
$itemsTab.Controls.Add($itemsHint)

[void]$tabs.TabPages.Add($generalTab)
[void]$tabs.TabPages.Add($toolsTab)
[void]$tabs.TabPages.Add($itemsTab)

# --- Bottom bar --------------------------------------------------------------

$bar = New-Object System.Windows.Forms.TableLayoutPanel
$bar.Dock = 'Bottom'
$bar.AutoSize = $true
$bar.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 8)
$bar.ColumnCount = 4
[void]$bar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$bar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$bar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$bar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))

$fileLink = New-Object System.Windows.Forms.LinkLabel
$fileLink.Text = 'Edit the config file'
$fileLink.AutoSize = $true
$fileLink.Anchor = 'Left'
$fileLink.Add_LinkClicked({ try { Open-ConfigFile } catch { Set-Status $_.Exception.Message 'Error' } })

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.AutoSize = $true
$script:StatusLabel.Anchor = 'Left'
$script:StatusLabel.Margin = New-Object System.Windows.Forms.Padding(12, 0, 3, 0)

$script:SaveButton = New-Object System.Windows.Forms.Button
$script:SaveButton.Text = '&Save'
$script:SaveButton.Enabled = $false
$script:SaveButton.Add_Click({ try { Save-Settings } catch { Set-Status $_.Exception.Message 'Error' } })
$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = '&Close'
$closeButton.Add_Click({ $form.Close() })

$bar.Controls.Add($fileLink, 0, 0)
$bar.Controls.Add($script:StatusLabel, 1, 0)
$bar.Controls.Add($script:SaveButton, 2, 0)
$bar.Controls.Add($closeButton, 3, 0)

$form.Controls.Add($tabs)
$form.Controls.Add($bar)

$form.Add_FormClosing({
    if ($script:Closing) { return }
    try {
        if ((Get-Changes).Count) {
            $answer = Show-Message 'Save your changes?' 'YesNoCancel' 'Question'
            if ($answer -eq 'Cancel') { $_.Cancel = $true; return }
            if ($answer -eq 'Yes') {
                $_.Cancel = $true
                Save-Settings { $script:Closing = $true; $form.Close() }
            }
        }
    } catch { }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({ try { Invoke-Tick } catch { Set-Busy $false; Set-Status $_.Exception.Message 'Error' } })

#endregion

#region Main

try {
    $form.Add_Shown({
        # Started with -WindowStyle Hidden, Windows applies SW_HIDE to the first window shown;
        # hiding and showing again is a second ShowWindow, which it honours.
        $form.Hide(); $form.Show(); $form.Activate()
        $timer.Start()
        Import-Settings
    })
    [System.Windows.Forms.Application]::Run($form)
} finally {
    $timer.Stop()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

#endregion
