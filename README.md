# DFIR Toolbox 

```
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
```

A modular setup utility for deploying forensic automation tools into the Windows context menu via registry integration. Designed for threat hunters, incident responders, and forensic analysts who need fast access to Python-based modules directly from Explorer.

---

## 📦 Installation

1. Clone the repository  
2. Configure `config.ini`:
   - `[Settings]` → installation path, icon, logging
   - `[Modules]` → enable/disable specific tools
   - `[Titles]` → display names for context menu
4. Run `setup.py` as administrator:

```bash
python setup.py
