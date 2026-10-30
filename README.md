<p align="center">
  <img src="docs/icon.png" width="110" alt="ForensicAid fingerprint">
</p>

<h1 align="center">ForensicAid</h1>

<p align="center"><b>Right-click evidence, pick what to do, get the results.</b></p>

| Right-click on a folder | Right-click on a disk image |
|---|---|
| ![ForensicAid menu on a folder](docs/menu-folder.png) | ![ForensicAid menu on a .vhdx file](docs/menu-disk-image.png) |

## Install

1. Download this repository.
2. Double-click **`install.cmd`** and answer **y** to every question.
3. Right-click any evidence file or folder, then choose **ForensicAid**.

ForensicAid finds the forensic tools you already have on the PC. A tool that is missing simply doesn't show up in the menu.

## What it does

- Parses the usual evidence with [Eric Zimmerman's tools](https://ericzimmerman.github.io) and [Chainsaw](https://github.com/WithSecureLabs/chainsaw): event logs, `$MFT`, Prefetch, LNK, registry, Amcache, SRUM and more.
- **Full triage**: runs every parser that fits a whole folder, for example a KAPE collection.
- Hashes files, extracts RDP cache screens and converts disk images to `.dd`.
- Puts the results in a `ForensicAid` folder next to the evidence.
- **Never changes the evidence.**

The red fingerprint next to the clock lets you switch menu items on and off.

## Help

- **A menu item is missing:** choose **ForensicAid → Find tools on this PC**.
- **Something else:** see [docs/ADVANCED.md](docs/ADVANCED.md).
- **To uninstall:** double-click **`uninstall.cmd`**.

## Planned

- A settings window instead of editing the config file by hand.
- Automatic download of the tools.
- KAPE integration.
- Antivirus quarantine with [maldump](https://github.com/NUKIB/maldump).
- RdpCacheStitcher opening the tiles by itself. Today ForensicAid starts it and puts the folder on the clipboard.

---

No guarantees. Use it at your own risk, and work on copies of the evidence.
