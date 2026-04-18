int main(string[] args) {
    var app = new Adw.Application("org.test.adw", 0);
    app.activate.connect(() => {
        var win = new Adw.ApplicationWindow(app);
        var manager = Adw.StyleManager.get_default();
        manager.color_scheme = Adw.ColorScheme.DEFAULT;
        
        GLib.message("Initial dark: " + manager.dark.to_string());
        
        manager.notify["dark"].connect(() => {
            GLib.message("Dark changed: " + manager.dark.to_string());
        });
        
        win.present();
    });
    
    GLib.Timeout.add_seconds(10, () => {
        app.quit();
        return false;
    });
    
    return app.run(args);
}
