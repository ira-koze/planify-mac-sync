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

    private static string escape_xml_text (string s) {
        return s.replace ("&", "&amp;").replace ("<", "&lt;").replace (">", "&gt;").replace ("\"", "&quot;");
    }

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
                    <d:propfind xmlns:d="DAV:" xmlns:ical="http://apple.com/ns/ical/" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.com/ns">
                        <d:prop>
                            <d:resourcetype />
                            <d:displayname />
                            <d:sync-token />
                            <ical:calendar-color />
                            <cal:calendar-color />
                            <oc:calendar-color />
                            <ical:calendar-icon />
                            <nc:calendar-emoji />
                            <cal:supported-calendar-component-set />
                        </d:prop>
                    </d:propfind>
        """;


        var multi_status = yield propfind (source.caldav_data.calendar_home_url, xml, "1", cancellable);

        Gee.ArrayList<Objects.Project> projects = new Gee.ArrayList<Objects.Project> ();

        foreach (var response in multi_status.responses ()) {
            string? href = response.href;

            foreach (var propstat in response.propstats ()) {
                if (propstat.status != Soup.Status.OK) continue;

                var resourcetype = propstat.get_first_prop_with_tagname ("resourcetype");
                var supported_calendar = propstat.get_first_prop_with_tagname ("supported-calendar-component-set");

                if (is_vtodo_calendar (resourcetype, supported_calendar)) {
                    var project = new Objects.Project.from_propstat (propstat, get_absolute_url (href));
                    project.source_id = source.id;

                    projects.add (project);
                }
            }
        }

        return projects;
    }


    public async void sync (Objects.Source source, GLib.Cancellable cancellable) throws GLib.Error {
        var xml = """<?xml version='1.0' encoding='utf-8'?>
                    <d:propfind xmlns:d="DAV:" xmlns:ical="http://apple.com/ns/ical/" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:nc="http://nextcloud.com/ns" xmlns:oc="http://owncloud.org/ns">
                        <d:prop>
                            <d:resourcetype />
                            <d:displayname />
                            <d:sync-token />
                            <ical:calendar-color />
                            <cal:calendar-color />
                            <oc:calendar-color />
                            <ical:calendar-icon />
                            <nc:calendar-emoji />
                            <cal:supported-calendar-component-set />
                            <nc:deleted-at/>
                        </d:prop>
                    </d:propfind>
        """;

        var multi_status = yield propfind (source.caldav_data.calendar_home_url, xml, "1", cancellable);


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
                Services.Store.instance ().delete_project (local_project);
            }
        }

        foreach (var response in multi_status.responses ()) {
            string? href = response.href;
            if (href == null) {
                continue;
            }

            string norm_href = Util.normalize_caldav_calendar_url (get_absolute_url (href));

            foreach (var propstat in response.propstats ()) {
                if (propstat.status != Soup.Status.OK) {
                    continue;
                }

                var resourcetype = propstat.get_first_prop_with_tagname ("resourcetype");
                var supported_calendar = propstat.get_first_prop_with_tagname ("supported-calendar-component-set");

                if (is_deleted_calendar (resourcetype)) {
                    Objects.Project ? project = Services.Store.instance ().get_project_via_url (norm_href);
                    if (project != null) {
                        Services.Store.instance ().delete_project (project);
                    }

                    continue;
                }

                if (is_vtodo_calendar (resourcetype, supported_calendar)) {
                    Objects.Project ? project = Services.Store.instance ().get_project_via_url (norm_href);

                    if (project == null) {
                        project = new Objects.Project.from_propstat (propstat, norm_href);
                        project.source_id = source.id;

                        Services.Store.instance ().insert_project (project);
                        /* Item load runs in sync_tasklist — avoid double-fetch. */
                    } else {
                        project.update_from_propstat (propstat, false);
                        Services.Store.instance ().update_project (project);
                    }
                }
            }
        }
    }

    public async void fetch_project_details (Objects.Project project, GLib.Cancellable cancellable) throws GLib.Error {
        var xml = """<?xml version='1.0' encoding='utf-8'?>
                    <d:propfind xmlns:d="DAV:" xmlns:ical="http://apple.com/ns/ical/" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.com/ns">
                        <d:prop>
                            <d:resourcetype />
                            <d:displayname />
                            <d:sync-token />
                            <ical:calendar-color />
                            <cal:calendar-color />
                            <oc:calendar-color />
                            <ical:calendar-icon />
                            <nc:calendar-emoji />
                            <cal:supported-calendar-component-set />
                        </d:prop>
                    </d:propfind>
        """;

        var multi_status = yield propfind (project.calendar_url, xml, "1", cancellable);

        foreach (var response in multi_status.responses ()) {

            foreach (var propstat in response.propstats ()) {
                if (propstat.status != Soup.Status.OK) {
                    continue;
                }

                var resourcetype = propstat.get_first_prop_with_tagname ("resourcetype");
                var supported_calendar = propstat.get_first_prop_with_tagname ("supported-calendar-component-set");
            
                if (is_vtodo_calendar (resourcetype, supported_calendar)) {
                    project.update_from_propstat (propstat, false);
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
                <d:description/>
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
        
        var multi_status = yield report (project.calendar_url, xml, "1", cancellable);
        var responses = multi_status.responses ();
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

                    if (ensure_section_from_vtodo (calendar_data.text_content, project)) {
                        continue;
                    }
                    if (is_section_vtodo_content (calendar_data.text_content)) {
                        warning ("CalDAV: section VTODO not applied; skipping task import (%s)", href ?? "");
                        continue;
                    }

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
                Idle.add ((owned) callback);
                return false;
            }
            return true;
        });
        yield;

        project.freeze_update = false;
        project.count_update ();
        Services.Store.instance ().update_project (project);
    }

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
            string sync_token_before_propfind = project.sync_id;
            if (sync_token_before_source_sync != null) {
                sync_token_before_propfind = sync_token_before_source_sync;
            }
            yield fetch_project_details (project, cancellable);

            /* Push local dirty items before pull so server data can't overwrite newer local edits. */
            var pending_push = Services.Database.get_default ().get_items_needing_push (project.id);
            foreach (var pitem in pending_push) {
                if (pitem.project_id != project.id) {
                    continue;
                }

                HttpResponse push_res = yield add_item (pitem, true);
                if (push_res.status) {
                    pitem.needs_push = false;
                    Services.Store.instance ().update_item (pitem, "");
                }
            }

            if (project.sync_id == null || project.sync_id == "") {
                yield update_sync_token (project, cancellable);
            }

            if (project.sync_id == null || project.sync_id == "") {
                warning ("No CalDAV sync-token for calendar %s; running full calendar-query fetch (incremental sync unavailable).", project.name);
                yield fetch_items_for_project (project, cancellable);
                yield update_sync_token (project, cancellable);
                return;
            }

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

    /** RFC 5545 (VTODO) + RFC 4791: persist a section as its own calendar resource. */
    public async HttpResponse put_section_calendar (Objects.Section section, Objects.Project project) {
        string body = build_section_vcalendar (section, project);
        var url = GLib.Path.build_path ("/", project.calendar_url, "%s.ics".printf (section.id));
        HttpResponse response = new HttpResponse ();
        try {
            yield send_request ("PUT", url, "text/calendar", body, null, null,
                new Soup.Status[]{ Soup.Status.NO_CONTENT, Soup.Status.CREATED });
            response.status = true;
        } catch (Error e) {
            response.error_code = e.code;
            response.error = e.message;
        }
        return response;
    }

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

    public async void update_sync_token (Objects.Project project, GLib.Cancellable cancellable) throws GLib.Error {
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
    }

    public async HttpResponse create_project (Objects.Project project) {
        var xml = """<?xml version="1.0" encoding="utf-8"?>
            <d:mkcol xmlns:d="DAV:" xmlns:ical="http://apple.com/ns/ical/" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.com/ns" xmlns:cal="urn:ietf:params:xml:ns:caldav">
            <d:set>
                <d:prop>
                    <d:resourcetype>
                        <d:collection/>
                        <cal:calendar/>
                    </d:resourcetype>
                    <d:displayname>%s</d:displayname>
                    <ical:calendar-color>%s</ical:calendar-color>
                    <ical:calendar-icon>%s</ical:calendar-icon>
                    <nc:calendar-emoji>%s</nc:calendar-emoji>
                    <oc:calendar-enabled>1</oc:calendar-enabled>
                    <cal:supported-calendar-component-set >
                        <cal:comp name="VTODO"/>
                    </cal:supported-calendar-component-set>
                </d:prop>
            </d:set>
        </d:mkcol>
        """.printf (project.name, project.color_hex, project.emoji, project.emoji);

        var calendar_url = GLib.Uri.resolve_relative (project.source.caldav_data.calendar_home_url, project.id, GLib.UriFlags.NONE);
        if (!calendar_url.has_suffix ("/")) {
            calendar_url += "/";
        }

        HttpResponse response = new HttpResponse ();

        try {
            yield send_request ("MKCOL", calendar_url, "application/xml", xml, null, null,
                                { Soup.Status.CREATED });
            project.calendar_url = calendar_url;
            response.status = true;
        } catch (Error e) {
            response.error_code = e.code;
            response.error = humanize_sabre_error_message (e.message);
        }

        return response;
    }

    public async HttpResponse update_project (Objects.Project project) {
        var xml = """<?xml version="1.0" encoding="utf-8"?>
        <d:propertyupdate xmlns:d="DAV:" xmlns:ical="http://apple.com/ns/ical/" xmlns:nc="http://nextcloud.com/ns">
            <d:set>
                <d:prop>
                    <d:displayname>%s</d:displayname>
                    <ical:calendar-color>%s</ical:calendar-color>
                    <ical:calendar-icon>%s</ical:calendar-icon>
                    <nc:calendar-emoji>%s</nc:calendar-emoji>
                </d:prop>
            </d:set>
        </d:propertyupdate>
        """.printf (project.name, project.color_hex, project.emoji, project.emoji);

        HttpResponse response = new HttpResponse ();

        try {
            yield send_request ("PROPPATCH", project.calendar_url, "application/xml", xml, null, null,
                                    { Soup.Status.MULTI_STATUS });

            response.status = true;
        } catch (Error e) {
            response.error_code = e.code;
            response.error = e.message;
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

    private async bool try_put_after_412_refresh (
        Objects.Item item,
        string url,
        bool update,
        Soup.Status[] expected,
        HttpResponse response
    ) {
        try {
            string server_cal = yield send_request ("GET", url, null, null, null, null, { Soup.Status.OK });
            string server_etag = _last_response_etag;
            if (server_etag == null || server_etag.strip () == "") {
                return false;
            }
            item.update_from_vtodo (server_cal, url, server_etag);
            string new_body = item.to_vtodo ();
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

    public async HttpResponse add_item (Objects.Item item, bool update = false) {
        var url = update ? item.ical_url : GLib.Path.build_path ("/", item.project.calendar_url, "%s.ics".printf (item.id));
        var body = item.to_vtodo ();

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
            if (_last_http_status_code == Soup.Status.PRECONDITION_FAILED || (e.message != null && e.message.contains ("HTTP 412"))) {
                if (yield try_put_after_412_refresh (item, url, update, expected, response)) {
                    return response;
                }
                response.error_code = (int) Soup.Status.PRECONDITION_FAILED;
                response.error = _("Precondition failed (412): this task was modified on the server.");
                return response;
            }
            response.error_code = e.code;
            response.error = e.message;
        }

        return response;
    }

    public async HttpResponse complete_item (Objects.Item item) {
        var body = item.to_vtodo ();

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
            if (_last_http_status_code == Soup.Status.PRECONDITION_FAILED || (e.message != null && e.message.contains ("HTTP 412"))) {
                var expected_c = new Soup.Status[]{ Soup.Status.NO_CONTENT, Soup.Status.CREATED };
                if (yield try_put_after_412_refresh (item, item.ical_url, true, expected_c, response)) {
                    return response;
                }
                response.error_code = (int) Soup.Status.PRECONDITION_FAILED;
                response.error = _("Precondition failed (412): this task was modified on the server.");
                return response;
            }
            response.error_code = e.code;
            response.error = e.message;
        }

        return response;
    }

    private GLib.HashTable<string,string>? if_match_headers_for_item (Objects.Item item, bool update, string put_url) {
        if (!update) {
            return null;
        }

        string etag = Util.get_etag_from_extra_data (item.extra_data);
        if (etag == null || etag == "") {
            return null;
        }

        string stored_url = Util.get_ical_url_from_extra_data (item.extra_data).strip ();
        string p = put_url.strip ();
        if (stored_url != "" && p != "" && stored_url != p) {
            return null;
        }

        var headers = new HashTable<string,string> (str_hash, str_equal);
        headers.insert ("If-Match", etag);
        return headers;
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
            yield send_request ("DELETE", item.ical_url, "", null, null, null, { Soup.Status.NO_CONTENT, Soup.Status.OK });

            response.status = true;
        } catch (Error e) {
            response.error_code = e.code;
            response.error = e.message;
        }


        return response;
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
