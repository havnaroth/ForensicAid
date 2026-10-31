# ForensicAid: details

## Menu items

| Menu item | Use it on | What you get |
|---|---|---|
| Hash | any file or folder | MD5 / SHA1 / SHA256. For a single file the SHA256 is copied to the clipboard; a folder gives `hashes.csv`. |
| Full triage | a folder, e.g. a KAPE collection | every parser below that fits the folder, plus `triage_summary.csv` |
| Event logs: Chainsaw / EvtxECmd | `.evtx` or a folder | Sigma detections and parsed event logs |
| NTFS: MFTECmd | `$MFT`, `$J`, `$Boot`, `$SDS`, `$I30` | file system timeline |
| Prefetch, LNK, Jump lists, Recycle Bin | `.pf`, `.lnk`, `*Destinations-ms`, `$I*` or a folder | program execution and file access |
| RDP bitmap cache | `Cache0000.bin`, `bcache*.bmc` or a folder | every tile as a PNG, plus a collage per cache file. When RdpCacheStitcher is installed, the tiles are also saved as BMP and it offers to open them. |
| Open tiles in RdpCacheStitcher | a results folder | starts [RdpCacheStitcher](https://github.com/bsi-bund/RdpCacheStitcher) to rebuild whole screens |
| Amcache, ShimCache, Registry, ShellBags | registry hives or a folder | parsed registry artifacts (RECmd uses `Kroll_Batch.reb`) |
| SRUM, UAL, Windows Timeline | `SRUDB.dat`, `*.mdb`, `ActivitiesCache.db` | resource usage, logons and activity history |
| Repair ESE database | `.edb`, `.mdb`, `SRUDB.dat`, `WebCacheV*.dat` | a repaired **copy** of the database |
| Disk image to RAW | `.vhdx`, `.vhd`, `.vmdk`, `.qcow2`, `.vdi` | a `.dd` image, made by qemu-img |
| Open in Timeline Explorer | `.csv`, `.xlsx` | the file opened in Timeline Explorer |
| Find tools / Check tools / Settings / Refresh menu | everywhere | manage ForensicAid itself |

### RdpCacheStitcher

RdpCacheStitcher has no command-line options, so it cannot be told which folder to open. ForensicAid starts it and copies the tile folder to the clipboard. In RdpCacheStitcher, choose **File → New case**, paste the folder with Ctrl+V and click **Select Folder**.

It reads only BMP tiles, so ForensicAid writes them to `for_RdpCacheStitcher\<cache file>\` in the results folder. RdpCacheStitcher also needs the [Visual C++ Redistributable (x64)](https://aka.ms/vs/17/release/vc_redist.x64.exe).

## How evidence is handled

- **Databases:** ESE databases (SRUM, UAL) and `ActivitiesCache.db` are copied with their logs, and only the copy is parsed.
  - A dirty database first gets a log replay (`esentutl /r`).
  - Only if that fails does the copy get a hard repair (`esentutl /p`).
- **Dirty registry hives:** a dirty hive with no `.LOG1`/`.LOG2` files next to it is parsed with `--nl`, and you get a warning.
- **Results:** they go to `<evidence folder>\ForensicAid\<timestamp>_<action>_<name>\`.
  - When that location is read-only, they go to `%USERPROFILE%\ForensicAid_Output`.
  - Each result folder has a `ForensicAid.log` with every command that was run, its exit code and how long it took.

## Tools

You don't need all of these. A missing tool only hides its menu item.
- [Eric Zimmerman's tools](https://ericzimmerman.github.io): run `Get-ZimmermanTools.ps1` into a folder such as `C:\Tools`.
- [Chainsaw v2](https://github.com/WithSecureLabs/chainsaw), plus a Sigma rules folder if you want Sigma.
- Timeline Explorer, which comes with the EZ tools.
- `qemu-img`, for disk image conversion.

### How "Find tools on this PC" searches

It also runs during install when tools are missing.
- **Quick scan, usually a few seconds.** It looks in:
  - folders where this user ran programs before (Program Compatibility Assistant, MuiCache);
  - Desktop, Documents and Downloads;
  - `ToolRoots`;
  - top-level folders with names like *Tools*, *Forensic* or *KAPE*.

  Prefetch and BAM would need admin rights, so they are not used.
- **Full scan:** `ForensicAid.ps1 -ScanTools -Deep` scans whole drives. That can take minutes.
- **Several versions of a tool:** it asks once. You can take the newest for all tools, choose for each tool, or keep what is already set.
- **Saving:** the result is written into the settings file. The previous version is kept as `.bak`.

## Windows 11 top-level menu

Without this, ForensicAid sits under *Show more options*. To get it into the main menu:

1. Build the extra component once. This needs Visual Studio with the C++ workload and the Windows SDK:
   ```
   powershell -ExecutionPolicy Bypass -File win11\build.ps1
   ```
2. Run `install.cmd`. It asks for admin rights once, to trust the package certificate.

Good to know:
- A right-click on a **drive icon** always uses *Show more options*. Windows does not allow anything else there.
- To skip the Windows 11 menu, untick the Windows 11 option in **Settings > General**.
- To remove the certificate after uninstalling, delete it in `certlm.msc` under *Trusted People*.

## Settings

Open **Settings** from the tray icon or from **ForensicAid → Settings** in Explorer. The **General** tab holds where results go, the menu options, the tool folders and the rule files. The **Tools** tab shows each tool's path, version and status, with buttons to browse and to find tools on this PC. The **Menu items** tab is described below. **Save** writes only what you changed and refreshes the menu.

### Menu items tab

The tab lists every item. Untick one to hide it from the menu.

**Edit...** (or a double-click) shows the arguments the item runs its program with, as a template with placeholders, and how the command would look on an example file. Change it and press **OK**; **Reset to default** brings back the built-in arguments. Changed items are shown in bold. For example, `{In} --csv {Out} --inc 4624,4625` makes EvtxECmd keep only logon events. The change also applies when the item runs as part of **Full triage**.

| Placeholder | Becomes |
|---|---|
| `{Path}` | the file or folder you right-clicked |
| `{In}` | `-f <file>` or `-d <folder>` (how the EZ tools take their input) |
| `{Out}` | the results folder of this run |
| `{Name}` | the file or folder name, without its path |
| `{Dir}` | the folder you clicked, or the folder holding the file |

Some items have extra placeholders that ForensicAid works out before the program runs, such as `{HiveArgs}` (adds `--nl` for a dirty hive without transaction logs) or `{Db}` (the repaired copy of an ESE database). The edit window lists them. Placeholders are quoted for you; inside quotes they are inserted as is, so `"{Out}\report"` works too.

Hash, RDP bitmap cache, Repair ESE database, Full triage and Open tiles in RdpCacheStitcher run several steps rather than one program, so their arguments cannot be changed.

**Add...** puts your own program in the menu: a title, the program, its arguments, whether it shows on files and/or folders, and which files it shows on (extensions, exact names or name prefixes). An optional **signature** (hex bytes at an offset, e.g. `4D5A` at 0 for an `.exe`) is checked before the program runs, so the item refuses files that only have the right name. Untick **Run in the ForensicAid console and wait** for programs with their own window.

Each changed or added item is one file in `%LOCALAPPDATA%\ForensicAid\actions`. To share an item, copy its file into someone else's `actions` folder and use **Refresh menu**. A custom item file looks like this:

```powershell
@{
    Title     = 'Foo cache - FooParser'
    Program   = 'C:\Tools\FooParser.exe'          # %VARIABLES% are expanded
    Command   = '-f {Path} --csv {Out}'
    Scope     = @('File')                         # File and/or Dir
    Ext       = @('.foo')                         # and/or Name = @(...), Prefix = @(...)
    Signature = @{ Offset = 0; Hex = '464F4F00' } # optional
    Output    = $true                             # create a results folder ({Out})
    Wait      = $true                             # $false: start it and return
}
```

A file named after a built-in item (for example `evtx.psd1`) holds only `Command` and replaces that item's arguments. **Check tools** lists the custom items and any item file that could not be read.

The settings live in `%LOCALAPPDATA%\ForensicAid\ForensicAid.config.psd1`. You can still edit it by hand (**Edit the config file** in the window). Every option is explained by a comment, and the window keeps those comments. After editing the file by hand, choose **ForensicAid → Refresh menu**.

| Setting | Meaning |
|---|---|
| `ToolRoots` | folders searched for tools |
| `Tools` | exact path to each tool; filled in by **Find tools on this PC** |
| `Chainsaw` | Sigma rules, mapping file and Chainsaw rules |
| `RECmdBatch` | the RECmd batch file to use |
| `OutputMode` / `OutputRoot` | where the results go |
| `OpenOutputFolder`, `PauseOnExit` | what happens when an action finishes |
| `FilterByFileType`, `HideUnavailable`, `Disabled` | which menu items are shown |
| `EnableLogging` | keep `history.log` |
| `Win11Menu` | install the Windows 11 top-level menu |

ForensicAid is installed in `%LOCALAPPDATA%\ForensicAid`. It holds the scripts, the settings, the history and the backups of old versions.

## Command line

```powershell
.\ForensicAid.ps1 -Action triage -Path 'E:\KAPE\C'   # any menu action by id
.\ForensicAid.ps1 -Action doctor                     # check tools
.\ForensicAid.ps1 -ScanTools [-Deep] [-Yes]          # find tools and link them in the settings
.\ForensicAid.ps1 -Install [-ResetConfig] [-Yes]
.\ForensicAid.ps1 -Uninstall
```

## Troubleshooting

- **A menu item is missing:** choose **Find tools on this PC**. If it still can't find the tool, run `-ScanTools -Deep`. **Check tools** shows what is linked right now.
- **ForensicAid shows twice, or the icon looks old:** run `install.cmd` again and let it restart Explorer.
- **The installer is stuck on "Deployment operation progress":** wait a minute. If nothing happens, restart Explorer from Task Manager.

## Repository layout

| Path | What |
|---|---|
| `ForensicAid.ps1` | installer, menu and every action |
| `ForensicAidTray.ps1` | the icon next to the clock; starts at logon through a per-user scheduled task |
| `ForensicAidSettings.ps1` | the settings window |
| `ForensicAid.config.psd1` | settings template |
| `install.cmd` / `uninstall.cmd` | double-click install and uninstall |
| `win11/` | Windows 11 menu component: C++ source, package, build script and tests |
| `docs/` | screenshots and this file |

## Planned, in more detail

- **Tool download:** download only the tools the PC scan did not find. When a tool on disk is older than the newest release, ask whether to update it.
- **KAPE integration.**
- **Antivirus quarantine:** [maldump](https://github.com/NUKIB/maldump) extracts quarantined files and their metadata from Windows Defender and other antivirus products.
- **RDP cache:**
  - opening the tile folder in RdpCacheStitcher automatically; this needs an upstream change so that it accepts a folder argument;
  - decoding the compressed tiles of old `bcache2x.bmc` files.
