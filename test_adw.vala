void main(string[] args) {
    Adw.init();
    var loop = new MainLoop();
    var manager = Adw.StyleManager.get_default();
    
    GLib.message("Initial dark: " + manager.dark.to_string());
    
    manager.notify["dark"].connect(() => {
        GLib.message("Dark changed: " + manager.dark.to_string());
    });
    
    // Force light scheme
    manager.color_scheme = Adw.ColorScheme.FORCE_LIGHT;
    
    GLib.Timeout.add_seconds(20, () => {
        loop.quit();
        return false;
    });
    
    loop.run();
}
