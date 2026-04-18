/*
 * Copyright © 2026 Alain M. (https://github.com/alainm23/planify)
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 */

public class Services.CalDAV.ICalValidator : GLib.Object {
    private static string debug_json_escape (string? s) {
        if (s == null) {
            return "";
        }
        return s.replace ("\\", "\\\\").replace ("\"", "\\\"").replace ("\r", "\\r").replace ("\n", "\\n");
    }

    private static void debug_agent_log (string run_id, string hypothesis_id, string location, string message, string data_json = "{}") {
        try {
            int64 ts = GLib.get_real_time () / 1000;
            string line = "{\"sessionId\":\"020cd6\",\"runId\":\"%s\",\"hypothesisId\":\"%s\",\"location\":\"%s\",\"message\":\"%s\",\"data\":%s,\"timestamp\":%lld}\n".printf (
                debug_json_escape (run_id),
                debug_json_escape (hypothesis_id),
                debug_json_escape (location),
                debug_json_escape (message),
                data_json,
                ts
            );
            Constants.agent_debug_log_append_line (line);
        } catch (Error e) {
            // no-op for debug instrumentation
        }
    }

    /**
     * Re-parse generated iCalendar before PUT and enforce minimal structural rules.
     */
    public static bool validate_put_calendar (string body, string? item_uid, out string? error_detail) {
        error_detail = null;

        if (body == null || body == "") {
            error_detail = _("Empty calendar body");
            return false;
        }

        ICal.Component ? root = ICal.Parser.parse_string (body);
        if (root == null) {
            error_detail = _("Calendar body failed to parse");
            return false;
        }

        ICal.Component ? vtodo = root.get_first_component (ICal.ComponentKind.VTODO_COMPONENT);
        if (vtodo == null) {
            error_detail = _("Missing VTODO component");
            return false;
        }

        string uid = vtodo.get_uid ();
        if (uid == null || uid == "") {
            error_detail = _("VTODO missing UID");
            return false;
        }

        if (item_uid != null && item_uid != "" && uid != item_uid) {
            error_detail = _("VTODO UID does not match item id");
            return false;
        }

        ICal.Property ? dtstamp = vtodo.get_first_property (ICal.PropertyKind.DTSTAMP_PROPERTY);
        if (dtstamp == null) {
            error_detail = _("VTODO missing DTSTAMP");
            return false;
        }

        ICal.Component ? alarm = vtodo.get_first_component (ICal.ComponentKind.VALARM_COMPONENT);
        int alarm_count = 0;
        while (alarm != null) {
            alarm_count++;
            int trigger_count = 0;
            ICal.Property ? p = alarm.get_first_property (ICal.PropertyKind.TRIGGER_PROPERTY);
            while (p != null) {
                trigger_count++;
                p = alarm.get_next_property (ICal.PropertyKind.TRIGGER_PROPERTY);
            }

            int action_count = 0;
            p = alarm.get_first_property (ICal.PropertyKind.ACTION_PROPERTY);
            while (p != null) {
                action_count++;
                p = alarm.get_next_property (ICal.PropertyKind.ACTION_PROPERTY);
            }

            if (trigger_count != 1 || action_count != 1) {
                // #region agent log
                debug_agent_log (
                    "initial",
                    "H3",
                    "ICalValidator.validate_put_calendar",
                    "Rejected VALARM shape during PUT validation",
                    """{"itemUid":"%s","alarmCount":%d,"triggerCount":%d,"actionCount":%d}""".printf (
                        debug_json_escape (uid),
                        alarm_count,
                        trigger_count,
                        action_count
                    )
                );
                // #endregion
                error_detail = _("Each VALARM must have exactly one TRIGGER and one ACTION");
                return false;
            }

            alarm = vtodo.get_next_component (ICal.ComponentKind.VALARM_COMPONENT);
        }

        if (alarm_count > 0) {
            // #region agent log
            debug_agent_log (
                "initial",
                "H3",
                "ICalValidator.validate_put_calendar",
                "Accepted VALARM set during PUT validation",
                """{"itemUid":"%s","alarmCount":%d}""".printf (debug_json_escape (uid), alarm_count)
            );
            // #endregion
        }

        return true;
    }
}
