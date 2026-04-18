/*
 * Copyright © 2023 Alain M. (https://github.com/alainm23/planify)
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301 USA
 *
 * Authored by: Alain M. <alainmh23@gmail.com>
 */

namespace ColorSchemeSettings {
    [DBus (name = "org.freedesktop.Accounts")]
    interface FDO.Accounts : Object {
        public abstract string find_user_by_name (string username) throws GLib.Error;
    }


    public class Settings : Object {
        public enum ColorScheme {
            NO_PREFERENCE,
            DARK,
            LIGHT
        }

        private ColorScheme? _prefers_color_scheme = null;

        public ColorScheme prefers_color_scheme {
            get {
                if (_prefers_color_scheme == null) {
                    setup_prefers_color_scheme ();
                }
                return _prefers_color_scheme;
            }
            private set {
                _prefers_color_scheme = value;
                notify_property ("prefers-color-scheme");
            }
        }

        private static ColorSchemeSettings.Settings? _instance = null;
        public static unowned ColorSchemeSettings.Settings get_default () {
            if (_instance == null) {
                _instance = new ColorSchemeSettings.Settings ();
            }
            return _instance;
        }

        private Portal.Settings? portal = null;

        private Settings () {}

        [CCode (cname = "macos_is_dark_mode")]
        private extern static int macos_is_dark_mode ();

        private void setup_prefers_color_scheme () {
            // macOS native code paths via CoreFoundation integration
            if (GLib.FileUtils.test ("/usr/bin/defaults", GLib.FileTest.EXISTS)) {
                // Instantly query the native macOS CoreFoundation state
                var is_dark = macos_is_dark_mode () == 1;
                prefers_color_scheme = is_dark ? ColorScheme.DARK : ColorScheme.LIGHT;

                // Safely poll the CoreFoundation memory state dynamically with zero latency
                GLib.Timeout.add_seconds (2, () => {
                    var current_dark = macos_is_dark_mode () == 1;
                    var new_scheme = current_dark ? ColorScheme.DARK : ColorScheme.LIGHT;
                    if (new_scheme != prefers_color_scheme) {
                        prefers_color_scheme = new_scheme;
                    }
                    return GLib.Source.CONTINUE; // Continue polling cleanly
                });
                return;
            }

            // Try freedesktop portal (Linux)
            try {
                portal = Portal.Settings.get ();
                if (portal != null) {
                    var result = portal.read (
                        "org.freedesktop.appearance",
                        "color-scheme"
                    );
                    if (result != null) {
                        var variant = result.get_variant ();
                        if (variant != null) {
                            prefers_color_scheme = (ColorScheme) variant.get_uint32 ();

                            portal.setting_changed.connect ((scheme, key, value) => {
                                if (scheme == "org.freedesktop.appearance" && key == "color-scheme") {
                                    prefers_color_scheme = (ColorScheme) value.get_uint32 ();
                                }
                            });
                            return;
                        }
                    }
                }
            } catch (Error e) {
                debug ("Portal not available: %s", e.message);
            }

            prefers_color_scheme = ColorScheme.NO_PREFERENCE;
        }
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

        public abstract HashTable<string, HashTable<string, Variant>> read_all (string[] namespaces) throws DBusError, IOError;
        public abstract Variant read (string namespace, string key) throws DBusError, IOError;

        public signal void setting_changed (string namespace, string key, Variant value);
    }
}