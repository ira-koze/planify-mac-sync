import os

path = 'src/App.vala'
with open(path, 'r') as f:
    lines = f.readlines()

# Remove any existing main function blocks to avoid duplicates
# and find where the class ends to ensure braces are balanced.
content = "".join(lines)

# We want to find the LAST closing brace of the class and ensure
# the main function is inside it and correctly formatted.
# This is a bit of a "reset" for the main function block.
import re

# Look for the main function
main_pattern = re.compile(r'public static int main \(string\[\] args\).*?\{.*?\}', re.DOTALL)
env_code = """public static int main (string[] args) {
    string current_xdg = GLib.Environment.get_variable ("XDG_DATA_DIRS") ?? "/usr/local/share:/usr/share";
    GLib.Environment.set_variable ("XDG_DATA_DIRS", "/opt/homebrew/share:" + current_xdg, true);
    GLib.Intl.setlocale (LocaleCategory.ALL, "");

    var app = new App ();
    return app.run (args);
}"""

if main_pattern.search(content):
    content = main_pattern.sub(env_code, content)
else:
    # If we can't find it precisely, append it before the final brace
    content = content.strip()
    if content.endswith('}'):
        content = content[:-1] + "\n    " + env_code + "\n}"

with open(path, 'w') as f:
    f.write(content)
print("src/App.vala fixed and environment logic injected.")
