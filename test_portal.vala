void main() {
    try {
        var portal = ColorSchemeSettings.Portal.Settings.get();
        if (portal != null) {
            GLib.message("Got portal!");
            var res = portal.read("org.freedesktop.appearance", "color-scheme");
            GLib.message("Read result!");
            var v = res.get_variant().get_uint32();
            GLib.message("variant: " + v.to_string());
        }
    } catch (Error e) {
        GLib.message("Error: " + e.message);
    }
}
namespace ColorSchemeSettings.Portal {
    private const string DBUS_DESKTOP_PATH = "/org/freedesktop/portal/desktop";
    private const string DBUS_DESKTOP_NAME = "org.freedesktop.portal.Desktop";

    [DBus (name = "org.freedesktop.portal.Settings")]
    interface Settings : Object {
        public static Settings @get () throws Error {
            return Bus.get_proxy_sync (
                BusType.SESSION,
                DBUS_DESKTOP_NAME,
                DBUS_DESKTOP_PATH,
                DBusProxyFlags.NONE
            );
        }
        public abstract Variant read (string namespace, string key) throws DBusError, IOError;
    }
}
