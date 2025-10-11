import sys
import subprocess
from pathlib import Path
import winreg
import configparser
import os

def read_config_path():
    try:
        key_path = r"SOFTWARE\DFIR_Toolbox"
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path) as key:
            value, _ = winreg.QueryValueEx(key, "ConfigPath")
            return value
    except FileNotFoundError:
        print(f"{RED}[✘] Config path not found in registry.{RESET}")
        return None


def load_config(config_path):
    if not os.path.isfile(config_path):
        raise FileNotFoundError(f"[✘] Config file not found: {config_path}")

    config = configparser.ConfigParser()
    config.read(config_path)

    settings = dict(config.items("Settings")) if config.has_section("Settings") else {}
    modules = dict(config.items("Modules")) if config.has_section("Modules") else {}
    titles = dict(config.items("Titles")) if config.has_section("Titles") else {}
    paths = dict(config.items("Paths")) if config.has_section("Paths") else {}

    return settings, modules, titles, paths

def main(settings, modules, titles, paths):
    if len(sys.argv) < 2:
        print("Usage: launch_amcache.py <path_to_file>")
        sys.exit(1)

    raw_path = sys.argv[1].strip('"').strip()
    target_file = Path(raw_path)
    target_dir = target_file.parent

    print(f"File: {target_file}")
    print(f"Dir:  {target_dir}")

    parser_path = paths.get("dfir_toolbox_amcache_path")
    #parser_path = r"C:\Users\Hannon\Desktop\AmcacheParser\AmcacheParser.exe"
    cmd = [
        parser_path,
        "-f", str(target_file),
        "--csv", str(target_dir)
    ]

    subprocess.run(cmd, shell=True)
    input("Press Enter to close...")

if __name__ == "__main__":
    config_path = read_config_path()
    if config_path is None:
        sys.exit(1)

    settings, modules, titles, paths = load_config(config_path)
    main(settings, modules, titles, paths)