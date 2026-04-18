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

public class Objects.AppError : GLib.Object {
    public string source { get; set; default = ""; }
    public int error_code { get; set; default = 0; }
    public string affected_uid { get; set; default = ""; }
    public string message { get; set; default = ""; }
    public string timestamp { get; set; default = new GLib.DateTime.now_utc ().to_string (); }

    public string to_json () {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("source");
        builder.add_string_value (source);
        builder.set_member_name ("error_code");
        builder.add_int_value (error_code);
        builder.set_member_name ("affected_uid");
        builder.add_string_value (affected_uid);
        builder.set_member_name ("message");
        builder.add_string_value (message);
        builder.set_member_name ("timestamp");
        builder.add_string_value (timestamp);
        builder.end_object ();

        var generator = new Json.Generator ();
        var root = builder.get_root ();
        generator.set_root (root);
        return generator.to_data (null);
    }
}
