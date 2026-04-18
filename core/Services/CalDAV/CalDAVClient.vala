/*
 * Copyright © 2025 Alain M. (https://github.com/alainm23/planify)
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


public class Services.CalDAV.CalDAVClient : Services.CalDAV.WebDAVClient {

    /** How many calendar-query responses to parse per main-loop Idle tick (full fetch). */
    private const int FETCH_ITEMS_IDLE_CHUNK = 40;

    /** One resource from sync-collection REPORT; sorted so section VTODOs apply before tasks. */
    private class SyncCollectionEntry : Object {
        public string href;
        public string vtodo_content;
        public string? etag_report;
        public string? doc_etag;
    }

    public CalDAVClient (Soup.Session session, string base_url, string username, string password, bool ignore_ssl = false) {
        base (session, base_url, username, password, ignore_ssl);
    }

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
            // no-op: debug instrumentation must never break sync
        }
    }

    private static string? extract_vtodo_x_property (string vtodo_content, string x_name) {
        if (vtodo_content == null || vtodo_content == "") {
            return null;
        }

        string prefix = x_name + ":";
        foreach (string raw_line in vtodo_content.split ("\n")) {
            string line = raw_line.strip ();
            if (line.has_prefix (prefix)) {
                return line.substring (prefix.length).strip ();
            }
        }

        return null;
    }

    private static string escape_xml_text (string s) {
        return s.replace ("&", "&amp;").replace ("<", "&lt;").replace (">", "&gt;").replace ("\"", "&quot;");
    }

    /** Turn Sabre/Nextcloud XML error bodies into short user-facing text (MKCOL/PROPPATCH failures). */
    private string humanize_sabre_error_message (string raw) {
        if (raw == null || raw == "") {
            return "";
        }

        int open = raw.index_of ("<s:message>");
        if (open >= 0) {
            int close = raw.index_of ("</s:message>", open);
            if (close > open) {
                long start = open + 11;
                long len = close - start;
                if (len > 0) {
                    string inner = raw.substring ((ssize_t) start, (ssize_t) len).strip ();
                    if (inner == "Calendar limit reached") {
                        return _("The server refused to create a calendar (calendar limit reached). Remove unused calendars in Nextcloud or ask an administrator to raise the limit.");
                    }
                    if (inner != "") {
                        return _("Could not create calendar: %s").printf (inner);
                    }
                }
            }
        }

        if (raw.contains ("HTTP 403") || raw.contains (" 403 ")) {
            return _("Could not create calendar (access denied). Check your Nextcloud calendar quota or permissions.");
        }

        return raw;
    }

    private string display_name_with_emoji_prefix (Objects.Project project) {
        string em = project.emoji != null ? project.emoji.strip () : "";
        if (em == "") {
            return project.name;
        }

        string prefix = em + " ";
        if (project.name.has_prefix (prefix)) {
            return project.name;
        }

        return prefix + project.name;
    }

    private bool proppatch_multistatus_ok (string raw_xml, out string? failure_detail) {
        failure_detail = null;
        try {
            var ms = new WebDAVMultiStatus.from_string (sanitize_xml_response (raw_xml));
            foreach (var resp in ms.responses ()) {
                foreach (var ps in resp.propstats ()) {
                    if (ps.status != Soup.Status.OK && ps.status != Soup.Status.NO_CONTENT && ps.status != Soup.Status.MULTI_STATUS) {
                        failure_detail = _("PROPPATCH failed (HTTP %u) for %s").printf ((uint) ps.status, resp.href ?? "");
                        return false;
                    }
                }
            }
        } catch (Error e) {
            failure_detail = e.message;
            return false;
        }

        return true;
    }

    private GLib.HashTable<string,string>? if_match_headers_for_item (Objects.Item item, bool is_update, string put_url) {
        if (!is_update) {
            return null;
        }

        string e = Util.get_etag_from_extra_data (item.extra_data).strip ();
        if (e == "") {
            return null;
        }

        string stored_url = Util.get_ical_url_from_extra_data (item.extra_data).strip ();
        string p = put_url.strip ();
        if (stored_url != "" && p != "" && stored_url != p) {
            /* Stale ETag from another resource URL causes 412 on first PUT to a new href. */
            return null;
        }

        var h = new GLib.HashTable<string,string> (str_hash, str_equal);
        h.insert ("If-Match", e);
        return h;
    }

    /**
     * If-Match failed: fetch current resource, merge into @item, then PUT again with a fresh ETag.
     * Returns true if the retry succeeded.
     */
    private async bool try_put_after_412_refresh (
        Objects.Item item,
        string url,
        bool update,
        Soup.Status[] expected,
        HttpResponse response
    ) {
        string? val_err;
        try {
            string server_cal = yield send_request ("GET", url, null, null, null, null, { Soup.Status.OK });
            string server_etag = _last_response_etag;
            if (server_etag == null || server_etag.strip () == "") {
                return false;
            }
            item.update_from_vtodo (server_cal, url, server_etag);
            string new_body = item.to_vtodo ();
            if (!ICalValidator.validate_put_calendar (new_body, item.id, out val_err)) {
                warning ("[iCal PUT validate] uid=%s after 412 merge: %s", item.id, val_err);
                return false;
            }
            GLib.HashTable<string,string>? if_headers = if_match_headers_for_item (item, update, url);
            yield send_request ("PUT", url, "text/calendar", new_body, null, null, expected, if_headers);
            string etag = _last_response_etag;
            if (etag == null || etag == "") {
                etag = Util.get_etag_from_extra_data (item.extra_data);
            }
            item.extra_data = Util.generate_extra_data (url, etag, new_body);
            response.status = true;
            return true;
        } catch (Error e) {
            warning ("412 recovery PUT failed: %s", e.message);
            return false;
        }
    }


    public async string? get_principal_url (GLib.Cancellable cancellable) throws GLib.Error {
        var xml = """<?xml version="1.0" encoding="utf-8"?>
                        <propfind xmlns="DAV:">
                            <prop>
                                <current-user-principal/>
                            </prop>
                        </propfind>
        """;

        var multi_status = yield propfind ("", xml, "0", cancellable);

        foreach (var response in multi_status.responses ()) {
            foreach (var propstat in response.propstats ()) {
                foreach (var principal in propstat.prop.get_elements_by_tag_name ("current-user-principal")) {
                    var href_elements = principal.get_elements_by_tag_name ("href");
                    foreach (var href in href_elements) {
                        string link = href.text_content.strip ();
                        return get_absolute_url (link);
                    }
                }
            }
        }

        return null;
    }

    public async string? get_calendar_home (string principal_url, GLib.Cancellable cancellable) throws GLib.Error {
        var xml = """<?xml version="1.0" encoding="utf-8"?>
                        <propfind xmlns="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
                            <prop>
                                <cal:calendar-home-set/>
                            </prop>
                        </propfind>
        """;


        var multi_status = yield propfind (principal_url, xml, "0", cancellable);

        foreach (var response in multi_status.responses ()) {
            foreach (var propstat in response.propstats ()) {
                foreach (var calendar_home in propstat.prop.get_elements_by_tag_name ("calendar-home-set")) {
                    var href_elements = calendar_home.get_elements_by_tag_name ("href");
                    foreach (var href in href_elements) {
                        string link = href.text_content.strip ();
                        return get_absolute_url (link);
                    }
                }
            }
        }
        return null;
    }


    public async void update_userdata (string principal_url, Objects.Source source, GLib.Cancellable cancellable) throws GLib.Error {
        var xml = """<?xml version="1.0" encoding="utf-8"?>
                    <d:propfind xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns">
                        <d:prop>
                            <d:displayname/>
                            <s:email-address/>
                        </d:prop>
                    </d:propfind>
        """;

        var multi_status = yield propfind (principal_url, xml, "0", cancellable);

        foreach (var response in multi_status.responses ()) {
            foreach (var propstat in response.propstats ()) {
                var prop = propstat.prop;

                var names = prop.get_elements_by_tag_name ("displayname");
                if (names.size > 0) {
                    source.caldav_data.user_displayname = names[0].text_content.strip ();
                }

                var emails = prop.get_elements_by_tag_name ("email-address");
                if (emails.size > 0) {
                    source.caldav_data.user_email = emails[0].text_content.strip ();
                };
            }
        }

        if (source.caldav_data.user_email != null && source.caldav_data.user_email != "") {
            source.display_name = source.caldav_data.user_email;
            return;
        }

        if (source.caldav_data.user_displayname != null && source.caldav_data.user_displayname != "") {
            source.display_name = source.caldav_data.user_displayname;
            return;
        }

        source.display_name = _ ("CalDAV");
    }

    public async Gee.ArrayList<Objects.Project> fetch_project_list (Objects.Source source, GLib.Cancellable cancellable) throws GLib.Error {
        var xml = """<?xml version='1.0' encoding='utf-8'?>
                    <d:propfind xmlns:d="DAV:" xmlns:ical="http://apple.com/ns/ical/" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:oc="http://owncloud.org/ns" xmlns:p="http://planify.app/ns">
                        <d:prop>
                            <d:resourcetype />
                            <d:displayname />
                            <d:sync-token />
                            <ical:calendar-color />
                            <cs:calendar-color />
                            <oc:calendar-color />
                            <cal:supported-calendar-component-set />
                            <p:X-PLANIFY-EMOJI />
                            <p:X-PLANIFY-ICON-STYLE />
                            <p:X-PLANIFY-DESCRIPTION />
                        </d:prop>
                    </d:propfind>
        """;


        var multi_status = yield propfind (source.caldav_data.calendar_home_url, xml, "1", cancellable);

        // Temporary debug aid: dump PROPFIND XML for inspection
        multi_status.debug_print ();

        Gee.ArrayList<Objects.Project> projects = new Gee.ArrayList<Objects.Project> ();
        var seen_hrefs = new Gee.HashSet<string> ();

        foreach (var response in multi_status.responses ()) {
            string? href = response.href;
            if (href == null) {
                continue;
            }

            string abs_href = get_absolute_url (href);
            if (seen_hrefs.contains (abs_href)) {
                warning ("PROPFIND duplicate href skipped: %s", abs_href);
                continue;
            }

            seen_hrefs.add (abs_href);

            foreach (var propstat in response.propstats ()) {
                if (propstat.status != Soup.Status.OK) continue;

                var resourcetype = propstat.get_first_prop_with_tagname ("resourcetype");
                var supported_calendar = propstat.get_first_prop_with_tagname ("supported-calendar-component-set");

                if (is_deleted_calendar (resourcetype)) {
                    continue;
                }

                if (is_vtodo_calendar (resourcetype, supported_calendar)) {
                    var project = new Objects.Project.from_propstat (propstat, abs_href);
                    project.source_id = source.id;

                    // #region agent log
                    debug_agent_log (
                        "initial",
                        "H5",
                        "CalDAVClient.fetch_project_list",
                        "Project properties from PROPFIND",
                        """{"projectName":"%s","href":"%s","hasEmojiProp":%s,"hasIconStyleProp":%s,"hasDescriptionProp":%s}""".printf (
                            debug_json_escape (project.name),
                            debug_json_escape (abs_href),
                            propstat.get_first_prop_with_tagname ("X-PLANIFY-EMOJI") != null ? "true" : "false",
                            propstat.get_first_prop_with_tagname ("X-PLANIFY-ICON-STYLE") != null ? "true" : "false",
                            propstat.get_first_prop_with_tagname ("description") != null ? "true" : "false"
                        )
                    );
                    // #endregion

                    projects.add (project);
                }
            }
        }

        return projects;
    }


    public async void sync (Objects.Source source, GLib.Cancellable cancellable) throws GLib.Error {
        var xml = """<?xml version='1.0' encoding='utf-8'?>
                    <d:propfind xmlns:d="DAV:" xmlns:ical="http://apple.com/ns/ical/" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:nc="http://nextcloud.com/ns" xmlns:cs="http://calendarserver.org/ns/" xmlns:oc="http://owncloud.org/ns" xmlns:p="http://planify.app/ns">
                        <d:prop>
                            <d:resourcetype />
                            <d:displayname />
                            <d:sync-token />
                            <ical:calendar-color />
                            <cs:calendar-color />
                            <oc:calendar-color />
                            <cal:supported-calendar-component-set />
                            <nc:deleted-at/>
                            <p:X-PLANIFY-EMOJI />
                            <p:X-PLANIFY-ICON-STYLE />
                            <p:X-PLANIFY-DESCRIPTION />
                        </d:prop>
                    </d:propfind>
        """;

        var multi_status = yield propfind (source.caldav_data.calendar_home_url, xml, "1", cancellable);

        // Temporary debug aid: dump PROPFIND XML for inspection
        multi_status.debug_print ();


        // Delete CalDAV Generic
        var server_urls = new Gee.HashSet<string> ();
        foreach (var response in multi_status.responses ()) {
            if (response.href != null) {
                server_urls.add (Util.normalize_caldav_calendar_url (get_absolute_url (response.href)));
            }
        }

        var local_projects = Services.Store.instance ().get_projects_by_source (source.id);
        foreach (Objects.Project local_project in local_projects) {
            if (!server_urls.contains (Util.normalize_caldav_calendar_url (local_project.calendar_url))) {
                yield Services.Store.instance ().delete_project (local_project);
            }
        }

        var seen_sync_hrefs = new Gee.HashSet<string> ();

        foreach (var response in multi_status.responses ()) {
            string? href = response.href;
            if (href == null) {
                continue;
            }

            string abs_href = get_absolute_url (href);
            string norm_href = Util.normalize_caldav_calendar_url (abs_href);
            if (seen_sync_hrefs.contains (norm_href)) {
                warning ("PROPFIND duplicate href skipped (sync): %s", abs_href);
                continue;
            }

            seen_sync_hrefs.add (norm_href);

            foreach (var propstat in response.propstats ()) {
                if (propstat.status != Soup.Status.OK) {
                    continue;
                }

                var resourcetype = propstat.get_first_prop_with_tagname ("resourcetype");
                var supported_calendar = propstat.get_first_prop_with_tagname ("supported-calendar-component-set");

                if (is_deleted_calendar (resourcetype)) {
                    Objects.Project ? project = Services.Store.instance ().get_project_via_url (norm_href);
                    if (project != null) {
                        yield Services.Store.instance ().delete_project (project);
                    }

                    continue;
                }

                if (is_vtodo_calendar (resourcetype, supported_calendar)) {
                    /* Sync even when the server omits DAV:displayname — skipping here dropped whole task lists. */
                    Objects.Project ? project = Services.Store.instance ().get_project_via_url (norm_href);

                    if (project == null) {
                        project = new Objects.Project.from_propstat (propstat, norm_href);
                        project.source_id = source.id;

                        Services.Store.instance ().insert_project (project);
                        /* Item load happens in sync_tasklist (REPORT or full calendar-query) — avoid double-fetch here. */
                    } else {
                        project.update_from_propstat (propstat, false);
                        Services.Store.instance ().update_project (project);
                    }
                }
            }
        }

        foreach (var project in Services.Store.instance ().get_projects_by_source (source.id)) {
            project.notify_property ("emoji");
            project.notify_property ("sections");
            project.notify_property ("description");
        }
    }

    public async void fetch_project_details (Objects.Project project, GLib.Cancellable cancellable) throws GLib.Error {
        var xml = """<?xml version='1.0' encoding='utf-8'?>
                    <d:propfind xmlns:d="DAV:" xmlns:ical="http://apple.com/ns/ical/" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:oc="http://owncloud.org/ns" xmlns:p="http://planify.app/ns">
                        <d:prop>
                            <d:resourcetype />
                            <d:displayname />
                            <d:sync-token />
                            <ical:calendar-color />
                            <cs:calendar-color />
                            <oc:calendar-color />
                            <cal:supported-calendar-component-set />
                            <p:X-PLANIFY-EMOJI />
                            <p:X-PLANIFY-ICON-STYLE />
                            <p:X-PLANIFY-DESCRIPTION />
                        </d:prop>
                    </d:propfind>
        """;

        var multi_status = yield propfind (project.calendar_url, xml, "1", cancellable);

        // Temporary debug aid: dump PROPFIND XML for inspection
        multi_status.debug_print ();

        foreach (var response in multi_status.responses ()) {

            foreach (var propstat in response.propstats ()) {
                if (propstat.status != Soup.Status.OK) {
                    continue;
                }

                var resourcetype = propstat.get_first_prop_with_tagname ("resourcetype");
                var supported_calendar = propstat.get_first_prop_with_tagname ("supported-calendar-component-set");
            
                if (is_vtodo_calendar (resourcetype, supported_calendar)) {
                    // #region agent log
                    debug_agent_log (
                        "initial",
                        "H5",
                        "CalDAVClient.fetch_project_details",
                        "Project detail props before update_from_propstat",
                        """{"projectId":"%s","projectName":"%s","hasEmojiProp":%s,"hasIconStyleProp":%s,"hasDescriptionProp":%s}""".printf (
                            debug_json_escape (project.id),
                            debug_json_escape (project.name),
                            propstat.get_first_prop_with_tagname ("X-PLANIFY-EMOJI") != null ? "true" : "false",
                            propstat.get_first_prop_with_tagname ("X-PLANIFY-ICON-STYLE") != null ? "true" : "false",
                            propstat.get_first_prop_with_tagname ("description") != null ? "true" : "false"
                        )
                    );
                    // #endregion

                    // Ensure we update the sync-token so subsequent syncs work
                    project.update_from_propstat (propstat);
                    Services.Store.instance ().update_project (project);
                    return;
                }
            }
        }
    }

    public delegate void ProgressCallback (int current, int total, string message);

    public async void fetch_items_for_project (Objects.Project project, GLib.Cancellable cancellable, owned ProgressCallback? progress_callback = null) throws GLib.Error {
        SourceFunc callback = fetch_items_for_project.callback;

        var xml = """<?xml version="1.0" encoding="utf-8"?>
        <cal:calendar-query xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
            <d:prop>
                <d:getetag/>
                <d:displayname/>
                <d:owner/>
                <d:sync-token/>
                <d:current-user-privilege-set/>
                <d:getcontenttype/>
                <d:resourcetype/>
                <cal:calendar-data/>
            </d:prop>
            <cal:filter>
                <cal:comp-filter name="VCALENDAR">
                    <cal:comp-filter name="VTODO">
                    </cal:comp-filter>
                </cal:comp-filter>
            </cal:filter>
        </cal:calendar-query>
        """;
        
        // #region agent log
        debug_agent_log (
            "initial",
            "H1pre",
            "CalDAVClient.fetch_items_for_project",
            "About to issue REPORT calendar-query (full fetch)",
            """{"projectId":"%s","projectName":"%s"}""".printf (
                debug_json_escape (project.id),
                debug_json_escape (project.name)
            )
        );
        // #endregion

        var multi_status = yield report (project.calendar_url, xml, "1", cancellable);
        var responses = multi_status.responses ();

        // #region agent log
        debug_agent_log (
            "initial",
            "H21",
            "CalDAVClient.fetch_items_for_project",
            "calendar-query REPORT returned",
            """{"projectId":"%s","responseCount":%d}""".printf (
                debug_json_escape (project.id),
                responses.size
            )
        );
        // #endregion

        /* REPORT order is not guaranteed; section VTODOs must be applied before tasks that reference them. */
        var sorted_responses = new Gee.ArrayList<WebDAVResponse> ();
        foreach (var r in responses) {
            sorted_responses.add (r);
        }
        sorted_responses.sort ((a, b) => {
            string? ca = get_first_calendar_data_from_response (a);
            string? cb = get_first_calendar_data_from_response (b);
            bool ha = ca != null && ca != "";
            bool hb = cb != null && cb != "";
            if (!ha && !hb) {
                return 0;
            }
            if (!ha) {
                return 1;
            }
            if (!hb) {
                return -1;
            }
            bool sa = is_section_vtodo_content (ca);
            bool sb = is_section_vtodo_content (cb);
            if (sa && !sb) {
                return -1;
            }
            if (!sa && sb) {
                return 1;
            }
            return 0;
        });
        int section_vtodo_count = 0;
        int task_vtodo_count = 0;
        int task_with_section_ref = 0;
        int unresolved_section_ref_before_parse = 0;

        // #region agent log
        debug_agent_log (
            "initial",
            "H1",
            "CalDAVClient.fetch_items_for_project",
            "Starting full calendar-query fetch",
            """{"projectId":"%s","projectName":"%s","responses":%d}""".printf (
                debug_json_escape (project.id),
                debug_json_escape (project.name),
                sorted_responses.size
            )
        );
        // #endregion
        
        if (progress_callback != null) {
            progress_callback (0, sorted_responses.size, _("Loading tasks for %s…").printf (project.name));
        }

        project.freeze_update = true;

        int index = 0;
        var items_list = new Gee.ArrayList<Objects.Item> ();

        Idle.add (() => {
            if (index >= sorted_responses.size) {
                if (progress_callback != null) {
                    progress_callback (sorted_responses.size, sorted_responses.size, _ ("Loaded tasks for %s…").printf (project.name));
                }
                project.add_items_batched (items_list);
                Idle.add ((owned) callback);
                return false;
            }

            int chunk = 0;
            while (index < sorted_responses.size && chunk < FETCH_ITEMS_IDLE_CHUNK) {
                var response = sorted_responses[index];
                string? href = response.href;

                foreach (var propstat in response.propstats ()) {
                    if (propstat.status != Soup.Status.OK) {
                        continue;
                    }

                    var calendar_data = propstat.get_first_prop_with_tagname ("calendar-data");
                    if (calendar_data == null || calendar_data.text_content == null) {
                        continue;
                    }

                    if (Constants.debug_caldav_http ()) {
                        Constants.log_debug_http ("[CalDAV Debug] RAW VTODO from %s:\n%s\n".printf (href, calendar_data.text_content));
                    }

                    string? section_ref = extract_vtodo_x_property (calendar_data.text_content, "X-PLANIFY-SECTION-ID");
                    if (section_ref != null && section_ref != "") {
                        task_with_section_ref++;
                        if (Services.Store.instance ().get_section (section_ref) == null) {
                            unresolved_section_ref_before_parse++;
                        }
                    }

                    if (ensure_section_from_vtodo (calendar_data.text_content, project)) {
                        section_vtodo_count++;
                        continue;
                    }
                    if (is_section_vtodo_content (calendar_data.text_content)) {
                        warning ("CalDAV: section VTODO not applied; skipping task import (%s)", href ?? "");
                        continue;
                    }

                    task_vtodo_count++;
                    Objects.Item item = new Objects.Item.from_vtodo (calendar_data.text_content, get_absolute_url (href), project);
                    items_list.add (item);
                }

                if (progress_callback != null && index % 10 == 0) {
                    progress_callback (index, sorted_responses.size, _ ("Syncing task %d of %d").printf (index, sorted_responses.size));
                }

                index++;
                chunk++;
            }

            if (index >= sorted_responses.size) {
                if (progress_callback != null) {
                    progress_callback (sorted_responses.size, sorted_responses.size, _ ("Loaded tasks for %s…").printf (project.name));
                }
                project.add_items_batched (items_list);
                // #region agent log
                debug_agent_log (
                    "initial",
                    "H1",
                    "CalDAVClient.fetch_items_for_project",
                    "Completed full calendar-query parse",
                    """{"projectId":"%s","sectionsSeen":%d,"tasksSeen":%d,"tasksWithSectionRef":%d,"unresolvedSectionRefBeforeParse":%d}""".printf (
                        debug_json_escape (project.id),
                        section_vtodo_count,
                        task_vtodo_count,
                        task_with_section_ref,
                        unresolved_section_ref_before_parse
                    )
                );
                // #endregion
                Idle.add ((owned) callback);
                return false;
            }
            return true;
        });
        yield;

        project.freeze_update = false;
        project.count_update ();
        Services.Store.instance ().update_project (project);
        project.notify_property ("emoji");
        project.notify_property ("sections");
    }

    /** Sabre/Nextcloud often sends `text/calendar` without the literal `vtodo` in Content-Type. */
    private bool is_calendar_vtodo_resource (string? href, string? content_type) {
        if (href != null && href.has_suffix (".ics")) {
            return true;
        }
        if (content_type == null || content_type.strip () == "") {
            return false;
        }
        string ct = content_type.down ();
        if (ct.index_of ("vtodo") >= 0) {
            return true;
        }
        if (ct.index_of ("text/calendar") >= 0) {
            return true;
        }
        return false;
    }

    public async void sync_tasklist (Objects.Project project, GLib.Cancellable cancellable, string? sync_token_before_source_sync = null) throws GLib.Error {
        if (project.is_deck) {
            return;
        }

        project.loading = true;
        project.sync_started ();

        try {
            /* Token before Core.sync's caldav_client.sync() PROPFIND (passed from Core). If absent,
             * fall back to project.sync_id (legacy callers). fetch_project_details then refreshes
             * project.sync_id; sync-collection must use the pre-refresh token or the delta is empty. */
            string sync_token_before_propfind = project.sync_id;
            if (sync_token_before_source_sync != null) {
                sync_token_before_propfind = sync_token_before_source_sync;
            }
            yield fetch_project_details (project, cancellable);

            /* Push local changes first so REPORT does not overwrite them before PUT. */
            var pending_push = Services.Database.get_default ().get_items_needing_push (project.id);
            int pending_push_count = pending_push.size;
            foreach (var pitem in pending_push) {
                if (pitem.project_id != project.id) {
                    continue;
                }

                HttpResponse push_res = yield add_item (pitem, true);
                if (push_res.status) {
                    pitem.needs_push = false;
                    Services.Store.instance ().update_item (pitem, "");
                } else if (push_res.error != null && push_res.error != "") {
                    warning ("CalDAV push retry failed for item %s: %s", pitem.id, push_res.error);
                }
            }

            int local_items_count = Services.Store.instance ().get_items_by_project (project).size;
            int tok_before_len = sync_token_before_propfind != null ? sync_token_before_propfind.length : 0;
            int sync_id_len_after_details = project.sync_id != null ? project.sync_id.length : 0;
            string pull_branch = "incremental_sync_collection";
            if (project.sync_id == null || project.sync_id == "") {
                pull_branch = "need_update_sync_token_first";
            } else if (local_items_count == 0) {
                pull_branch = "full_calendar_query_empty_local";
            } else if (tok_before_len == 0) {
                pull_branch = "full_calendar_query_no_pre_propfind_token";
            }

            // #region agent log
            debug_agent_log (
                "initial",
                "H13",
                "CalDAVClient.sync_tasklist",
                "Post-push pull branch (before optional update_sync_token)",
                """{"projectId":"%s","projectName":"%s","pendingPushCount":%d,"localItems":%d,"tokBeforeLen":%d,"syncIdLen":%d,"pullBranch":"%s"}""".printf (
                    debug_json_escape (project.id),
                    debug_json_escape (project.name),
                    pending_push_count,
                    local_items_count,
                    tok_before_len,
                    sync_id_len_after_details,
                    pull_branch
                )
            );
            // #endregion

            if (project.sync_id == null || project.sync_id == "") {
                yield update_sync_token (project, cancellable);
            }

            if (project.sync_id == null || project.sync_id == "") {
                warning ("No CalDAV sync-token for calendar %s; running full calendar-query fetch (incremental sync unavailable).", project.name);
                yield fetch_items_for_project (project, cancellable);
                yield update_sync_token (project, cancellable);
                return;
            }

            /* sync-collection only returns *changes* since the token. */
            if (Services.Store.instance ().get_items_by_project (project).size == 0) {
                warning ("CalDAV: calendar \"%s\" has no local tasks; running full calendar-query fetch (required for first-time / empty replica sync).", project.name);
                yield fetch_items_for_project (project, cancellable);
                yield update_sync_token (project, cancellable);
                return;
            }

            string token_for_delta = sync_token_before_propfind;
            if (token_for_delta == null || token_for_delta == "") {
                warning ("CalDAV: no sync-token from before PROPFIND; running full calendar-query fetch (incremental delta unavailable).");
                yield fetch_items_for_project (project, cancellable);
                yield update_sync_token (project, cancellable);
                return;
            }

            // #region agent log
            debug_agent_log (
                "post-fix",
                "H12",
                "CalDAVClient.sync_tasklist",
                "Incremental sync-collection using pre-PROPFIND sync-token",
                """{"projectId":"%s","projectName":"%s","tokenForDeltaLen":%d,"syncIdAfterPropfindLen":%d}""".printf (
                    debug_json_escape (project.id),
                    debug_json_escape (project.name),
                    token_for_delta.length,
                    project.sync_id.length
                )
            );
            // #endregion

            var xml = """
        <d:sync-collection xmlns:d="DAV:">
            <d:sync-token>%s</d:sync-token>
            <d:sync-level>1</d:sync-level>
            <d:prop>
                <d:getetag/>
                <d:getcontenttype/>
            </d:prop>
        </d:sync-collection>
        """.printf (escape_xml_text (token_for_delta));

            var multi_status = yield report (project.calendar_url, xml, "1", cancellable);

            // #region agent log
            debug_agent_log (
                "initial",
                "H20",
                "CalDAVClient.sync_tasklist",
                "sync-collection REPORT returned",
                """{"projectId":"%s","responseCount":%d}""".printf (
                    debug_json_escape (project.id),
                    multi_status.responses ().size
                )
            );
            // #endregion

            project.freeze_update = true;

            var sync_collection_entries = new Gee.ArrayList<SyncCollectionEntry> ();

            foreach (WebDAVResponse response in multi_status.responses ()) {
                string? href = response.href;

                if (response.status == Soup.Status.NOT_FOUND) {
                    Objects.Item ? item = Services.Store.instance ().get_item_by_ical_url (get_absolute_url (href));
                    if (item != null) {
                        Services.Store.instance ().delete_item (item);
                    }

                    continue;
                }

                foreach (WebDAVPropStat propstat in response.propstats ()) {
                    if (propstat.status == Soup.Status.NOT_FOUND) {
                        Objects.Item ? item = Services.Store.instance ().get_item_by_ical_url (get_absolute_url (href));
                        if (item != null) {
                            Services.Store.instance ().delete_item (item);
                        }
                    } else {
                        string? ctype = null;
                        var getcontenttype = propstat.get_first_prop_with_tagname ("getcontenttype");
                        if (getcontenttype != null && getcontenttype.text_content != null) {
                            ctype = getcontenttype.text_content;
                        }

                        if (!is_calendar_vtodo_resource (href, ctype)) {
                            continue;
                        }

                        string? etag_report = null;
                        var etag_el = propstat.get_first_prop_with_tagname ("getetag");
                        if (etag_el != null && etag_el.text_content != null) {
                            etag_report = etag_el.text_content.strip ();
                        }

                        string vtodo_content = yield get_vtodo_by_url (get_absolute_url (href), cancellable);

                        string? doc_etag = _last_response_etag;
                        if (doc_etag == null || doc_etag == "") {
                            doc_etag = etag_report;
                        }

                        var entry = new SyncCollectionEntry ();
                        entry.href = href ?? "";
                        entry.vtodo_content = vtodo_content;
                        entry.etag_report = etag_report;
                        entry.doc_etag = doc_etag;
                        sync_collection_entries.add (entry);
                    }
                }
            }

            sync_collection_entries.sort ((a, b) => {
                bool sa = is_section_vtodo_content (a.vtodo_content);
                bool sb = is_section_vtodo_content (b.vtodo_content);
                if (sa && !sb) {
                    return -1;
                }
                if (!sa && sb) {
                    return 1;
                }
                return 0;
            });

            // #region agent log
            debug_agent_log (
                "initial",
                "H1b",
                "CalDAVClient.sync_tasklist.incremental",
                "Ordered sync-collection entries (sections first)",
                """{"projectId":"%s","projectName":"%s","entryCount":%d}""".printf (
                    debug_json_escape (project.id),
                    debug_json_escape (project.name),
                    sync_collection_entries.size
                )
            );
            // #endregion

            foreach (SyncCollectionEntry entry in sync_collection_entries) {
                string href = entry.href;
                string vtodo_content = entry.vtodo_content;
                string? doc_etag = entry.doc_etag;

                if (ensure_section_from_vtodo (vtodo_content, project)) {
                    continue;
                }
                if (is_section_vtodo_content (vtodo_content)) {
                    warning ("CalDAV: section VTODO not applied; skipping task import (%s)", href);
                    continue;
                }

                try {
                    ICal.Component vcalendar = new ICal.Component.from_string (vtodo_content);
                    
                    ICal.Component vtodo_comp = vcalendar.get_first_component (ICal.ComponentKind.VTODO_COMPONENT);
                    while (vtodo_comp != null) {
                        string uid = vtodo_comp.get_uid ();
                        if (uid != null && uid != "") {
                            Objects.Item ? item = Services.Store.instance ().get_item (uid);

                            if (item != null) {
                                if (item.needs_push) {
                                    warning ("Skipping remote merge for item %s (local needs_push)", item.id);
                                } else {
                                    string old_project_id = item.project_id;
                                    string old_parent_id = item.parent_id;
                                    bool old_checked = item.checked;

                                    item.update_from_vtodo (vtodo_content, get_absolute_url (href), doc_etag);
                                    item.project_id = project.id;
                                    Services.Store.instance ().update_item (item);

                                    if (old_project_id != item.project_id || old_parent_id != item.parent_id) {
                                        Services.EventBus.get_default ().item_moved (item, old_project_id, "", old_parent_id);
                                    }

                                    if (old_checked != item.checked) {
                                        Services.Store.instance ().complete_item (item, old_checked);
                                    }
                                }
                            } else {
                                var new_item = new Objects.Item.from_vtodo (vtodo_content, get_absolute_url (href), project, doc_etag);
                                if (new_item.has_parent) {
                                    Objects.Item ? parent_item = new_item.parent;
                                    if (parent_item != null) {
                                        parent_item.add_item_if_not_exists (new_item);
                                    } else {
                                        project.add_item_if_not_exists (new_item);
                                    }
                                } else {
                                    project.add_item_if_not_exists (new_item);
                                }
                            }
                        }
                        
                        vtodo_comp = vcalendar.get_next_component (ICal.ComponentKind.VTODO_COMPONENT);
                    }
                } catch (Error e) {
                    warning ("Error parsing VTODO from %s: %s", href, e.message);
                }
            }

            var sync_token = multi_status.get_first_text_content_by_tag_name ("sync-token");
            if (sync_token != null && sync_token != project.sync_id) {
                project.sync_id = sync_token;
                project.update_local ();
            }

            project.freeze_update = false;
            project.count_update ();
            Services.Store.instance ().update_project (project);
            project.notify_property ("emoji");
            project.notify_property ("sections");
        } finally {
            project.loading = false;
            project.freeze_update = false;
            project.sync_finished ();
        }
    }


    private async string? get_vtodo_by_url (string url, GLib.Cancellable cancellable) throws GLib.Error {
        return yield send_request ("GET", url, "", null, null, cancellable, { Soup.Status.OK });
    }

    public async void update_sync_token (Objects.Project project, GLib.Cancellable cancellable) throws GLib.Error {
        // #region agent log
        debug_agent_log (
            "initial",
            "H14",
            "CalDAVClient.update_sync_token",
            "enter (PROPFIND sync-token only)",
            """{"projectId":"%s"}""".printf (debug_json_escape (project.id))
        );
        // #endregion

        var xml = """<?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
            <d:prop>
                <d:sync-token/>
            </d:prop>
        </d:propfind>
        """;

        var multi_status = yield propfind (project.calendar_url, xml, "1", cancellable);

        foreach (var response in multi_status.responses ()) {
            foreach (var propstat in response.propstats ()) {
                if (propstat.status != Soup.Status.OK) continue;

                var sync_token = propstat.get_first_prop_with_tagname ("sync-token");
                if (sync_token != null) {
                    project.sync_id = sync_token.text_content;
                    project.update_local ();
                }
            }
        }

        // #region agent log
        debug_agent_log (
            "initial",
            "H14",
            "CalDAVClient.update_sync_token",
            "exit",
            """{"projectId":"%s","syncIdLen":%d}""".printf (
                debug_json_escape (project.id),
                project.sync_id != null ? project.sync_id.length : 0
            )
        );
        // #endregion
    }

    public async HttpResponse create_project (Objects.Project project) {
        var xml = """<?xml version="1.0" encoding="utf-8"?>
        <d:mkcol xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:ical="http://apple.com/ns/ical/">
            <d:set>
                <d:prop>
                    <d:resourcetype>
                        <d:collection/>
                        <cal:calendar/>
                    </d:resourcetype>
                    <d:displayname>%s</d:displayname>
                    <ical:calendar-color>%s</ical:calendar-color>
                    <cal:supported-calendar-component-set >
                        <cal:comp name="VTODO"/>
                    </cal:supported-calendar-component-set>
                </d:prop>
            </d:set>
        </d:mkcol>
        """.printf (project.name, project.color_hex);

        if (Constants.debug_caldav_http ()) {
            Constants.log_debug_http ("[CalDAV] MKCOL Payload for project %s:\n%s\n".printf (project.name, xml));
        }

        var calendar_url = GLib.Uri.resolve_relative (project.source.caldav_data.calendar_home_url, project.id, GLib.UriFlags.NONE);
        if (!calendar_url.has_suffix ("/")) {
            calendar_url += "/";
        }

        HttpResponse response = new HttpResponse ();

        try {
            yield send_request ("MKCOL", calendar_url, "application/xml", xml, null, null,
                                { Soup.Status.CREATED });
            project.calendar_url = calendar_url;
            response = yield update_project (project);
        } catch (Error e) {
            response.error_code = e.code;
            response.error = humanize_sabre_error_message (e.message);
        }

        return response;
    }

    public async HttpResponse update_project (Objects.Project project) {
        var xml = """<?xml version="1.0" encoding="utf-8"?>
        <d:propertyupdate xmlns:d="DAV:" xmlns:ical="http://apple.com/ns/ical/" xmlns:p="http://planify.app/ns">
            <d:set>
                <d:prop>
                    <d:displayname>%s</d:displayname>
                    <ical:calendar-color>%s</ical:calendar-color>
                    <p:X-PLANIFY-EMOJI>%s</p:X-PLANIFY-EMOJI>
                    <p:X-PLANIFY-ICON-STYLE>%s</p:X-PLANIFY-ICON-STYLE>
                    <p:X-PLANIFY-DESCRIPTION>%s</p:X-PLANIFY-DESCRIPTION>
                </d:prop>
            </d:set>
        </d:propertyupdate>
        """.printf (
            escape_xml_text (project.name),
            escape_xml_text (project.color_hex),
            escape_xml_text (project.emoji),
            escape_xml_text (project.icon_style.to_string ()),
            escape_xml_text (project.description)
        );

        if (Constants.debug_caldav_http ()) {
            Constants.log_debug_http ("[CalDAV] PROPPATCH Payload for project %s:\n%s\n".printf (project.name, xml));
        }

        HttpResponse response = new HttpResponse ();

        try {
            var raw = yield send_request ("PROPPATCH", project.calendar_url, "application/xml", xml, null, null,
                                    { Soup.Status.MULTI_STATUS });

            string? det;
            if (!proppatch_multistatus_ok (raw, out det)) {
                var ae = new Objects.AppError ();
                ae.source = "caldav_proppatch";
                ae.affected_uid = project.id;
                ae.message = det ?? _("Calendar property update was rejected by the server");
                Services.AppErrors.get_default ().report (ae, true);

                /* Many servers ignore X-PLANIFY-*; embed emoji in DAV:displayname so it still syncs. */
                string fb_name = escape_xml_text (display_name_with_emoji_prefix (project));
                var xml_fb = """<?xml version="1.0" encoding="utf-8"?>
        <d:propertyupdate xmlns:d="DAV:" xmlns:ical="http://apple.com/ns/ical/">
            <d:set>
                <d:prop>
                    <d:displayname>%s</d:displayname>
                    <ical:calendar-color>%s</ical:calendar-color>
                </d:prop>
            </d:set>
        </d:propertyupdate>
        """.printf (fb_name, escape_xml_text (project.color_hex));

                var raw_fb = yield send_request ("PROPPATCH", project.calendar_url, "application/xml", xml_fb, null, null,
                                        { Soup.Status.MULTI_STATUS });

                if (!proppatch_multistatus_ok (raw_fb, out det)) {
                    var aefb = new Objects.AppError ();
                    aefb.source = "caldav_proppatch";
                    aefb.affected_uid = project.id;
                    aefb.message = det ?? _("PROPPATCH failed after fallback");
                    Services.AppErrors.get_default ().report (aefb, true);
                    response.error_code = (int) Soup.Status.FORBIDDEN;
                    response.error = aefb.message;
                    return response;
                }
            }

            response.status = true;
        } catch (Error e) {
            response.error_code = e.code;
            response.error = e.message;
            var aenet = new Objects.AppError ();
            aenet.source = "caldav_proppatch";
            aenet.affected_uid = project.id;
            aenet.message = e.message;
            Services.AppErrors.get_default ().report (aenet, true);
        }

        return response;
    }

    public async HttpResponse delete_project (Objects.Project project) {
        HttpResponse response = new HttpResponse ();

        try {
            yield send_request ("DELETE", project.calendar_url, "text/calendar", null, null, null,
                                { Soup.Status.NO_CONTENT, Soup.Status.MULTI_STATUS });
            // Radicale sends a Multi-Status with 200 OK -> TODO: Validate Response in Multi Status?
            response.status = true;
        } catch (Error e) {
            response.error_code = e.code;
            response.error = e.message;
        }

        return response;
    }

    public async HttpResponse add_item (Objects.Item item, bool update = false) {
        var url = update ? item.ical_url : GLib.Path.build_path ("/", item.project.calendar_url, "%s.ics".printf (item.id));
        var body = item.to_vtodo ();

        string? val_err;
        if (!ICalValidator.validate_put_calendar (body, item.id, out val_err)) {
            warning ("[iCal PUT validate] uid=%s violation=%s", item.id, val_err);
            var ae = new Objects.AppError ();
            ae.source = "caldav_put";
            ae.affected_uid = item.id;
            ae.message = val_err;
            Services.AppErrors.get_default ().report (ae, true);
            HttpResponse bad = new HttpResponse ();
            bad.error = val_err;
            return bad;
        }

        var expected = update ? new Soup.Status[]{ Soup.Status.NO_CONTENT, Soup.Status.CREATED }
                              : new Soup.Status[]{ Soup.Status.CREATED };

        HttpResponse response = new HttpResponse ();
        GLib.HashTable<string,string>? if_headers = if_match_headers_for_item (item, update, url);

        try {
            yield send_request ("PUT", url, "text/calendar", body, null, null, expected, if_headers);
            string etag = _last_response_etag;
            if (etag == null || etag == "") {
                etag = Util.get_etag_from_extra_data (item.extra_data);
            }

            item.extra_data = Util.generate_extra_data (url, etag, body);
            response.status = true;
        } catch (Error e) {
            bool is_412 = (e.code == (int) Soup.Status.PRECONDITION_FAILED) ||
                          (e.message != null && (e.message.contains ("HTTP 412") ||
                                                 e.message.contains ("Precondition failed") ||
                                                 e.message.contains ("If-Match")));
            if (is_412) {
                if (yield try_put_after_412_refresh (item, url, update, expected, response)) {
                    return response;
                }
                var ae412 = new Objects.AppError ();
                ae412.source = "caldav_conflict";
                ae412.affected_uid = item.id;
                ae412.message = _("Precondition failed (412): this task was modified on the server.");
                Services.AppErrors.get_default ().report (ae412, true);
                response.error_code = (int) Soup.Status.PRECONDITION_FAILED;
                response.error = ae412.message;
                return response;
            }

            // If server rejects media type (415), retry with CRLF-normalized body and explicit charset
            if (e.message != null && e.message.contains ("HTTP 415")) {
                try {
                    clear_last_request_signature ();
                    var alt_body = body.replace ("\n", "\r\n");
                    if (!ICalValidator.validate_put_calendar (alt_body, item.id, out val_err)) {
                        warning ("[iCal PUT validate] uid=%s violation=%s (415 retry body)", item.id, val_err);
                        var ae415 = new Objects.AppError ();
                        ae415.source = "caldav_put";
                        ae415.affected_uid = item.id;
                        ae415.message = val_err;
                        Services.AppErrors.get_default ().report (ae415, true);
                        response.error = val_err;
                        return response;
                    }
                    yield send_request ("PUT", url, "text/calendar; charset=utf-8", alt_body, null, null, expected, if_headers);
                    string etag2 = _last_response_etag;
                    if (etag2 == null || etag2 == "") {
                        etag2 = Util.get_etag_from_extra_data (item.extra_data);
                    }

                    item.extra_data = Util.generate_extra_data (url, etag2, alt_body);
                    response.status = true;
                } catch (Error e2) {
                    response.error_code = e2.code;
                    response.error = e2.message;
                }
            } else {
                response.error_code = e.code;
                response.error = e.message;
            }
        }

        if (!response.status && response.error != null && response.error != "") {
            var aefail = new Objects.AppError ();
            aefail.source = "caldav_put";
            aefail.affected_uid = item.id;
            aefail.message = response.error;
            Services.AppErrors.get_default ().report (aefail, true);
        }

        return response;
    }

    public async HttpResponse complete_item (Objects.Item item) {
        var body = item.to_vtodo ();

        string? val_err;
        if (!ICalValidator.validate_put_calendar (body, item.id, out val_err)) {
            warning ("[iCal PUT validate] uid=%s violation=%s", item.id, val_err);
            var ae = new Objects.AppError ();
            ae.source = "caldav_put";
            ae.affected_uid = item.id;
            ae.message = val_err;
            Services.AppErrors.get_default ().report (ae, true);
            HttpResponse bad = new HttpResponse ();
            bad.error = val_err;
            return bad;
        }

        HttpResponse response = new HttpResponse ();
        GLib.HashTable<string,string>? if_headers = if_match_headers_for_item (item, true, item.ical_url);

        try {
            yield send_request ("PUT", item.ical_url, "text/calendar", body, null, null, { Soup.Status.NO_CONTENT, Soup.Status.CREATED }, if_headers);
            string etag = _last_response_etag;
            if (etag == null || etag == "") {
                etag = Util.get_etag_from_extra_data (item.extra_data);
            }

            item.extra_data = Util.generate_extra_data (item.ical_url, etag, body);

            response.status = true;
        } catch (Error e) {
            bool is_412 = (e.code == (int) Soup.Status.PRECONDITION_FAILED) ||
                          (e.message != null && (e.message.contains ("HTTP 412") ||
                                                 e.message.contains ("Precondition failed") ||
                                                 e.message.contains ("If-Match")));
            if (is_412) {
                var expected_c = new Soup.Status[]{ Soup.Status.NO_CONTENT, Soup.Status.CREATED };
                if (yield try_put_after_412_refresh (item, item.ical_url, true, expected_c, response)) {
                    return response;
                }
                var ae412c = new Objects.AppError ();
                ae412c.source = "caldav_conflict";
                ae412c.affected_uid = item.id;
                ae412c.message = _("Precondition failed (412): this task was modified on the server.");
                Services.AppErrors.get_default ().report (ae412c, true);
                response.error_code = (int) Soup.Status.PRECONDITION_FAILED;
                response.error = ae412c.message;
                return response;
            }

            if (e.message != null && e.message.contains ("HTTP 415")) {
                try {
                    var alt_body = body.replace ("\n", "\r\n");
                    if (!ICalValidator.validate_put_calendar (alt_body, item.id, out val_err)) {
                        warning ("[iCal PUT validate] uid=%s violation=%s (415 retry body)", item.id, val_err);
                        var ae415c = new Objects.AppError ();
                        ae415c.source = "caldav_put";
                        ae415c.affected_uid = item.id;
                        ae415c.message = val_err;
                        Services.AppErrors.get_default ().report (ae415c, true);
                        response.error = val_err;
                        return response;
                    }
                    yield send_request ("PUT", item.ical_url, "text/calendar; charset=utf-8", alt_body, null, null, { Soup.Status.NO_CONTENT, Soup.Status.CREATED }, if_headers);
                    string etag2 = _last_response_etag;
                    if (etag2 == null || etag2 == "") {
                        etag2 = Util.get_etag_from_extra_data (item.extra_data);
                    }

                    item.extra_data = Util.generate_extra_data (item.ical_url, etag2, alt_body);
                    response.status = true;
                } catch (Error e2) {
                    response.error_code = e2.code;
                    response.error = e2.message;
                }
            } else {
                response.error_code = e.code;
                response.error = e.message;
            }
        }

        if (!response.status && response.error != null && response.error != "") {
            var aefailc = new Objects.AppError ();
            aefailc.source = "caldav_put";
            aefailc.affected_uid = item.id;
            aefailc.message = response.error;
            Services.AppErrors.get_default ().report (aefailc, true);
        }

        return response;
    }


    public async HttpResponse move_item (Objects.Item item, Objects.Project destination_project) {
        var destination = GLib.Path.build_path ("/", destination_project.calendar_url, "%s.ics".printf (item.id));

        var headers = new HashTable<string,string> (str_hash, str_equal);
        headers.insert ("Destination", destination);

        HttpResponse response = new HttpResponse ();

        try {
            yield send_request ("MOVE", item.ical_url, "", null, null, null, { Soup.Status.NO_CONTENT, Soup.Status.CREATED }, headers);

            item.extra_data = Util.generate_extra_data (destination, "", item.calendar_data);

            response.status = true;
        } catch (Error e) {
            response.error_code = e.code;
            response.error = e.message;
        }

        return response;
    }


    public async HttpResponse delete_item (Objects.Item item) {
        HttpResponse response = new HttpResponse ();

        try {
            // Accept 204, 200 and also 207 Multi-Status responses from various CalDAV servers
            yield send_request ("DELETE", item.ical_url, "", null, null, null, { Soup.Status.NO_CONTENT, Soup.Status.OK, Soup.Status.MULTI_STATUS });

            response.status = true;
        } catch (Error e) {
            response.error_code = e.code;
            response.error = e.message;
        }


        return response;
    }

    /**
     * Section rows are stored as standalone VTODO resources (RFC 5545 §3.6.2) with Planify X-properties;
     * RFC 4791 CalDAV stores them as calendar objects in the collection.
     */
    public async HttpResponse put_section_calendar (Objects.Section section, Objects.Project project) {
        string body = build_section_vcalendar (section, project);

        string? val_err;
        if (!ICalValidator.validate_put_calendar (body, section.id, out val_err)) {
            warning ("[iCal PUT validate] section uid=%s violation=%s", section.id, val_err);
            var ae = new Objects.AppError ();
            ae.source = "caldav_put";
            ae.affected_uid = section.id;
            ae.message = val_err ?? "";
            Services.AppErrors.get_default ().report (ae, true);
            HttpResponse bad = new HttpResponse ();
            bad.error = val_err;
            return bad;
        }

        var url = GLib.Path.build_path ("/", project.calendar_url, "%s.ics".printf (section.id));
        var expected = new Soup.Status[]{ Soup.Status.NO_CONTENT, Soup.Status.CREATED };

        HttpResponse response = new HttpResponse ();

        try {
            yield send_request ("PUT", url, "text/calendar", body, null, null, expected);
            response.status = true;
        } catch (Error e) {
            if (e.message != null && e.message.contains ("HTTP 415")) {
                try {
                    var alt_body = body.replace ("\n", "\r\n");
                    if (!ICalValidator.validate_put_calendar (alt_body, section.id, out val_err)) {
                        response.error = val_err;
                        return response;
                    }
                    yield send_request ("PUT", url, "text/calendar; charset=utf-8", alt_body, null, null, expected);
                    response.status = true;
                } catch (Error e2) {
                    response.error_code = e2.code;
                    response.error = e2.message;
                }
            } else {
                response.error_code = e.code;
                response.error = e.message;
            }
        }

        if (!response.status && response.error != null && response.error != "") {
            var aef = new Objects.AppError ();
            aef.source = "caldav_put";
            aef.affected_uid = section.id;
            aef.message = response.error;
            Services.AppErrors.get_default ().report (aef, true);
        }

        return response;
    }

    /** Builds a minimal VCALENDAR containing one section VTODO (RFC 5545; CalDAV resource). */
    private string build_section_vcalendar (Objects.Section section, Objects.Project project) {
        var vtodo = new ICal.Component (ICal.ComponentKind.VTODO_COMPONENT);
        vtodo.set_uid (section.id);
        vtodo.set_dtstamp (new ICal.Time.current_with_zone (ICal.Timezone.get_utc_timezone ()));
        vtodo.set_summary (section.name);
        vtodo.set_status (ICal.PropertyStatus.NEEDSACTION);

        if (section.description != null && section.description.strip () != "") {
            vtodo.set_description (section.description);
        }

        var t1 = new ICal.Property (ICal.PropertyKind.X_PROPERTY);
        t1.set_x_name ("X-PLANIFY-TYPE");
        t1.set_x ("section");
        vtodo.add_property (t1);

        var t2 = new ICal.Property (ICal.PropertyKind.X_PROPERTY);
        t2.set_x_name ("X-PLANIFY-ITEM-TYPE");
        t2.set_x ("section");
        vtodo.add_property (t2);

        var sn = new ICal.Property (ICal.PropertyKind.X_PROPERTY);
        sn.set_x_name ("X-PLANIFY-SECTION-NAME");
        sn.set_x (section.name);
        vtodo.add_property (sn);

        var sid = new ICal.Property (ICal.PropertyKind.X_PROPERTY);
        sid.set_x_name ("X-PLANIFY-SECTION-ID");
        sid.set_x (section.id);
        vtodo.add_property (sid);

        if (section.color != null && section.color != "") {
            var sc = new ICal.Property (ICal.PropertyKind.X_PROPERTY);
            sc.set_x_name ("X-PLANIFY-SECTION-COLOR");
            sc.set_x (section.color);
            vtodo.add_property (sc);
        }

        var pid = new ICal.Property (ICal.PropertyKind.X_PROPERTY);
        pid.set_x_name ("X-PLANIFY-PROJECT-ID");
        pid.set_x (project.id);
        vtodo.add_property (pid);

        var ord = new ICal.Property (ICal.PropertyKind.X_PROPERTY);
        ord.set_x_name ("X-APPLE-SORT-ORDER");
        ord.set_x (section.section_order.to_string ());
        vtodo.add_property (ord);

        var vtodo_string = vtodo.as_ical_string ();
        var raw = "%s%s%s".printf (
            "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Planify App (https://github.com/alainm23/planify)\n",
            vtodo_string,
            "END:VCALENDAR\n"
        );
        return raw.replace ("\n", "\r\n");
    }

    private bool ensure_section_from_vtodo (string vtodo_content, Objects.Project project) {
        try {
            ICal.Component vcalendar = new ICal.Component.from_string (vtodo_content);
            ICal.Component ? vtodo = vcalendar.get_first_component (ICal.ComponentKind.VTODO_COMPONENT);
            if (vtodo == null || !is_section_vtodo (vtodo)) {
                return false;
            }

            string? section_name = vtodo.get_summary ();
            if (section_name == null || section_name.strip () == "") {
                section_name = get_named_x_property (vtodo, "X-PLANIFY-SECTION-NAME");
            }

            if (section_name == null || section_name.strip () == "") {
                if (Constants.debug_caldav_http ()) {
                    Constants.log_debug_http ("[Section Sync] Skipping section VTODO with empty name\n%s\n".printf (vtodo_content));
                }
                return true;
            }

            string? section_color = get_named_x_property (vtodo, "X-PLANIFY-SECTION-COLOR");
            string? remote_uid = vtodo.get_uid ();
            Services.Store.instance ().get_or_create_section_by_name (project.id, section_name, section_color, remote_uid);
            return true;
        } catch (Error e) {
            warning ("Failed to inspect section VTODO: %s", e.message);
            return false;
        }
    }

    private bool is_section_vtodo (ICal.Component vtodo) {
        string? planify_type = get_named_x_property (vtodo, "X-PLANIFY-TYPE");
        if (planify_type != null && planify_type.down ().strip () == "section") {
            return true;
        }

        string? item_type = get_named_x_property (vtodo, "X-PLANIFY-ITEM-TYPE");
        if (item_type != null && item_type.down ().strip () == "section") {
            return true;
        }

        return false;
    }

    private bool is_section_vtodo_content (string vtodo_content) {
        try {
            ICal.Component vcalendar = new ICal.Component.from_string (vtodo_content);
            ICal.Component ? vtodo = vcalendar.get_first_component (ICal.ComponentKind.VTODO_COMPONENT);
            return vtodo != null && is_section_vtodo (vtodo);
        } catch (Error e) {
            return false;
        }
    }

    private string? get_first_calendar_data_from_response (WebDAVResponse response) {
        foreach (var propstat in response.propstats ()) {
            if (propstat.status != Soup.Status.OK) {
                continue;
            }
            var calendar_data = propstat.get_first_prop_with_tagname ("calendar-data");
            if (calendar_data != null && calendar_data.text_content != null) {
                return calendar_data.text_content;
            }
        }
        return null;
    }

    private string? get_named_x_property (ICal.Component vtodo, string property_name) {
        ICal.Property ? xprop = vtodo.get_first_property (ICal.PropertyKind.X_PROPERTY);
        while (xprop != null) {
            if (xprop.get_x_name () == property_name) {
                return xprop.get_value_as_string ();
            }

            xprop = vtodo.get_next_property (ICal.PropertyKind.X_PROPERTY);
        }

        return null;
    }



    private bool is_vtodo_calendar (GXml.DomElement? resourcetype, GXml.DomElement? supported_calendar) {
        if (resourcetype == null) {
            return false;
        }

        bool is_calendar = resourcetype.get_elements_by_tag_name ("calendar").length > 0;
        if (!is_calendar) {
            return false;
        }

        if (supported_calendar == null) {
            /* Nextcloud/Sabre often omit supported-calendar-component-set on PROPFIND; still a CalDAV calendar. */
            return true;
        }

        var calendar_comps = supported_calendar.get_elements_by_tag_name ("comp");
        bool has_any_comp = false;
        foreach (GXml.DomElement calendar_comp in calendar_comps) {
            has_any_comp = true;
            if (calendar_comp.get_attribute ("name") == "VTODO") {
                return true;
            }
        }

        if (!has_any_comp) {
            return true;
        }

        return false;
    }

    public bool is_deleted_calendar (GXml.DomElement? resourcetype) {
        if (resourcetype == null) {
            return false;
        }

        return resourcetype.get_elements_by_tag_name ("deleted-calendar").length > 0;
    }
}
