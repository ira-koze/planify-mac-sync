import os, re

def safe_patch(path, pattern, replacement):
    if not os.path.exists(path): return
    with open(path, 'r') as f: content = f.read()
    if re.search(pattern, content, re.DOTALL):
        new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)
        with open(path, 'w') as f: f.write(new_content)
        print(f"✅ Patched: {path}")

# FIX 1: MainWindow Null Guard (The actual crash site)
safe_patch('src/MainWindow.vala', 
    r'(color_scheme_settings\.settings\.notify\["prefers-color-scheme"\]\.connect.*?\(.*?\);)', 
    r'if (color_scheme_settings != null && color_scheme_settings.settings != null) { \1 }')

# FIX 2: App Environment Injection (schema detection)
safe_patch('src/App.vala', 
    r'(public static int main \(string\[\] args\) \{)', 
    r'\1\n        GLib.Environment.set_variable ("XDG_DATA_DIRS", "/opt/homebrew/share:" + (GLib.Environment.get_variable ("XDG_DATA_DIRS") ?? "/usr/share"), true);\n        GLib.Environment.set_variable ("GSETTINGS_SCHEMA_DIR", "/opt/homebrew/share/glib-2.0/schemas", true);')

# FIX 3: ColorSchemeSettings Nested Singleton
# This handles the specific hierarchy needed so Util.vala doesn't break
color_path = 'core/Services/ColorSchemeSettings.vala'
if os.path.exists(color_path):
    with open(color_path, 'r') as f: c = f.read()
    c = re.sub(r'static GLib\.Once<Settings> _instance;', 'private static Settings? _instance = null;', c)
    c = re.sub(r'public static Settings get_default \(\) \{.*?return _instance\.once \(.*?\}\);\s*\}', 
               'public static unowned Settings get_default () { if (_instance == null) { _instance = new Settings (); } return _instance; }', c, flags=re.DOTALL)
    with open(color_path, 'w') as f: f.write(c)
    print(f"✅ Patched: {color_path}")

# FIX 4: Generic Singletons
for f_path, cls in [('core/Services/Store.vala', 'Services.Store'), 
                    ('src/Services/DBusServer.vala', 'DBusServer'), 
                    ('src/Services/MigrateFromPlanner.vala', 'MigrateFromPlanner')]:
    if not os.path.exists(f_path): continue
    with open(f_path, 'r') as f: c = f.read()
    c = re.sub(r'static GLib\.Once<.*?> (?:_instance|instance);', f'private static {cls}? _instance = null;', c)
    method = "instance" if "Store" in cls else "get_default"
    c = re.sub(rf'public static unowned {cls} {method} \(.*?\)\s*\{{.*?\}}', 
               f'public static unowned {cls} {method} () {{ if (_instance == null) {{ _instance = new {cls} (); }} return _instance; }}', c, flags=re.DOTALL)
    with open(f_path, 'w') as f: f.write(c)
    print(f"✅ Patched: {f_path}")
