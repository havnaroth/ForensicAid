# ForensicAid

**Right-click evidence, pick what to do, get the results.**

ForensicAid puts forensic parsers into your right-click menu. Right-click a file such as `Amcache.hve`, `Security.evtx` or `disk.vhdx`, or a whole folder from KAPE, choose **ForensicAid**, and click the parser you want. It runs the right tool with the right options. The results end up in a `ForensicAid` folder next to the evidence.

| Right-click on a folder | Right-click on a disk image |
|---|---|
| ![ForensicAid menu on a folder](docs/menu-folder.png) | ![ForensicAid menu on a .vhdx file](docs/menu-disk-image.png) |

The menu only shows what makes sense for the item you clicked. On a `.vhdx` file you get the RAW conversion, and on a folder you get the folder parsers.

## What you need

- Windows 10 or 11. Nothing else needs to be installed: no Python, no admin account.
- The forensic tools you want to use, in one folder, for example `C:\Tools`:
  - [Eric Zimmerman's tools](https://ericzimmerman.github.io): run `Get-ZimmermanTools.ps1` into that folder;
  - [Chainsaw v2](https://github.com/WithSecureLabs/chainsaw);
  - `qemu-img`, only for disk image conversion.

  You don't need all of them. Missing tools just don't show in the menu.

## Install

1. Download or clone this repository.
2. Double-click **`install.cmd`**.
3. Answer the questions:
   - If you have an older version, it asks to remove it. Say **y**. A backup is made first.
   - On Windows 11 it may ask for **admin permission** once, so ForensicAid can appear in the main right-click menu. Say **yes**.
4. Done. Right-click any evidence file or folder and look for **ForensicAid**.

If your tools are not in `C:\Tools` or on your Desktop, right-click anything and choose **ForensicAid → Edit configuration**. Add your tools folder under `ToolRoots`, save the file, then choose **ForensicAid → Refresh menu**.

To remove ForensicAid, double-click **`uninstall.cmd`**.

## What it can do

| Menu item | Use it on | What you get |
|---|---|---|
| Hash | any file or folder | MD5 / SHA1 / SHA256. For a single file the SHA256 is copied to the clipboard. |
| Full triage | a folder, e.g. a KAPE collection | every parser below that fits the folder, in one go |
| Event logs (Chainsaw / EvtxECmd) | `.evtx` or a folder | Sigma detections and parsed event logs |
| NTFS (MFTECmd) | `$MFT`, `$J`, ... | file system timeline |
| Prefetch, LNK, Jump lists, Recycle Bin | `.pf`, `.lnk`, ... or a folder | program execution and file access |
| RDP bitmap cache | `Cache0000.bin`, `bcache*.bmc` | screen fragments from RDP sessions, as images and a collage |
| Amcache, ShimCache, Registry, ShellBags | registry hives or a folder | parsed registry artifacts |
| SRUM, UAL, Windows Timeline | `SRUDB.dat`, `*.mdb`, `ActivitiesCache.db` | resource usage, logons and activity history |
| Repair ESE database | `.edb`, `.mdb`, `.dat` | a repaired **copy** of the database |
| Disk image to RAW | `.vhdx`, `.vhd`, `.vmdk`, ... | a `.dd` image |
| Open in Timeline Explorer | `.csv` | opens the results for review |

**Your evidence is never changed.** Databases are copied before they are parsed or repaired, and each result folder has a `ForensicAid.log` with every command that was run.

## Tray icon

After installing, a red fingerprint appears next to the clock. Right-click it to:
- switch menu items on or off;
- run any action on a file you pick;
- open your last results.

## Windows 11

On Windows 11, ForensicAid appears directly in the right-click menu, not hidden under *Show more options*. For that, it needs a small extra component, which has to be built once with Visual Studio:

```
powershell -ExecutionPolicy Bypass -File win11\build.ps1
```

Run `install.cmd` after building. If you skip this step, ForensicAid still works, but it stays under *Show more options*.

## If something goes wrong

- **The menu item you want is missing:** choose **ForensicAid → Check tools**. It shows which tools were found and which were not.
- **ForensicAid shows twice, or the icon looks old:** run `install.cmd` again and let it restart Explorer.
- **The installer seems stuck on "Deployment operation progress":** wait a minute. If it still doesn't move, restart Explorer from Task Manager.

## For advanced users

- Settings file: `%LOCALAPPDATA%\ForensicAid\ForensicAid.config.psd1`. Every option in it is explained by a comment.
- Command line:

  ```powershell
  .\ForensicAid.ps1 -Action triage -Path 'E:\KAPE\C'   # any menu action by id
  .\ForensicAid.ps1 -Action doctor                     # check tools
  ```
- Everything is in two PowerShell scripts: `ForensicAid.ps1` and the tray icon in `ForensicAidTray.ps1`. The Windows 11 component's source is in `win11/`.

## Planned

- Automatic download of the tools ForensicAid supports by default: EZ tools, Chainsaw with Sigma rules, Timeline Explorer, qemu-img.
- KAPE integration.
- RDP cache: decoding the compressed tiles of old `bcache2x.bmc` files.

---

**No guarantees.** Use it on your own responsibility, and work on copies of evidence when in doubt.
