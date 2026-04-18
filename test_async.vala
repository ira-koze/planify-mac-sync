void main() {
    var loop = new MainLoop();
    try {
        var subprocess = new GLib.Subprocess(
            GLib.SubprocessFlags.STDOUT_PIPE,
            "/usr/bin/defaults", "read", "-g", "AppleInterfaceStyle"
        );
        subprocess.communicate_utf8_async.begin(null, null, (obj, res) => {
            try {
                string stdout_buf, stderr_buf;
                subprocess.communicate_utf8_async.end(res, out stdout_buf, out stderr_buf);
                bool is_dark = subprocess.get_successful() && stdout_buf != null && stdout_buf.strip() == "Dark";
                GLib.message("Is dark async: " + is_dark.to_string());
            } catch (Error e) {
                GLib.message("Error: " + e.message);
            }
            loop.quit();
        });
    } catch (Error e) {
        GLib.message("error");
    }
    loop.run();
}
