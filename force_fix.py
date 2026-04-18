import os

def fix_file(path, search_str, replacement_lines):
    if not os.path.exists(path): return
    with open(path, 'r') as f:
        lines = f.readlines()
    
    new_lines = []
    found = False
    for line in lines:
        if search_str in line and not found:
            new_lines.extend(replacement_lines)
            found = True
        elif "GLib.Once" in line and ("_instance" in line or "instance" in line):
            # Skip the old Once declarations
            continue
        elif "return _instance.once" in line or "return instance.once" in line:
            # Skip the old Once return calls
            continue
        else:
            new_lines.append(line)
    
    with open(path, 'w') as f:
        f.writelines(new_lines)
    print(f"✅ Forced Fix: {path}")

# 1. Fix App.vala (Early environment injection)
fix_file('src/App.vala', 'public static int main', [
    '    public static int main (string[] args) {\n',
    '        GLib.Environment.set_variable ("XDG_DATA_DIRS", "/opt/homebrew/share:" + (GLib.Environment.get_variable ("XDG_DATA_DIRS") ?? "/usr/share"), true);\n',
    '        GLib.Environment.set_variable ("GSETTINGS_SCHEMA_DIR", "/opt/homebrew/share/glib-2.0/schemas", true);\n'
])

# 2. Fix ColorSchemeSettings.vala (The main culprit)
# We handle the nested Settings class by defining the instance inside the correct block
fix_file('core/Services/ColorSchemeSettings.vala', 'public class Settings', [
    '        public class Settings : GLib.Object {\n',
    '            private static Settings? _instance = null;\n',
    '            public static unowned Settings get_default () {\n',
    '                if (_instance == null) { _instance = new Settings (); }\n',
    '                return _instance;\n',
    '            }\n'
])

# 3. Fix MainWindow.vala (The Crash Shield)
fix_file('src/MainWindow.vala', 'color_scheme_settings.settings.notify["prefers-color-scheme"].connect', [
    '        if (color_scheme_settings != null && color_scheme_settings.settings != null) {\n',
    '            color_scheme_settings.settings.notify["prefers-color-scheme"].connect (() => {\n',
    '                update_theme ();\n',
    '            });\n',
    '        }\n'
])

# 4. Fix Store.vala
fix_file('core/Services/Store.vala', 'public class Store', [
    '    public class Store : GLib.Object {\n',
    '        private static Services.Store? _instance = null;\n',
    '        public static unowned Services.Store instance () {\n',
    '            if (_instance == null) { _instance = new Services.Store (); }\n',
    '            return _instance;\n',
    '        }\n'
])
