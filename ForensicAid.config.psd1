# ForensicAid configuration (PowerShell data file - use single quotes for paths).
# After editing use  ForensicAid > Refresh menu  (or run install.cmd again).
# %VARIABLES% such as %USERPROFILE% are expanded.
@{
    # Folders searched recursively for tool executables - e.g. the folder you ran
    # Get-ZimmermanTools.ps1 into, and the folder with chainsaw / qemu-img.
    ToolRoots = @(
        'C:\Tools'
        '%USERPROFILE%\Desktop'
    )

    # Explicit executable paths. Leave empty to auto-discover under ToolRoots / PATH.
    Tools = @{
        AmcacheParser        = ''
        AppCompatCacheParser = ''
        EvtxECmd             = ''
        JLECmd               = ''
        LECmd                = ''
        MFTECmd              = ''
        PECmd                = ''
        RBCmd                = ''
        RECmd                = ''
        SBECmd               = ''
        SrumECmd             = ''
        SumECmd              = ''
        WxTCmd               = ''
        TimelineExplorer     = ''
        Chainsaw             = ''
        QemuImg              = ''
    }

    Chainsaw = @{
        SigmaRules = ''    # Sigma rules folder (e.g. a SigmaHQ clone\rules). Empty = <chainsaw>\sigma if present
        Mapping    = ''    # Empty = <chainsaw>\mappings\sigma-event-logs-all.yml
        Rules      = ''    # Chainsaw rules. Empty = <chainsaw>\rules
        ExtraArgs  = @('--skip-errors')
    }

    # RECmd batch file. Empty = RECmd\BatchExamples\Kroll_Batch.reb (or DFIRBatch.reb)
    RECmdBatch = ''

    # NextToEvidence: <evidence folder>\ForensicAid\<timestamp>_<action>_<name>
    #                 (falls back to OutputRoot when that location is read-only, e.g. a mounted image)
    # OutputRoot:     always write under OutputRoot
    # EvidenceFolder: straight into the evidence's own folder, mixed with the evidence; a new run
    #                 overwrites the last one (falls back to OutputRoot when the folder is read-only)
    OutputMode = 'NextToEvidence'
    OutputRoot = '%USERPROFILE%\ForensicAid_Output'

    OpenOutputFolder = $true       # open results in Explorer when an action finishes
    PauseOnExit      = 'Always'    # Always | OnError | Never
    FilterByFileType = $true       # file items only show for matching files (e.g. Amcache only on Amcache.hve)
    HideUnavailable  = $true       # hide items whose tool was not found
    Disabled         = @()         # action ids to hide, e.g. @('to-raw', 'triage')
    EnableLogging    = $true       # history.log in the install folder
    Win11Menu        = $true       # Windows 11: also add ForensicAid to the top-level menu (needs win11\build.ps1 output)
}
