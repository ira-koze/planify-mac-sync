import re
path = 'core/Services/Store.vala'
with open(path, 'r') as f:
    content = f.read()

# Precisely find the GLib.Once block
old_pattern = re.compile(r'static GLib\.Once<Services\.Store> _instance;\s*public static unowned Services\.Store instance \(\) \{\s*return _instance\.once \(\(\) => \{\s*return new Services\.Store \(\);\s*\}\);\s*\}', re.DOTALL)

new_block = """private static Services.Store? _instance = null;
    public static unowned Services.Store instance () {
        if (_instance == null) {
            _instance = new Services.Store ();
        }
        return _instance;
    }"""

if old_pattern.search(content):
    content = old_pattern.sub(new_block, content)
    with open(path, 'w') as f:
        f.write(content)
    print("Store.vala patched safely and successfully!")
else:
    print("Could not find the target block.")
