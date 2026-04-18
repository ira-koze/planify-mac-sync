/*
 * Copyright © 2026 Alain M. (https://github.com/alainm23/planify)
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
 */

public class Services.AppErrors : GLib.Object {
    private static Services.AppErrors? _instance = null;
    private Gee.ArrayList<Objects.AppError> errors = new Gee.ArrayList<Objects.AppError> ();

    public signal void reported (Objects.AppError error);

    public static unowned Services.AppErrors get_default () {
        if (_instance == null) {
            _instance = new Services.AppErrors ();
        }

        return _instance;
    }

    public Gee.ArrayList<Objects.AppError> snapshot () {
        var copy = new Gee.ArrayList<Objects.AppError> ();
        foreach (var error in errors) {
            copy.add (error);
        }

        return copy;
    }

    public void report (Objects.AppError error, bool surface_to_user = true) {
        errors.add (error);
        warning ("[AppError] %s", error.to_json ());
        reported (error);

        if (error.source.has_prefix ("caldav_")) {
            try {
                Services.Database.get_default ().insert_sync_error (error.source, error.affected_uid, error.message);
            } catch (Error e) {
                stderr.printf ("[AppErrors] failed to persist sync_error row: %s\n", e.message);
            }
        }

        if (surface_to_user) {
            Services.EventBus.get_default ().send_error_toast (error.error_code, error.message);
        }
    }

    /**
     * Trim the SyncErrors table so it cannot grow without bound. Safe to call on startup.
     */
    public void prune_sync_errors (int keep_last = 500) {
        try {
            Services.Database.get_default ().prune_sync_errors (keep_last);
        } catch (Error e) {
            stderr.printf ("[AppErrors] prune_sync_errors failed: %s\n", e.message);
        }
    }
}
