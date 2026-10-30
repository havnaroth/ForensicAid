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
| RDP bitmap cache | `Cache000?.bin`, `bcache*.bmc`, folder | built-in: every tile as PNG + a collage per cache file |
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

Uninstall with `uninstall.cmd`. It removes the menu, the tray icon and its autostart. Your config and history are kept.

### Windows 11 top-level menu

Windows 11 shows classic menu entries only under **Show more options**. To put **ForensicAid** in the new top-level menu, ForensicAid includes a native shell extension in `win11/`. It is a C++ `IExplorerCommand` DLL registered through a signed sparse package. It has no logic of its own: it reads `menu.json`, which `Register-Menu` writes, so tray toggles apply to both menus.

1. Build it once with `win11\build.ps1`. This needs Visual Studio with the C++ workload and the Windows SDK. The script creates a self-signed `CN=ForensicAid` certificate in your user store and signs the package with it.
2. Run `install.cmd`. On Windows 11 it also:
   - copies the DLL;
   - asks for one UAC confirmation so the certificate is trusted (`LocalMachine\TrustedPeople`);
   - registers the package and offers to restart Explorer.
   If you refuse UAC, only the classic menu is installed.

Windows does not allow new-menu entries on drive icons, so a right-click on a drive itself still uses **Show more options**. Folders and files on that drive get the new menu. Set `Win11Menu = $false` in the config to skip all this. `uninstall.cmd` removes the package. The certificate stays trusted until you delete it in `certlm.msc` under *Trusted People*.

To test the DLL without installing it, run `win11\test\Test-Harness.ps1`.

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

- KAPE integration.
- RDP cache: decoding RLE-compressed tiles of old `bcache2x.bmc` files (currently counted and skipped).

**No guarantees.** Use it on your own responsibility, and work on copies of evidence when in doubt.
