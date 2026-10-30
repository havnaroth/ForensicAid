# ForensicAid

Right-click a piece of evidence in Explorer and parse it with the right tool, with no command lines to type.

ForensicAid adds a **ForensicAid** submenu for files, folders and folder backgrounds. On Windows 11 it appears in the top-level menu; drive icons keep it under *Show more options*. A tray icon lets you choose which items the menu shows.
It wraps [Eric Zimmerman's tools](https://ericzimmerman.github.io), [Chainsaw](https://github.com/WithSecureLabs/chainsaw), `esentutl` and `qemu-img`, and has its own hashing and RDP bitmap cache parsing.

Author: Mateusz Nowicki aka Hannon. Version 1.0.0.

## Features

| Menu item | Shown on | Uses |
|---|---|---|
| Hash (MD5/SHA1/SHA256) | any file (SHA256 copied to the clipboard), folder (`hashes.csv` of every file) | built-in |
| Open in Timeline Explorer | `.csv`, `.xlsx` | Timeline Explorer |
| Full triage (all parsers) | folder or drive, e.g. KAPE output or a mounted image | every parser below that applies |
| Event logs: Chainsaw hunt | `.evtx`, folder | Chainsaw v2 (Sigma + Chainsaw rules) |
| Event logs: EvtxECmd | `.evtx`, folder | EvtxECmd |
| NTFS | `$MFT`, `$J`, `$Boot`, `$SDS`, `$I30` (`$J` resolves paths through a `$MFT` found nearby) | MFTECmd |
| Prefetch / LNK / Jump lists / Recycle Bin | `.pf`, `.lnk`, `*Destinations-ms`, `$I*`, folder | PECmd / LECmd / JLECmd / RBCmd |
| RDP bitmap cache | `Cache000?.bin`, `bcache*.bmc`, folder | built-in: every tile as PNG + a collage per cache file |
| Amcache / ShimCache | `Amcache.hve` / `SYSTEM` | AmcacheParser / AppCompatCacheParser |
| Registry (batch) | hives, folder | RECmd + `Kroll_Batch.reb` |
| ShellBags | folder | SBECmd |
| SRUM / UAL / Windows Timeline | `SRUDB.dat` / `*.mdb` / `ActivitiesCache.db`, folder | SrumECmd / SumECmd / WxTCmd |
| Repair ESE database (copy) | `.edb`, `.mdb`, `SRUDB.dat`, `WebCacheV*.dat` | esentutl |
| Disk image to RAW (.dd) | `.vhdx`, `.vhd`, `.vmdk`, `.qcow2`, `.vdi` | qemu-img |
| Check tools / Edit configuration / Refresh menu | everywhere | built-in |

File items only show for matching files. Items whose tool was not found are hidden. The menu works on one item at a time.

### Evidence handling

- **Evidence is never modified.** ESE databases (SRUM, UAL) and `ActivitiesCache.db` are copied with their transaction logs or `-wal` files, and only the copy is parsed.
  - A dirty database first gets a log replay (`esentutl /r`).
  - Only if that fails does the copy get a hard repair (`esentutl /p`).
- **Dirty registry hives** with no `.LOG1`/`.LOG2` next to them are detected and parsed with `--nl`, and you get a warning. This works for single hives and for folders.
- **Results** go to `<evidence folder>\ForensicAid\<timestamp>_<action>_<name>\` together with `ForensicAid.log`, which records every command, exit code and duration.
  - If that location is read-only, for example a mounted image, results go to `OutputRoot`.
  - Our own output folders are skipped when a folder is scanned again.
- **Full triage** indexes the folder once and runs every parser that applies, each into its own subfolder. It ends with `triage_summary.csv`. A step is marked as a warning when its tool exits with an error or produces no CSV, because most EZ tool versions exit with 0 even when they fail.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1, which is built in. Python is not needed.
- The tools you want to use:
  - EZ tools: the easiest way is `Get-ZimmermanTools.ps1`, run into e.g. `C:\Tools\EZ`;
  - Chainsaw **v2**, plus a Sigma rules folder if you want Sigma;
  - Timeline Explorer;
  - `qemu-img`.

  Anything missing just hides its menu item.
- For the Windows 11 top-level menu only, you also need Visual Studio with the C++ workload and the Windows 10/11 SDK. They are only used to build it once.

## Install

1. Clone the repository.
2. **Windows 11 only, optional:** build the top-level menu with `powershell -ExecutionPolicy Bypass -File win11\build.ps1`. The build output is not stored in the repository, so do this on a machine with Visual Studio. Copy `win11\dist` to other machines.
3. Run `install.cmd` as your normal user, not as administrator. The installer:
   1. **Older versions:** looks for older ForensicAid menus and the Python *DFIR Toolbox* (`setup.py`).
      - If it finds any, it lists them and asks for permission to remove them. Removing them is required.
      - If you answer *no*, nothing is changed.
      - If you answer *yes*, everything is first backed up (`.reg` exports and file copies) to `%LOCALAPPDATA%\ForensicAid\legacy_backup\`.
      - Machine-wide leftovers (HKLM, `C:\ProgramData\DFIR_Toolbox`) need a UAC confirmation.
   2. **Files and menu:** copies its files to `%LOCALAPPDATA%\ForensicAid`, finds your tools and registers the menu for your user only.
   3. **Windows 11 menu:** if `win11\dist` exists, copies the shell extension and asks for a UAC confirmation once, so the package certificate is trusted. It then registers or updates the package and offers to restart Explorer.
   4. **Tray icon:** starts it and adds it to autostart.
4. If tools are missing, open **Edit configuration** from the tray or the menu. Add your tool folders to `ToolRoots`, or set exact paths under `Tools`, then use **Refresh menu**.

Run `install.cmd` again after pulling a new version. It keeps your config and only changes what changed.

**Uninstall:** run `uninstall.cmd`. It removes the menu, the Windows 11 package, the tray icon and its autostart. Your config, history and backups stay in `%LOCALAPPDATA%\ForensicAid`.

## Windows 11 top-level menu

Windows 11 shows classic menu entries only under *Show more options*. To appear in the top-level menu, an entry must come from a packaged shell extension. `win11/` contains one:
- a small C++ `IExplorerCommand` DLL, registered through a signed sparse package;
- the package points at the DLL in `%LOCALAPPDATA%\ForensicAid`.

The DLL has no logic of its own. It reads `menu.json`, which ForensicAid writes every time the menu is registered. Items, file filters, icons and tray toggles are therefore the same in both menus.

- **Certificate:** `win11\build.ps1` signs the package with a self-signed `CN=ForensicAid` certificate from your user store, and creates that certificate on the first build. Installing the package needs this certificate in `LocalMachine\TrustedPeople`, which is why there is one UAC prompt.
- **Versions:** every build gets a new package version, and the installer updates the registered package in place.
- **Drive icons:** Windows does not allow top-level entries on drive icons. Right-clicking a drive itself still uses *Show more options*. Folders and files on the drive get the top-level menu.
- **No duplicates:** while the package is registered, the classic entries for files and folders are not registered, so the item does not show twice.
- **Turning it off:** set `Win11Menu = $false` in the config to skip all of this.
- **Testing:** `win11\test\Test-Harness.ps1` loads the DLL without installing it and shows what the menu would contain for test files.

## Tray icon

The fingerprint icon next to the clock gives you:
- **Context menu items:** tick or untick each item, and both menus update in the background. These choices are stored in `menu.state.json`, so your config file is never rewritten.
- **Run action...:** run any action on a file or folder picked in a dialog.
- **Check tools**, **Edit configuration** and **Refresh menu**.
- Shortcuts to the last results, the output folder, the history log and the install folder.
- **Start with Windows**.

Double-click the icon to open the last results.

## Configuration

`%LOCALAPPDATA%\ForensicAid\ForensicAid.config.psd1` is a commented PowerShell data file. `%VARIABLES%` in it are expanded. After editing it, use **Refresh menu**.

| Setting | Meaning |
|---|---|
| `ToolRoots` | Folders searched recursively for tools. When several copies are found, the highest version wins, e.g. net9 over net6 or Chainsaw v2 over v1. |
| `Tools` | Exact executable paths. These take priority over `ToolRoots`. |
| `Chainsaw` | `SigmaRules`, `Mapping`, `Rules`, `ExtraArgs`. Empty values use the standard layout next to `chainsaw.exe`. |
| `RECmdBatch` | Batch file for RECmd. When empty, `BatchExamples\Kroll_Batch.reb` is used. |
| `OutputMode` / `OutputRoot` | `NextToEvidence` (default, falls back to `OutputRoot`) or always `OutputRoot`. |
| `OpenOutputFolder` | Open the results in Explorer when an action finishes. |
| `PauseOnExit` | `Always`, `OnError` or `Never`. |
| `FilterByFileType` | Show file items only for matching files. |
| `HideUnavailable` | Hide items whose tool was not found. |
| `Disabled` | Action ids to hide, e.g. `@('to-raw')`. The tray adds its own toggles to this. |
| `EnableLogging` | Write `history.log` in the install folder. |
| `Win11Menu` | Install the Windows 11 top-level menu when the package has been built. |

## Command line

```powershell
.\ForensicAid.ps1 -Action triage -Path 'E:\KAPE\C'   # any action id: hash, chainsaw, evtx, mft, registry, srum, rdpcache, to-raw, ...
.\ForensicAid.ps1 -Action doctor                     # which tools and rules were found
.\ForensicAid.ps1 -Install [-ResetConfig] [-Yes]     # -Yes = remove old versions without asking
.\ForensicAid.ps1 -Uninstall
```

## Repository layout

| Path | What |
|---|---|
| `ForensicAid.ps1` | Installer, menu registration and every action, all in one script. |
| `ForensicAidTray.ps1` | Tray icon. |
| `ForensicAid.config.psd1` | Config template, copied on the first install. |
| `install.cmd` / `uninstall.cmd` | Double-click wrappers. |
| `icon.ico` | Menu, tray and package icon. |
| `win11/` | Windows 11 shell extension: `src/` (DLL + stub exe), `package/` (manifest), `build.ps1`, `test/` (harness). |

## Troubleshooting

- **The menu does not show up or still shows old items:** run **Check tools**, then **Refresh menu**. On Windows 11, restart Explorer after the first install of the package.
- **ForensicAid shows twice:** run `install.cmd` again. This happens when the classic entries were registered before the Windows 11 package.
- **The installer seems stuck on "Deployment operation progress ... Initialized":** Windows is waiting for Explorer to release the old package. Give it a minute. If it does not move on, restart Explorer from Task Manager.
- **The old icon still shows:** Explorer caches icons. Restart Explorer.
- **The Windows 11 menu was skipped:** the installer prints why, e.g. the package was not built or the UAC prompt was refused. The classic menu works either way.
- **To remove the certificate after uninstalling:** open `certlm.msc` and delete `ForensicAid` under *Trusted People*. Delete it from `certmgr.msc` under *Personal* only if you no longer build the package.

## Planned

- KAPE integration.
- RDP cache: decoding the RLE-compressed tiles of old `bcache2x.bmc` files. They are currently counted and skipped.

**No guarantees.** Use it on your own responsibility, and work on copies of evidence when in doubt.
