# ForensicAid

Right-click DFIR evidence in Explorer and parse it with the right tool, with no copy-pasting of command lines.
ForensicAid adds a **ForensicAid** submenu for files, folders, drives and folder backgrounds, plus a tray icon to manage it.
It wraps [Eric Zimmerman's tools](https://ericzimmerman.github.io), [Chainsaw](https://github.com/WithSecureLabs/chainsaw), `esentutl` and `qemu-img`.

Author: Mateusz Nowicki aka Hannon. Version 1.0.0.

![Sample](sample.jpg)

## What it does

| Menu item | Shown on | Tool |
|---|---|---|
| Hash (MD5/SHA1/SHA256) | any file (SHA256 copied to the clipboard); folder: `hashes.csv` of every file | built-in |
| Open in Timeline Explorer | `.csv`, `.xlsx` | TimelineExplorer |
| Full triage (all parsers) | folder or drive, e.g. a KAPE output or a mounted image | everything below that applies |
| Event logs: Chainsaw hunt | `.evtx`, folder | Chainsaw v2 (Sigma + Chainsaw rules) |
| Event logs: EvtxECmd | `.evtx`, folder | EvtxECmd |
| NTFS | `$MFT`, `$J`, `$Boot`, `$SDS`, `$I30` (`$J` resolves paths through a `$MFT` found nearby) | MFTECmd |
| Prefetch / LNK / Jump lists / Recycle Bin | `.pf`, `.lnk`, `*Destinations-ms`, `$I*`, folder | PECmd / LECmd / JLECmd / RBCmd |
| Amcache / ShimCache | `Amcache.hve` / `SYSTEM` | AmcacheParser / AppCompatCacheParser |
| Registry (batch) | hives, folder | RECmd with `Kroll_Batch.reb` |
| ShellBags | folder | SBECmd |
| SRUM / UAL / Windows Timeline | `SRUDB.dat` / `*.mdb` / `ActivitiesCache.db`, folder | SrumECmd / SumECmd / WxTCmd |
| Repair ESE database (copy) | `.edb`, `.mdb`, `SRUDB.dat`, `WebCacheV*.dat` | esentutl |
| Disk image to RAW (.dd) | `.vhdx`, `.vhd`, `.vmdk`, `.qcow2`, `.vdi` | qemu-img |
| Check tools / Edit configuration / Refresh menu | everywhere | built-in |

File items only show for matching files. Items whose tool was not found are hidden.

**Evidence is never modified:**
- ESE databases (SRUM, UAL) and `ActivitiesCache.db` are always copied, together with their transaction logs or `-wal` files, and parsed from the copy.
- A dirty ESE database first gets a log replay (`esentutl /r`). Only if that fails does the copy get a hard repair (`esentutl /p`).
- A dirty registry hive with no `.LOG1`/`.LOG2` next to it is detected and parsed with `--nl`, and you get a warning.

**Results** go to `<folder of the evidence>\ForensicAid\<timestamp>_<action>_<name>\`, together with `ForensicAid.log`, which records the commands, exit codes and times. When that location is read-only (for example a mounted image), results go to `OutputRoot` instead. Every run is also appended to `history.log` in the install folder.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1, which is built in. Python is not needed.
- The tools themselves. The easiest way to get the EZ tools is `Get-ZimmermanTools.ps1`, run into e.g. `C:\Tools\EZ`. For Chainsaw use **v2**, plus a Sigma rules folder if you want Sigma.

## Install

1. Clone the repository and run `install.cmd`. No administrator rights are needed.
2. If an older ForensicAid menu or the Python *DFIR Toolbox* (`setup.py`) is still registered, the installer lists what it found and asks for permission to remove it. Removing it is required for this version.
   - If you answer *no*, nothing is changed.
   - If you answer *yes*, everything is first backed up (`.reg` exports and file copies) to `%LOCALAPPDATA%\ForensicAid\legacy_backup\`.
   - Machine-wide leftovers (HKLM, `C:\ProgramData\DFIR_Toolbox`) need one UAC confirmation.
3. The installer copies the files to `%LOCALAPPDATA%\ForensicAid`, finds your tools, registers the menu and starts the tray icon.
4. If tools are missing, open **Edit configuration**, either from the tray or the menu. Add your tool folders to `ToolRoots`, or set exact paths under `Tools`, then use **Refresh menu**.

On Windows 11 the menu is under **Show more options** (or Shift+right-click). Getting it into the new top-level menu needs a packaged shell extension, which is planned.

Uninstall with `uninstall.cmd`. It removes the menu, the tray icon and its autostart. Your config and history are kept.

## Tray icon

The icon next to the clock gives you:
- **Context menu items**: tick or untick each item and the Explorer menu is updated in the background. These choices are stored in `menu.state.json`, so your config file is never rewritten.
- **Run action...**: run any action on a file or folder picked in a dialog.
- **Check tools**, **Edit configuration**, **Refresh menu**.
- Open the last results, the output folder, the history log or the install folder.
- **Start with Windows**.

Double-click the icon to open the last results.

## Configuration

`%LOCALAPPDATA%\ForensicAid\ForensicAid.config.psd1` is a commented PowerShell data file. The main settings:

- `ToolRoots`: folders searched recursively for the tools. When several copies are found, the newest version wins.
- `Tools`: explicit executable paths.
- `Chainsaw`: Sigma rules, mapping file and rules. Empty values use the standard layout next to `chainsaw.exe`.
- `RECmdBatch`: the RECmd batch file to use.
- `OutputMode` / `OutputRoot`: where results go.
- `PauseOnExit`, `OpenOutputFolder`, `FilterByFileType`, `HideUnavailable`, `Disabled`.

## Command line

```powershell
.\ForensicAid.ps1 -Action triage -Path 'E:\KAPE\C'   # any action id: hash, chainsaw, mft, registry, srum, ...
.\ForensicAid.ps1 -Action doctor                     # which tools were found
.\ForensicAid.ps1 -Install [-ResetConfig] [-Yes]     # -Yes = remove old versions without asking
.\ForensicAid.ps1 -Uninstall
```

## Planned

- Windows 11 top-level context menu (`IExplorerCommand` sparse package).
- KAPE integration, RDP bitmap cache parser.

**No guarantees.** Use it on your own responsibility, and work on copies of evidence when in doubt.
