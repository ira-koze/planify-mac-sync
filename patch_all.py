import os
import re

for folder in ["src", "core", "quick-add"]:
    for root, dirs, files in os.walk(folder):
        for file in files:
            if file.endswith(".vala"):
                filepath = os.path.join(root, file)
                with open(filepath, "r") as f:
                    lines = f.readlines()
                
                new_lines = []
                for idx, line in enumerate(lines):
                    if ".connect (" in line:
                        escaped_file = filepath.replace('"', '\\"')
                        new_lines.append(f"        GLib.message(\"FILE {escaped_file} LINE {idx}\");\n")
                    new_lines.append(line)
                
                with open(filepath, "w") as f:
                    f.writelines(new_lines)

print("Patch done")
