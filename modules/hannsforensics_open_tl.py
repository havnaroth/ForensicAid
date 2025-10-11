import sys
import subprocess
from pathlib import Path

def main():
    if len(sys.argv) < 2:
        print("Usage: launch_esentutl.py <path_to_file>")
        sys.exit(1)

    raw_path = sys.argv[1].strip('"').strip()
    target_file = Path(raw_path)
    target_dir = target_file.parent

    #print(f"File: {target_file}")
    #print(f"Dir:  {target_dir}")

    parser_path = r"C:\Users\xxxxx\Desktop\TimelineExplorer\TimelineExplorer.exe"
    cmd = [
        parser_path,
         str(target_file),
    ]

    subprocess.run(cmd, shell=True)
    input("Press Enter to close...")

if __name__ == "__main__":
    main()