import os

def inject_after_line(path, search_text, injection):
    if not os.path.exists(path): return
    with open(path, 'r') as f: lines = f.readlines()
    with open(path, 'w') as f:
        for line in lines:
            f.write(line)
            if search_text in line:
                f.write(injection + "\n")
    print(f"✅ Fixed environment in: {path}")

# 1. Inject Homebrew paths into the very first line of the Main function
# This ensures ALL settings (Store, Accounts, etc.) can find their schemas.
inject_after_line('src/App.vala', 'public static int main', 
    '        GLib.Environment.set_variable ("XDG_DATA_DIRS", "/opt/homebrew/share:" + (GLib.Environment.get_variable ("XDG_DATA_DIRS") ?? "/usr/share"), true);\n'
    '        GLib.Environment.set_variable ("GSETTINGS_SCHEMA_DIR", "/opt/homebrew/share/glib-2.0/schemas", true);')

# 2. Add the "Shield" to MainWindow to stop the NULL crash if anything goes wrong
with open('src/MainWindow.vala', 'r') as f: content = f.read()
# This safely wraps the connection in an IF block without breaking braces
target = 'color_scheme_settings.settings.notify["prefers-color-scheme"].connect'
if target in content:
    content = content.replace(target, 'if (color_scheme_settings.settings != null) color_scheme_settings.settings.notify["prefers-color-scheme"].connect')
    with open('src/MainWindow.vala', 'w') as f: f.write(content)
    print("✅ Fixed crash-shield in: src/MainWindow.vala")
