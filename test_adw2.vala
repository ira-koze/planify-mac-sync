void main(string[] args) {
    Adw.init();
    var loop = new MainLoop();
    var manager = Adw.StyleManager.get_default();
    
    // Default scheme
    manager.color_scheme = Adw.ColorScheme.DEFAULT;
    
    GLib.message("Initial dark: " + manager.dark.to_string());
    
    manager.notify["dark"].connect(() => {
        GLib.message("Dark changed: " + manager.dark.to_string());
    });
    
    GLib.Timeout.add_seconds(10, () => {
        loop.quit();
        return false;
    });
    
    loop.run();
}
