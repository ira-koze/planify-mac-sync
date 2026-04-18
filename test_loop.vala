void main() {
    var loop = new MainLoop();
    GLib.Timeout.add_seconds(1, () => {
        try {
            string stdout_buf, stderr_buf;
            int exit_status;
            GLib.Process.spawn_command_line_sync(
                "/usr/bin/defaults read -g AppleInterfaceStyle",
                out stdout_buf, out stderr_buf, out exit_status
            );
            bool is_dark = exit_status == 0 && stdout_buf.strip() == "Dark";
            GLib.message("Is Dark: " + is_dark.to_string());
        } catch (Error e) {
            GLib.message("Err: " + e.message);
        }
        loop.quit();
        return GLib.Source.REMOVE;
    });
    loop.run();
}
