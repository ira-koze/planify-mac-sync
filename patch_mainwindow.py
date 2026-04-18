import re

with open("src/MainWindow.vala", "r") as f:
    lines = f.readlines()

new_lines = []
count = 0
for line in lines:
    if ".connect (" in line and "=>" in line:
        count += 1
        new_lines.append(f"        GLib.message(\"Connecting signal {count}: \" + \"\"\"{line.strip()}\"\"\");\n")
    elif ".connect (" in line:
        count += 1
        new_lines.append(f"        GLib.message(\"Connecting signal {count}: \" + \"\"\"{line.strip()}\"\"\");\n")
    new_lines.append(line)

with open("src/MainWindow.vala", "w") as f:
    f.writelines(new_lines)
