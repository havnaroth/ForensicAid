import os
import winreg
import configparser
import ctypes
import shutil

# ANSI color codes
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
RESET = "\033[0m"

ASCII_ART = f"""{GREEN}
 ██████████   ███████████ █████ ███████████                        
░░███░░░░███ ░░███░░░░░░█░░███ ░░███░░░░░███                       
 ░███   ░░███ ░███   █ ░  ░███  ░███    ░███                       
 ░███    ░███ ░███████    ░███  ░██████████                        
 ░███    ░███ ░███░░░█    ░███  ░███░░░░░███                       
 ░███    ███  ░███  ░     ░███  ░███    ░███                       
 ██████████   █████       █████ █████   █████                      
░░░░░░░░░░   ░░░░░       ░░░░░ ░░░░░   ░░░░░                       
                                                                   
                                                                   
                                                                   
 ███████████                   ████  █████                         
░█░░░███░░░█                  ░░███ ░░███                          
░   ░███  ░   ██████   ██████  ░███  ░███████   ██████  █████ █████
    ░███     ███░░███ ███░░███ ░███  ░███░░███ ███░░███░░███ ░░███ 
    ░███    ░███ ░███░███ ░███ ░███  ░███ ░███░███ ░███ ░░░█████░  
    ░███    ░███ ░███░███ ░███ ░███  ░███ ░███░███ ░███  ███░░░███ 
    █████   ░░██████ ░░██████  █████ ████████ ░░██████  █████ █████
   ░░░░░     ░░░░░░   ░░░░░░  ░░░░░ ░░░░░░░░   ░░░░░░  ░░░░░ ░░░░░ 
                                                                   
                                                                   
                                                                   
   Author : Mateusz Nowicki aka Hannon
   Version: 0.1
   Date   : 11.10.2025
{RESET}"""


# Enable ANSI color support in Windows CMD
def enable_ansi_colors():
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
    kernel32.SetConsoleMode(handle, 7)   # ENABLE_VIRTUAL_TERMINAL_PROCESSING

BASE_KEY_PATH = r"*\shell\HannsForensics"

def load_config():
    config_path = os.path.join(os.path.dirname(__file__), "config.ini")
    config = configparser.ConfigParser()
    if not os.path.exists(config_path):
        print(f"{RED}[✘] config.ini not found.{RESET}")
        return {}, [], {}

    config.read(config_path)

    # Read Settings
    settings = {}
    if "Settings" in config:
        for key, value in config["Settings"].items():
            settings[key.strip()] = value.strip()

    # Read Enabled Modules
    enabled_modules = []
    if "Modules" in config:
        for key, value in config["Modules"].items():
            if value.strip().upper() == "TRUE":
                enabled_modules.append(key.strip())

    # Read Titles
    titles = {}
    if "Titles" in config:
        for key, value in config["Titles"].items():
            titles[key.strip()] = value.strip()

    return settings, enabled_modules, titles

def verify_module_files(modules):
    base_dir = os.path.dirname(__file__)
    modules_dir = os.path.join(base_dir, "modules")
    print("\n[📁] Verifying module scripts in 'modules' directory...")

    missing = []

    for module in modules:
        expected_file = os.path.join(modules_dir, f"{module}.py")
        if not os.path.isfile(expected_file):
            missing.append(expected_file)

    if missing:
        for path in missing:
            print(f"{RED}[✘] Missing: {path}{RESET}")
    else:
        print(f"{GREEN}[✔] All expected modules are present.{RESET}")

def check_installation_path(settings):
    path = settings.get("installation_path", "").strip()
    if not path:
        print(f"{RED}[!] No installation_path defined in config.ini.{RESET}")
        return

    if os.path.isdir(path):
        print(f"{GREEN}[✔] Installation path exists: {path}{RESET}")
    else:
        print(f"{RED}[✘] Installation path missing: {path}{RESET}")
        try:
            os.makedirs(path)
            print(f"{GREEN}[✔] Created installation path: {path}{RESET}")
        except PermissionError:
            print(f"{RED}[✘] Permission denied. Could not create installation path.{RESET}")
        except Exception as e:
            print(f"{RED}[✘] Error creating installation path: {e}{RESET}")

def ensure_base_key_exists(settings):
    try:
        with winreg.OpenKey(winreg.HKEY_CLASSES_ROOT, BASE_KEY_PATH, 0, winreg.KEY_READ):
            print(f"{GREEN}[✔] Base registry key exists.{RESET}")
    except FileNotFoundError:
        print(f"{YELLOW}[!] Base registry key not found. Creating...{RESET}")
        try:
            with winreg.CreateKey(winreg.HKEY_CLASSES_ROOT, BASE_KEY_PATH) as key:
                winreg.SetValueEx(key, "MUIVerb", 0, winreg.REG_SZ, "Hanns Forensics")
                winreg.SetValueEx(key, "SubCommands", 0, winreg.REG_SZ, "")
                if "default_icon" in settings:
                    winreg.SetValueEx(key, "Icon", 0, winreg.REG_SZ, settings["default_icon"])
                print(f"{GREEN}[✔] Base key created with default values.{RESET}")
        except PermissionError:
            print(f"{RED}[✘] Permission denied. Run as administrator.{RESET}")

def write_subcommands(enabled_modules):
    subcommands_value = ";".join(enabled_modules)
    try:
        with winreg.OpenKey(winreg.HKEY_CLASSES_ROOT, BASE_KEY_PATH, 0, winreg.KEY_SET_VALUE) as key:
            winreg.SetValueEx(key, "SubCommands", 0, winreg.REG_SZ, subcommands_value)
            print(f"{GREEN}[✔] SubCommands updated: {subcommands_value}{RESET}")
    except PermissionError:
        print(f"{RED}[✘] Permission denied. Run as administrator.{RESET}")

def check_commandstore_keys(modules, titles, settings):
    base_path = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CommandStore\shell"
    install_path = settings.get("installation_path", "").rstrip("\\")
    print("\n[🔧] Validating and correcting CommandStore entries...")

    for module in modules:
        module_path = f"{base_path}\\{module}"
        expected_title = titles.get(module)
        expected_command = f'cmd.exe /k "python {install_path}\\{module}.py\\"%1\\""'

        if not expected_title:
            print(f"{YELLOW}[!] Warning: No title defined for {module} in [Titles] section.{RESET}")
            expected_title = module  # fallback

        try:
            with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, module_path) as key:
                try:
                    current_title = winreg.QueryValueEx(key, "MUIVerb")[0]
                    if current_title != expected_title:
                        winreg.SetValueEx(key, "MUIVerb", 0, winreg.REG_SZ, expected_title)
                        print(f"{YELLOW}[↻] MUIVerb corrected for {module}{RESET}")
                    else:
                        print(f"{GREEN}[✔] MUIVerb OK for {module}{RESET}")
                except FileNotFoundError:
                    winreg.SetValueEx(key, "MUIVerb", 0, winreg.REG_SZ, expected_title)
                    print(f"{GREEN}[+] MUIVerb set for {module}{RESET}")

                try:
                    with winreg.CreateKey(key, "command") as cmd_key:
                        try:
                            current_cmd = winreg.QueryValueEx(cmd_key, "")[0]
                            if current_cmd != expected_command:
                                winreg.SetValueEx(cmd_key, "", 0, winreg.REG_SZ, expected_command)
                                print(f"{YELLOW}[↻] Command corrected for {module}{RESET}")
                            else:
                                print(f"{GREEN}[✔] Command OK for {module}{RESET}")
                        except FileNotFoundError:
                            winreg.SetValueEx(cmd_key, "", 0, winreg.REG_SZ, expected_command)
                            print(f"{GREEN}[+] Command set for {module}{RESET}")
                except PermissionError:
                    print(f"{RED}[✘] Permission denied creating command subkey for {module}{RESET}")
        except PermissionError:
            print(f"{RED}[✘] Permission denied accessing CommandStore for {module}{RESET}")

def install_modules(modules, settings):
    base_dir = os.path.dirname(__file__)
    source_dir = os.path.join(base_dir, "modules")
    target_dir = settings.get("installation_path", "").strip()

    if not target_dir:
        print(f"{RED}[✘] No installation_path defined in config.ini. Cannot install modules.{RESET}")
        return

    print(f"\n[📦] Installing modules to: {target_dir}")

    for module in modules:
        src = os.path.join(source_dir, f"{module}.py")
        dst = os.path.join(target_dir, f"{module}.py")

        if not os.path.isfile(src):
            print(f"{RED}[✘] Source file missing: {src}{RESET}")
            continue

        try:
            shutil.copy2(src, dst)
            print(f"{GREEN}[✔] Installed: {module}.py → {dst}{RESET}")
        except PermissionError:
            print(f"{RED}[✘] Permission denied copying {module}.py to {dst}{RESET}")
        except Exception as e:
            print(f"{RED}[✘] Error copying {module}.py: {e}{RESET}")


if __name__ == "__main__":
    enable_ansi_colors()
    print(ASCII_ART)
    settings, modules, titles = load_config()
    verify_module_files(modules)
    print(f"\nSettings: {settings}")
    print(f"Enabled modules: {modules}")
    print(f"Titles: {titles}")
    check_installation_path(settings)
    ensure_base_key_exists(settings)
    if modules:
        write_subcommands(modules)
        check_commandstore_keys(modules, titles, settings)
        install_modules(modules, settings)
    print (f"{RED}!!! Remember that each module needs to have its related EZ tool paths set correctly inside the module script!!!{RESET}")
